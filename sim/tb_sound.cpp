// Sound board in isolation: drive the command latch and the IRQ line the way
// the main board does, and see what comes out. Far quicker than booting the
// whole game to reach the point where it happens to play something.
//
//   tb_sound <timeplt.rom> <command_hex> <seconds> <out.wav>

#include "Vtimeplt_sound.h"
#include "Vtimeplt_sound___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <map>
#include <algorithm>

static Vtimeplt_sound *dut;
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
    if (fread(d.data(), 1, n, f) != (size_t)n) { exit(1); }
    fclose(f);
    return d;
}

static void put32(FILE *f, unsigned v) { for (int i = 0; i < 4; i++) fputc((v >> (8 * i)) & 255, f); }
static void put16(FILE *f, unsigned v) { for (int i = 0; i < 2; i++) fputc((v >> (8 * i)) & 255, f); }

static void write_wav(const char *path, const std::vector<short> &s, int rate) {
    FILE *f = fopen(path, "wb");
    unsigned bytes = (unsigned)s.size() * 2;
    fwrite("RIFF", 1, 4, f); put32(f, 36 + bytes); fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f); put32(f, 16); put16(f, 1); put16(f, 1);
    put32(f, rate); put32(f, rate * 2); put16(f, 2); put16(f, 16);
    fwrite("data", 1, 4, f); put32(f, bytes);
    for (short v : s) put16(f, (unsigned short)v);
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: tb_sound <rom> <cmd_hex> <seconds> <out.wav>\n"); return 2; }
    unsigned cmd = strtoul(argv[2], nullptr, 16);
    double secs = atof(argv[3]);

    dut = new Vtimeplt_sound;
    dut->reset = 1; dut->pause = 0;
    dut->snd_data = 0; dut->snd_irq = 0; dut->snd_mute = 0;
    dut->dl_we = 0;
    for (int i = 0; i < 64; i++) tick();

    auto rom = load_rom(argv[1]);
    for (size_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = (unsigned)a; dut->dl_data = rom[a]; dut->dl_we = 1; tick();
    }
    dut->dl_we = 0;
    for (int i = 0; i < 64; i++) tick();
    dut->reset = 0;

    const double CLK = 49152000.0;
    // let the board finish its own init (clears 1 KB of RAM, then spins)
    for (long long i = 0; i < (long long)(0.05 * CLK); i++) tick();
    printf("after init:  ay_writes=%u irq_acks=%u irq_pending=%d filter=%04x\n",
           dut->dbg_ay_writes, dut->dbg_irqs, dut->dbg_irq_pending, dut->dbg_filter);

    // the main board's handshake: latch the byte, then pulse LS259 Q2 high
    dut->snd_data = cmd;
    dut->snd_irq = 1; tick(); dut->snd_irq = 0;

    std::vector<short> pcm;
    long long n = (long long)(secs * CLK);
    int peak = 0;
    unsigned acks_at_1ms = 0;
    std::map<unsigned, long long> pchist;
    for (long long i = 0; i < n; i++) {
        tick();
        if ((i & 127) == 0)
            pchist[dut->rootp->timeplt_sound__DOT__u_cpu__DOT__i_tv80_core__DOT__PC]++;
        if (i == (long long)(0.001 * CLK)) acks_at_1ms = dut->dbg_irqs;
        if (dut->audio_ce) {
            short v = (short)dut->audio;
            pcm.push_back(v);
            int a = v < 0 ? -v : v;
            if (a > peak) peak = a;
        }
    }
    double sumsq = 0, sum = 0;
    for (short v : pcm) { sumsq += (double)v * v; sum += v; }
    double dc = pcm.empty() ? 0 : sum / pcm.size();
    double ac = 0;
    for (short v : pcm) ac += (v - dc) * (v - dc);
    ac = pcm.empty() ? 0 : sqrt(ac / pcm.size());

    write_wav(argv[4], pcm, (int)(1789772.0 / 8.0 + 0.5));
    printf("cmd 0x%02x -> %zu samples  peak=%d dc=%.1f ac_rms=%.1f\n",
           cmd, pcm.size(), peak, dc, ac);
    printf("             ay_writes=%u irq_acks=%u (at 1 ms: %u) irq_pending=%d int_ack=%d ch0=%u\n",
           dut->dbg_ay_writes, dut->dbg_irqs, acks_at_1ms,
           dut->dbg_irq_pending, dut->dbg_int_ack, dut->dbg_ch0);
    auto *c = dut->rootp;
    printf("             cpu: PC=%04x IntE_FF1=%d IntE_FF2=%d INT_s=%d IntCycle=%d IStatus=%d\n",
           c->timeplt_sound__DOT__u_cpu__DOT__i_tv80_core__DOT__PC,
           c->timeplt_sound__DOT__u_cpu__DOT__i_tv80_core__DOT__IntE_FF1,
           c->timeplt_sound__DOT__u_cpu__DOT__i_tv80_core__DOT__IntE_FF2,
           c->timeplt_sound__DOT__u_cpu__DOT__i_tv80_core__DOT__INT_s,
           c->timeplt_sound__DOT__u_cpu__DOT__i_tv80_core__DOT__IntCycle,
           c->timeplt_sound__DOT__u_cpu__DOT__i_tv80_core__DOT__IStatus);
    std::vector<std::pair<long long, unsigned>> top;
    for (auto &kv : pchist) top.push_back({kv.second, kv.first});
    std::sort(top.rbegin(), top.rend());
    printf("             PC histogram (top 12 of %zu distinct):", pchist.size());
    for (size_t i = 0; i < top.size() && i < 12; i++)
        printf(" %04x:%lld", top[i].second, top[i].first);
    printf("\n");
    return 0;
}
