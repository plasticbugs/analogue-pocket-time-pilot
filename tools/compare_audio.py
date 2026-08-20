#!/usr/bin/env python3
"""Compare two recordings of the same sound: the core's and MAME's.

    compare_audio.py <rtl.wav> <mame.wav> [mame_start_s] [length_s]

The two run at very different sample rates (the core dumps at the AY's own
223.7 kHz, MAME resamples to 48 kHz), so both are box-decimated to a common
8 kHz before anything is measured. That also throws away the ultrasonic square
wave harmonics MAME's resampler has already removed, which would otherwise
make the core look louder than it is.

Reports DC-removed RMS, peak, and energy in octave-ish bands. A flat ratio
across the bands means the level is off; a ratio that slopes means the filters
are wrong.
"""
import sys, wave, struct, math, cmath

TARGET = 8000


def read_wav(path, start=0.0, length=None):
    w = wave.open(path)
    n, ch, rate = w.getnframes(), w.getnchannels(), w.getframerate()
    s = list(struct.unpack('<%dh' % (n * ch), w.readframes(n)))[0::ch]
    a = int(start * rate)
    b = len(s) if length is None else min(len(s), a + int(length * rate))
    return s[a:b], rate


def decimate(s, rate, target=TARGET):
    """Box average down to `target` Hz -- crude but it does remove the top end."""
    step = rate / target
    out = []
    i = 0.0
    while int(i) + int(step) <= len(s):
        seg = s[int(i):int(i) + max(1, int(step))]
        out.append(sum(seg) / len(seg))
        i += step
    return out


def stats(x):
    if not x:
        return 0.0, 0.0, 0.0
    dc = sum(x) / len(x)
    ac = [v - dc for v in x]
    return dc, math.sqrt(sum(v * v for v in ac) / len(ac)), max(abs(v) for v in ac)


def bands(x, rate, edges=(100, 250, 500, 1000, 2000, 3500, 4000)):
    dc = sum(x) / len(x)
    x = [v - dc for v in x]
    n = len(x)
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        e = 0.0
        steps = 5
        for k in range(steps):
            f = lo + (hi - lo) * (k + 0.5) / steps
            w = 2 * math.pi * f / rate
            acc = 0j
            for i, v in enumerate(x):
                acc += v * cmath.exp(-1j * w * i)
            e += abs(acc) ** 2
        out.append((lo, hi, math.sqrt(e / steps) / n))
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rtl_path, mame_path = sys.argv[1], sys.argv[2]
    mstart = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    length = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5

    a, ra = read_wav(rtl_path, 0.0, length)
    b, rb = read_wav(mame_path, mstart, length)
    da, db = decimate(a, ra), decimate(b, rb)
    n = min(len(da), len(db))
    da, db = da[:n], db[:n]

    for name, x in ((rtl_path, da), (mame_path, db)):
        dc, rms, pk = stats(x)
        print(f'{name:28s} n={len(x):6d}  dc={dc:9.1f}  ac_rms={rms:9.1f}  ac_peak={pk:9.1f}')
    _, ra_rms, _ = stats(da)
    _, rb_rms, _ = stats(db)
    if rb_rms > 0:
        r = ra_rms / rb_rms
        print(f'\noverall RMS ratio core/MAME = {r:.3f}  ({20*math.log10(r):+.2f} dB)')
        print(f'suggested OUT_GAIN scale     = {1.0/r:.3f}x')

    print(f'\n{"band Hz":>13}  {"core":>10}  {"MAME":>10}   ratio')
    for (lo, hi, ea), (_, _, eb) in zip(bands(da, TARGET), bands(db, TARGET)):
        rr = (ea / eb) if eb else float('inf')
        print(f'{lo:5.0f}-{hi:5.0f}  {ea:10.1f}  {eb:10.1f}   {rr:6.2f}')


if __name__ == '__main__':
    sys.exit(main())
