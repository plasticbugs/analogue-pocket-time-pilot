// Full-system bench: boot the real game on the real Z80 and look at what comes
// out.
//
// Drives the same scripted inputs as tools/dumpstate.lua, runs to a target
// frame, then pauses the CPU and captures one clean frame as a native 256x224
// PPM. With -ram it also dumps the video memories in the same text format the
// Lua dumper writes, so RTL and MAME state can be diffed directly.
//
//   tb_system <timeplt.rom> <frame> <out.ppm> [-ram out_state.txt] [-quiet]

#include "Vtimeplt_main.h"
#include "Vtimeplt_main___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>

static Vtimeplt_main *dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static inline void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    main_time++;
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

// The RTL bench and the MAME dumper do not start their frame counters at the
// same instant, and they do not stop at the same point within a frame:
//
//   * MAME's register_frame_done fires at the END of a frame, by which time the
//     NMI handler for that frame has run. This bench pauses at the TOP of
//     vblank, before it. That is one frame of game state.
//   * The core's counters are held in reset during the ROM download, so its
//     first vblank arrives a fraction of a frame after the CPU starts, one
//     frame earlier in the count than MAME's. That is the second.
//
// Measured, not assumed: RTL vblank 302 reproduces MAME frame 300 byte for byte
// (see docs/verification.md). The skew is applied to both the stop point and
// the input schedule so "frame N" means the same game state on both sides.
static const int FRAME_SKEW = 2;

// scripted inputs, matched to tools/dumpstate.lua
static void set_inputs(int frame) {
    unsigned in0 = 0xff, in1 = 0xff;
    if (frame >= 600 && frame < 604) in0 &= ~0x01u;   // coin 1
    if (frame >= 660 && frame < 664) in0 &= ~0x08u;   // start 1
    if (frame > 700) {
        in1 &= ~0x10u;                                 // fire
        if ((frame / 60) % 2 == 0) in1 &= ~0x02u;      // right
        else                       in1 &= ~0x01u;      // left
    }
    dut->in0 = in0;
    dut->in1 = in1;
}

template <typename T>
static void dump_region(FILE *f, const char *name, const T &mem, size_t len) {
    fprintf(f, "%s\n", name);
    for (size_t i = 0; i < len; i++) {
        fprintf(f, "%02x", mem[i] & 0xff);
        if ((i % 32) == 31) fputc('\n', f);
    }
    if (len % 32) fputc('\n', f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        fprintf(stderr, "usage: tb_system <rom> <frame> <out.ppm> [-ram state.txt] [-quiet]\n");
        return 2;
    }
    const char *rom_path = argv[1];
    const int target = atoi(argv[2]);
    const char *ppm_path = argv[3];
    const char *ram_path = nullptr;
    bool quiet = false;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "-ram") && i + 1 < argc) ram_path = argv[++i];
        else if (!strcmp(argv[i], "-quiet")) quiet = true;
    }

    dut = new Vtimeplt_main;
    dut->reset = 1;
    dut->pause = 0;
    dut->in0 = dut->in1 = dut->in2 = 0xff;
    dut->dsw0 = 0xff;          // 1 coin 1 credit both slots
    dut->dsw1 = 0x4b;          // 3 lives, upright, 10k/50k, difficulty 4, demo sounds on
    dut->dl_we = 0;
    for (int i = 0; i < 64; i++) tick();

    auto rom = load_rom(rom_path);
    for (size_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = (unsigned)a;
        dut->dl_data = rom[a];
        dut->dl_we = 1;
        tick();
    }
    dut->dl_we = 0;
    for (int i = 0; i < 64; i++) tick();
    dut->reset = 0;

    // ---- run to the target frame
    int vbl = 0;
    set_inputs(-FRAME_SKEW);
    while (vbl < target + FRAME_SKEW) {
        tick();
        if (dut->vblank_rise_o) {
            vbl++;
            set_inputs(vbl - FRAME_SKEW);
        }
    }

    // ---- freeze and render one clean frame
    dut->pause = 1;
    const int W = 256, H = 224;
    std::vector<unsigned char> img;
    img.reserve(W * H * 3);
    int seen = 0, prev_ce = 0;
    bool capturing = false;
    long long guard = 0;
    while (seen < 3 && guard < 20000000LL) {
        tick(); guard++;
        if (dut->vblank_rise_o) {
            seen++;
            if (seen == 1) capturing = true;
            if (seen == 2) break;
        }
        int ce = dut->ce_pix;
        if (prev_ce && !ce && capturing && dut->de) {
            img.push_back(dut->red);
            img.push_back(dut->green);
            img.push_back(dut->blue);
        }
        prev_ce = ce;
    }
    if ((int)img.size() != W * H * 3) {
        fprintf(stderr, "captured %zu pixels, expected %d\n", img.size() / 3, W * H);
        return 1;
    }

    FILE *o = fopen(ppm_path, "wb");
    if (!o) { fprintf(stderr, "cannot write %s\n", ppm_path); return 1; }
    fprintf(o, "P6\n%d %d\n255\n", W, H);
    fwrite(img.data(), 1, img.size(), o);
    fclose(o);

    if (ram_path) {
        auto *r = dut->rootp;
        FILE *f = fopen(ram_path, "w");
        if (!f) { fprintf(stderr, "cannot write %s\n", ram_path); return 1; }
        fprintf(f, "frame %d\n", target);
        dump_region(f, "COLORRAM",   r->timeplt_main__DOT__u_video__DOT__u_cram__DOT__mem, 1024);
        dump_region(f, "VIDEORAM",   r->timeplt_main__DOT__u_video__DOT__u_vram__DOT__mem, 1024);
        dump_region(f, "SPRITERAM0", r->timeplt_main__DOT__u_video__DOT__u_spr0__DOT__mem, 256);
        dump_region(f, "SPRITERAM1", r->timeplt_main__DOT__u_video__DOT__u_spr1__DOT__mem, 256);
        dump_region(f, "WORKRAM",    r->timeplt_main__DOT__u_wram__DOT__mem, 2048);
        fprintf(f, "END\n");
        fclose(f);
    }

    if (!quiet)
        printf("frame %d: wrote %s%s%s  (overrun=%d watchdog=%d)\n",
               target, ppm_path, ram_path ? " + " : "", ram_path ? ram_path : "",
               dut->dbg_spr_overrun, dut->dbg_watchdog);
    return 0;
}
