// Frozen-state video bench.
//
// Loads a .rom image and one state dump captured by tools/dumpstate.lua into
// the video core's memories, renders a frame, and writes it out as a native
// 256x224 PPM. tools/diff_frames.py rotates it and diffs against MAME's own
// snapshot of the same state, so a run is a direct RTL-vs-hardware check that
// takes a few seconds.
//
//   tb_video <timeplt.rom> <state.txt> <out.ppm>

#include "Vtimeplt_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>

static Vtimeplt_video *dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    main_time++;
}

// --------------------------------------------------------------- state file
struct State { std::map<std::string, std::vector<unsigned char>> reg; };

static bool is_region(const std::string &s) {
    if (s.empty() || !isupper((unsigned char)s[0])) return false;
    for (char c : s) if (!isupper((unsigned char)c) && !isdigit((unsigned char)c)) return false;
    // a hex line is all lowercase hex; region names are upper case
    return true;
}

static State load_state(const char *path) {
    State st;
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    char line[512];
    std::string cur;
    while (fgets(line, sizeof line, f)) {
        std::string s(line);
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
        if (s.empty() || s == "END") continue;
        if (is_region(s)) { cur = s; st.reg[cur]; continue; }
        if (cur.empty()) continue;                    // metadata line
        for (size_t i = 0; i + 1 < s.size(); i += 2)
            st.reg[cur].push_back((unsigned char)strtol(s.substr(i, 2).c_str(), nullptr, 16));
    }
    fclose(f);
    return st;
}

static std::vector<unsigned char> load_rom(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> d(n);
    if (fread(d.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); exit(1); }
    fclose(f);
    return d;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: tb_video <rom> <state.txt> <out.ppm>\n"); return 2; }

    dut = new Vtimeplt_video;
    dut->reset = 1;
    dut->video_enable = 0;
    dut->flip = 0;
    dut->cram_we = dut->vram_we = dut->spr0_we = dut->spr1_we = 0;
    dut->dl_we = 0;
    for (int i = 0; i < 16; i++) tick();

    // --- ROM image
    auto rom = load_rom(argv[1]);
    for (size_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = (unsigned)a;
        dut->dl_data = rom[a];
        dut->dl_we = 1;
        tick();
    }
    dut->dl_we = 0;
    tick();

    // --- machine state
    State st = load_state(argv[2]);
    auto put = [&](const char *name, int which) {
        auto it = st.reg.find(name);
        if (it == st.reg.end()) { fprintf(stderr, "state has no %s\n", name); exit(1); }
        const auto &v = it->second;
        for (size_t i = 0; i < v.size(); i++) {
            if (which < 2) { dut->cpu_vaddr = (unsigned)i; dut->cpu_vdin = v[i]; }
            else           { dut->cpu_saddr = (unsigned)i; dut->cpu_sdin = v[i]; }
            dut->cram_we = (which == 0); dut->vram_we = (which == 1);
            dut->spr0_we = (which == 2); dut->spr1_we = (which == 3);
            tick();
        }
        dut->cram_we = dut->vram_we = dut->spr0_we = dut->spr1_we = 0;
        tick();
    };
    put("COLORRAM", 0);
    put("VIDEORAM", 1);
    put("SPRITERAM0", 2);
    put("SPRITERAM1", 3);

    dut->reset = 0;
    dut->video_enable = 1;

    // --- let the pipeline settle, then capture one whole frame
    const int W = 256, H = 224;
    std::vector<unsigned char> img;
    img.reserve(W * H * 3);

    int vb_seen = 0, prev_ce = 0;
    long long guard = 0;
    bool capturing = false;
    while (vb_seen < 3 && guard < 40000000LL) {
        tick(); guard++;
        if (dut->vblank_rise) {
            vb_seen++;
            if (vb_seen == 2) capturing = true;
            if (vb_seen == 3) break;
        }
        int ce = dut->ce_pix;
        if (prev_ce && !ce) {                 // outputs just updated at the dot edge
            if (capturing && dut->de) {
                img.push_back(dut->red);
                img.push_back(dut->green);
                img.push_back(dut->blue);
            }
        }
        prev_ce = ce;
    }

    if (dut->dbg_spr_overrun) {
        fprintf(stderr, "sprite engine overran its line budget\n");
        return 1;
    }

    if ((int)img.size() != W * H * 3) {
        fprintf(stderr, "captured %zu bytes, expected %d (%zu pixels vs %d)\n",
                img.size(), W * H * 3, img.size() / 3, W * H);
        return 1;
    }

    FILE *o = fopen(argv[3], "wb");
    if (!o) { fprintf(stderr, "cannot write %s\n", argv[3]); return 1; }
    fprintf(o, "P6\n%d %d\n255\n", W, H);
    fwrite(img.data(), 1, img.size(), o);
    fclose(o);
    printf("wrote %s (%dx%d)\n", argv[3], W, H);
    return 0;
}
