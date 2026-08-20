#!/usr/bin/env python3
"""Per-second peak/RMS profile of a WAV, and optionally a band comparison.

    wav_profile.py <file.wav> [more.wav ...]
    wav_profile.py --compare <a.wav> <b.wav> [start_s] [len_s]
"""
import sys, wave, struct, math, cmath


def read_wav(path):
    w = wave.open(path)
    n, ch, rate = w.getnframes(), w.getnchannels(), w.getframerate()
    raw = w.readframes(n)
    s = struct.unpack('<%dh' % (n * ch), raw)
    return list(s[0::ch]), rate


def profile(path):
    s, rate = read_wav(path)
    print(f'{path}: {len(s)} samples @ {rate} Hz ({len(s)/rate:.2f} s)')
    for sec in range(len(s) // rate):
        seg = s[sec * rate:(sec + 1) * rate]
        dc = sum(seg) / len(seg)
        ac = [v - dc for v in seg]
        rms = math.sqrt(sum(v * v for v in ac) / len(ac))
        print(f'  t={sec:3d}s  dc={dc:9.1f}  ac_rms={rms:9.1f}  peak={max(abs(v) for v in seg):6d}')


def dft_bands(x, rate, nbands=8, fmax=8000.0):
    """Crude band energies via a Goertzel sweep -- enough to compare spectra."""
    n = len(x)
    dc = sum(x) / n
    x = [v - dc for v in x]
    edges = [fmax * (i / nbands) ** 1.5 for i in range(nbands + 1)]
    out = []
    for b in range(nbands):
        lo, hi = edges[b], edges[b + 1]
        # sample a handful of frequencies inside the band
        e = 0.0
        steps = 6
        for k in range(steps):
            f = lo + (hi - lo) * (k + 0.5) / steps
            w = 2 * math.pi * f / rate
            acc = 0j
            for i, v in enumerate(x):
                acc += v * cmath.exp(-1j * w * i)
            e += abs(acc) ** 2
        out.append((lo, hi, math.sqrt(e / steps) / n))
    return out


def compare(a_path, b_path, start=0.0, length=0.25):
    a, ra = read_wav(a_path)
    b, rb = read_wav(b_path)
    sa = a[int(start * ra):int((start + length) * ra)]
    sb = b[int(start * rb):int((start + length) * rb)]
    for name, s in ((a_path, sa), (b_path, sb)):
        dc = sum(s) / len(s)
        ac = [v - dc for v in s]
        rms = math.sqrt(sum(v * v for v in ac) / len(ac))
        print(f'{name}: n={len(s)} dc={dc:.1f} ac_rms={rms:.1f} peak={max(abs(v) for v in s)}')
    # decimate to a common analysis rate to keep the DFT cheap
    target = 8000
    def dec(s, r):
        step = r / target
        return [s[int(i * step)] for i in range(int(len(s) / step))]
    da, db = dec(sa, ra), dec(sb, rb)
    ba, bb = dft_bands(da, target), dft_bands(db, target)
    print(f'{"band Hz":>16}  {"A":>10}  {"B":>10}   ratio')
    for (lo, hi, ea), (_, _, eb) in zip(ba, bb):
        r = (ea / eb) if eb else float('inf')
        print(f'{lo:7.0f}-{hi:7.0f}  {ea:10.1f}  {eb:10.1f}   {r:6.2f}')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--compare':
        compare(sys.argv[2], sys.argv[3],
                float(sys.argv[4]) if len(sys.argv) > 4 else 0.0,
                float(sys.argv[5]) if len(sys.argv) > 5 else 0.25)
    else:
        for p in sys.argv[1:]:
            profile(p)
