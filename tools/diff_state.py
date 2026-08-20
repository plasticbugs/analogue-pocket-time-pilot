#!/usr/bin/env python3
"""Compare two machine-state dumps region by region.

    diff_state.py <mame_state.txt> <rtl_state.txt>

Only the regions present in both are compared, so the RTL dump can carry extra
ones (work RAM) that the MAME dumper does not write.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tpvideo as tp


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    _, a = tp.load_state(sys.argv[1])
    _, b = tp.load_state(sys.argv[2])
    tag = os.path.basename(sys.argv[2])

    # Work RAM 0xAFE0-0xAFFF is stack. The two dumpers stop the CPU at
    # different points inside the frame, so bytes *below* the current stack
    # pointer are stale leftovers from different call depths and carry no
    # machine state. Everything at or above SP is compared.
    skip = {'WORKRAM': range(0x7e0, 0x800)}
    bad_total = 0
    detail = []
    for name in ('COLORRAM', 'VIDEORAM', 'SPRITERAM0', 'SPRITERAM1', 'WORKRAM'):
        if name not in a or name not in b:
            continue
        x, y = a[name], b[name]
        n = min(len(x), len(y))
        ign = skip.get(name, ())
        bad = [i for i in range(n) if x[i] != y[i] and i not in ign]
        if bad:
            bad_total += len(bad)
            detail.append(f'{name}: {len(bad)}/{n}  first ' +
                          ', '.join(f'{i:03x}:{x[i]:02x}!={y[i]:02x}' for i in bad[:6]))
    if bad_total == 0:
        print(f'OK   {tag}: RAM identical to MAME')
        return 0
    print(f'FAIL {tag}: {bad_total} bytes differ')
    for d in detail:
        print('  ', d)
    return 1


if __name__ == '__main__':
    sys.exit(main())
