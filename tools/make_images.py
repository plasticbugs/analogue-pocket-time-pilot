#!/usr/bin/env python3
"""Generate PLACEHOLDER Pocket artwork -- the shipped assets are hand-made.

Superseded: pkg/pocket/ now carries real artwork. This is kept because it
documents the formats -- the icon is 36x36 and the platform banner 521x165, raw
16-bit, five bits per gun with the top bit unused -- and because it is a quick
way to produce stand-ins for a new core.

It writes into build/ and never into pkg/, so running it cannot overwrite the
real assets.

    tools/make_images.py
"""
import os, struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# 5x7 block font, enough for the title
FONT = {
    'A': ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    'C': ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    'E': ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    'I': ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    'K': ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    'L': ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    'M': ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    'N': ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    'O': ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    'P': ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    '1': ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    '2': ["01110", "10001", "00001", "00110", "01000", "10000", "11111"],
    '8': ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    '9': ["01110", "10001", "10001", "01111", "00001", "10001", "01110"],
    ' ': ["00000"] * 7,
}


def pack(rgb5):
    """(r,g,b) each 0..31 -> little-endian 16-bit word, BGRA5551."""
    r, g, b = rgb5
    return struct.pack('<H', (r << 10) | (g << 5) | b)


class Img:
    def __init__(self, w, h, fill=(0, 0, 0)):
        self.w, self.h = w, h
        self.px = [fill] * (w * h)

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                self.px[y * self.w + x] = c

    def text(self, x, y, s, c, scale=1, spacing=1):
        cx = x
        for ch in s.upper():
            g = FONT.get(ch, FONT[' '])
            for row, bits in enumerate(g):
                for col, bit in enumerate(bits):
                    if bit == '1':
                        self.rect(cx + col * scale, y + row * scale,
                                  cx + (col + 1) * scale, y + (row + 1) * scale, c)
            cx += (len(g[0]) + spacing) * scale
        return cx

    def save(self, path):
        with open(path, 'wb') as f:
            for c in self.px:
                f.write(pack(c))


W = (31, 31, 31)
G = (20, 20, 20)
D = (9, 9, 9)
K = (0, 0, 0)


def plane(img, x, y, s, c):
    """A small top-down biplane silhouette, s pixels per cell."""
    art = [
        "....X....",
        "....X....",
        ".XXXXXXX.",
        "XXXXXXXXX",
        "....X....",
        "...XXX...",
        "..XXXXX..",
        "....X....",
        "...XXX...",
    ]
    for r, row in enumerate(art):
        for col, ch in enumerate(row):
            if ch == 'X':
                img.rect(x + col * s, y + r * s, x + (col + 1) * s, y + (r + 1) * s, c)


def main():
    # build/, never pkg/: the shipped artwork is hand-made and must not be
    # clobbered by re-running this.
    core = os.path.join(ROOT, 'build', 'placeholder_art')
    plats = core
    os.makedirs(core, exist_ok=True)
    os.makedirs(plats, exist_ok=True)

    # ---- 36x36 core icon: a plane over a grey horizon band
    icon = Img(36, 36, K)
    icon.rect(0, 24, 36, 36, D)
    for x in range(0, 36, 6):
        icon.rect(x, 30, x + 3, 31, G)
    plane(icon, 9, 4, 2, W)
    icon.save(os.path.join(core, 'icon.bin'))

    # ---- 521x165 platform banner
    ban = Img(521, 165, K)
    for y in range(165):                       # subtle vertical fade
        v = 2 + (y * 6) // 165
        ban.rect(0, y, 521, y + 1, (v, v, v))
    ban.rect(0, 118, 521, 121, G)
    plane(ban, 40, 46, 8, W)
    ban.text(160, 44, 'TIME', W, scale=6, spacing=1)
    ban.text(160, 92, 'PILOT', W, scale=6, spacing=1)
    ban.text(160, 136, 'KONAMI 1982', G, scale=2, spacing=1)
    ban.save(os.path.join(plats, 'timepilot.bin'))

    print('wrote', os.path.join(core, 'icon.bin'),
          os.path.getsize(os.path.join(core, 'icon.bin')), 'bytes')
    print('wrote', os.path.join(plats, 'timepilot.bin'),
          os.path.getsize(os.path.join(plats, 'timepilot.bin')), 'bytes')


if __name__ == '__main__':
    main()
