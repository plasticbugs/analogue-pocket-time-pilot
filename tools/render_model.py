#!/usr/bin/env python3
"""Render a dumped Time Pilot state and diff it against MAME's snapshot.

    tools/render_model.py artifacts/state_0180.txt artifacts/timeplt/0000.png

Writes <state>_ref.png next to the state file, and on a mismatch also
<state>_diff.png with the differing pixels marked. Exit status is 0 only when
the render is pixel-identical to MAME.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tpvideo as tp


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    state_path = sys.argv[1]
    mame_png = sys.argv[2] if len(sys.argv) > 2 else None

    rom = tp.Rom()
    meta, reg = tp.load_state(state_path)
    fb = tp.render(rom, reg['COLORRAM'], reg['VIDEORAM'],
                   reg['SPRITERAM0'], reg['SPRITERAM1'])
    img = tp.crop_visible(fb)
    w, h, rot = tp.rot90cw(tp.VIS_W, tp.VIS_H, img)

    base = os.path.splitext(state_path)[0]
    tp.write_png(base + '_ref.png', w, h, rot)

    if mame_png is None:
        print(f'{base}_ref.png written ({w}x{h}) - no MAME snapshot to compare')
        return 0

    mw, mh, mimg = tp.read_png(mame_png)
    if (mw, mh) != (w, h):
        # try the other rotation before calling it a failure
        w2, h2, rot2 = tp.rot90ccw(tp.VIS_W, tp.VIS_H, img)
        if (mw, mh) == (w2, h2):
            w, h, rot = w2, h2, rot2
        else:
            print(f'FAIL size: model {w}x{h}, MAME {mw}x{mh}')
            return 1

    bad = diff_report(w, h, rot, mimg, base)
    tag = os.path.basename(state_path)
    if bad == 0:
        print(f'OK   {tag}: {w}x{h}, 0 differing pixels')
        return 0
    print(f'FAIL {tag}: {bad} differing pixels of {w*h} -> {base}_diff.png')
    return 1


def diff_report(w, h, a, b, base):
    bad = 0
    out = bytearray(a)
    cells = {}
    for y in range(h):
        for x in range(w):
            o = (y * w + x) * 3
            if a[o:o + 3] != b[o:o + 3]:
                bad += 1
                out[o:o + 3] = b'\xff\x00\xff'
                cells[(x // 8, y // 8)] = cells.get((x // 8, y // 8), 0) + 1
    if bad:
        tp.write_png(base + '_diff.png', w, h, out)
        top = sorted(cells.items(), key=lambda kv: -kv[1])[:12]
        print('  hotspots (8x8 cell -> count):',
              ', '.join(f'({cx},{cy})={n}' for (cx, cy), n in top))
    return bad


if __name__ == '__main__':
    sys.exit(main())
