// Audio bench: boot the whole machine and record what the sound board plays.
//
// Writes a mono 16-bit WAV at the AY's own sample rate (chip clock / 8 =
// 223721.5 Hz), plus a one-line census of how busy the sound CPU was. Compare
// against MAME recorded over the same window with -wavwrite; see
// tools/compare_audio.py.
//
// The window is given in FRAMES, not seconds: the core runs at the measured
// 60.606 Hz while MAME's driver still uses 60.000 Hz, so a window in seconds
// would slide against MAME's recording by 1% and compare different music.
//
//   tb_audio <timeplt.rom> <first_frame> <last_frame> <out.wav>

#include "Vtimeplt_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>

static Vtimeplt_core *dut;
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static inline void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    main_time++;
}

static const int FRAME_SKEW = 2;   // see sim/tb_system.cpp
static int coin_frame = 600;       // -coinframe moves it earlier for quick debug runs

// scripted inputs, matched to tools/play.lua and sim/tb_system.cpp
static void set_inputs(Vtimeplt_core *d, int frame) {
    unsigned in0 = 0xff, in1 = 0xff;
    if (frame >= coin_frame && frame < coin_frame + 4)  in0 &= ~0x01u;   // coin 1
    if (frame >= coin_frame + 60 && frame < coin_frame + 64) in0 &= ~0x08u; // start 1
    if (frame > coin_frame + 100) {
        in1 &= ~0x10u;                                 // fire
        if ((frame / 60) % 2 == 0) in1 &= ~0x02u;      // right
        else                       in1 &= ~0x01u;      // left
    }
    d->in0 = in0;
    d->in1 = in1;
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

static void put32(FILE *f, unsigned v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); fputc((v >> 16) & 255, f); fputc((v >> 24) & 255, f); }
static void put16(FILE *f, unsigned v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); }

static void write_wav(const char *path, const std::vector<short> &s, int rate) {
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", path); exit(1); }
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
    if (argc < 5) {
        fprintf(stderr, "usage: tb_audio <rom> <first_frame> <last_frame> <out.wav>\n");
        return 2;
    }
    const char *rom_path = argv[1];
    const int f0 = atoi(argv[2]);
    const int f1 = atoi(argv[3]);
    const char *wav_path = argv[4];
    for (int i = 5; i < argc; i++)
        if (!strcmp(argv[i], "-coinframe") && i + 1 < argc) coin_frame = atoi(argv[++i]);

    dut = new Vtimeplt_core;
    dut->reset = 1;
    dut->pause = 0;
    dut->in0 = dut->in1 = dut->in2 = 0xff;
    dut->dsw0 = 0xff;
    dut->dsw1 = 0x4b;
    dut->dl_we = 0;
    for (int i = 0; i < 64; i++) tick();

    auto rom = load_rom(rom_path);
    for (size_t a = 0; a < rom.size(); a++) {
        dut->dl_addr = (unsigned)a; dut->dl_data = rom[a]; dut->dl_we = 1; tick();
    }
    dut->dl_we = 0;
    for (int i = 0; i < 64; i++) tick();
    dut->reset = 0;

    std::vector<short> pcm;
    pcm.reserve((size_t)((f1 - f0) * 3700));
    int vbl = 0;
    long long nonzero = 0;
    int peak = 0;
    set_inputs(dut, -FRAME_SKEW);
    while (vbl - FRAME_SKEW < f1) {
        tick();
        if (dut->vblank_rise) {
            vbl++;
            set_inputs(dut, vbl - FRAME_SKEW);
        }
        if (dut->audio_ce && (vbl - FRAME_SKEW) >= f0) {
            short v = (short)dut->audio;
            pcm.push_back(v);
            if (v) nonzero++;
            int a = v < 0 ? -v : v;
            if (a > peak) peak = a;
        }
    }

    // sample rate the AY channels update at
    const int rate = (int)(1789772.0 / 8.0 + 0.5);
    write_wav(wav_path, pcm, rate);

    double sumsq = 0;
    for (short v : pcm) sumsq += (double)v * v;
    double rms = pcm.empty() ? 0 : sqrt(sumsq / pcm.size());
    printf("%s: %zu samples @ %d Hz  peak=%d rms=%.1f nonzero=%.1f%%\n",
           wav_path, pcm.size(), rate, peak, rms,
           pcm.empty() ? 0.0 : 100.0 * nonzero / pcm.size());
    printf("  main board:  snd_cmds=%u  snd_irq_edges=%u\n",
           dut->dbg_snd_cmds, dut->dbg_main_snd_irqs);
    printf("  sound board: timer=%02x filter=%04x ay_writes=%u irq_acks=%u ch0=%u"
           " irq_pending=%d int_ack_level=%d\n",
           dut->dbg_snd_timer, dut->dbg_snd_filter,
           dut->dbg_ay_writes, dut->dbg_irqs, dut->dbg_ch0,
           dut->dbg_irq_pending, dut->dbg_int_ack);
    return 0;
}
