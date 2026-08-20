#!/usr/bin/env python3
"""Diff a native 256x224 PPM from the RTL bench against a MAME snapshot.

    diff_frames.py rtl.ppm mame.png [diff.png]

Rotates the PPM the way MAME rotates the screen (90 degrees clockwise) and
compares pixel for pixel. Prints the worst 8x8 cells on a mismatch so the
failure has somewhere to start.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tpvideo as tp


def read_ppm(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'P6'):
        raise SystemExit(f'{path}: not a P6 ppm')
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(d) and d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        fields.append(int(d[i:j]))
        i = j
    return fields[0], fields[1], bytearray(d[i + 1:])


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ppm, png = sys.argv[1], sys.argv[2]
    diff_out = sys.argv[3] if len(sys.argv) > 3 else os.path.splitext(ppm)[0] + '_diff.png'

    w, h, img = read_ppm(ppm)
    rw, rh, rot = tp.rot90cw(w, h, img)
    mw, mh, mimg = tp.read_png(png)
    tag = os.path.basename(ppm)
    if (rw, rh) != (mw, mh):
        print(f'FAIL {tag}: size {rw}x{rh} vs MAME {mw}x{mh}')
        return 1

    bad, cells = 0, {}
    out = bytearray(rot)
    for y in range(rh):
        for x in range(rw):
            o = (y * rw + x) * 3
            if rot[o:o + 3] != mimg[o:o + 3]:
                bad += 1
                out[o:o + 3] = b'\xff\x00\xff'
                cells[(x // 8, y // 8)] = cells.get((x // 8, y // 8), 0) + 1
    if bad == 0:
        print(f'OK   {tag}: 0 differing pixels')
        return 0
    tp.write_png(diff_out, rw, rh, out)
    top = sorted(cells.items(), key=lambda kv: -kv[1])[:12]
    print(f'FAIL {tag}: {bad} differing pixels of {rw*rh} -> {diff_out}')
    print('  hotspots (8x8 cell -> count):',
          ', '.join(f'({cx},{cy})={n}' for (cx, cy), n in top))
    return 1


if __name__ == '__main__':
    sys.exit(main())
