"""Time Pilot video model: the executable spec for the video hardware.

Everything here is a direct transcription of MAME's timeplt driver -- the
gfx decode, the PROM colour resolution, the tilemap/sprite priority rules --
written so it can be read while writing RTL instead of re-deriving from C++.

No third-party modules: PNG in and out are done with zlib and struct.
"""
import os, zlib, struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# ---------------------------------------------------------------- .rom layout
ROM_MAIN    = (0x00000, 0x6000)
ROM_SOUND   = (0x06000, 0x1000)
ROM_TILES   = (0x07000, 0x2000)
ROM_SPRITES = (0x09000, 0x4000)
PROM_B4     = (0x0D000, 0x20)     # palette low byte
PROM_B5     = (0x0D020, 0x20)     # palette high byte
PROM_E9     = (0x0D040, 0x100)    # sprite colour lookup
PROM_E12    = (0x0D140, 0x100)    # char colour lookup
ROM_SIZE    = 0x0D240

# Screen: the raster is 256 wide, 256 tall, with rows 16..239 visible.
SCR_W, SCR_H = 256, 256
VIS_Y0, VIS_Y1 = 16, 240
VIS_W, VIS_H = 256, VIS_Y1 - VIS_Y0


# ------------------------------------------------------------------- PNG i/o
def read_png(path):
    d = open(path, 'rb').read()
    pos, idat, plte = 8, b'', None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        tag = d[pos + 4:pos + 8]
        if tag == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', d[pos + 8:pos + 18])
            ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
        elif tag == b'PLTE':
            plte = d[pos + 8:pos + 8 + ln]
        elif tag == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * ch
    img = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        row = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f:
            for x in range(stride):
                a = row[x - ch] if x >= ch else 0
                b = prev[x]
                c = prev[x - ch] if x >= ch else 0
                if f == 1:   row[x] = (row[x] + a) & 0xff
                elif f == 2: row[x] = (row[x] + b) & 0xff
                elif f == 3: row[x] = (row[x] + (a + b) // 2) & 0xff
                elif f == 4:
                    pp = a + b - c
                    pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                    row[x] = (row[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 0xff
        prev = row
        for x in range(w):
            o = (y * w + x) * 3
            if ct == 3:
                pi = row[x] * 3
                img[o:o + 3] = plte[pi:pi + 3]
            elif ct == 0:
                img[o:o + 3] = bytes([row[x]] * 3)
            else:
                img[o:o + 3] = row[x * ch:x * ch + 3]
    return w, h, img


def write_png(path, w, h, img):
    raw = b''.join(b'\x00' + bytes(img[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def chunk(tag, d):
        c = tag + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n'
                           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw, 6))
                           + chunk(b'IEND', b''))


# --------------------------------------------------------------------- ROM
class Rom:
    def __init__(self, path=None):
        path = path or os.path.join(ROOT, 'build', 'timeplt.rom')
        d = open(path, 'rb').read()
        if len(d) != ROM_SIZE:
            raise SystemExit(f'{path}: expected {ROM_SIZE} bytes, got {len(d)}')
        cut = lambda r: d[r[0]:r[0] + r[1]]
        self.main    = cut(ROM_MAIN)
        self.sound   = cut(ROM_SOUND)
        self.tiles   = cut(ROM_TILES)
        self.sprites = cut(ROM_SPRITES)
        self.b4, self.b5 = cut(PROM_B4), cut(PROM_B5)
        self.e9, self.e12 = cut(PROM_E9), cut(PROM_E12)

        # 32 physical colours: 5-bit resistor DACs, weights summing to 255.
        W = (0x19, 0x24, 0x35, 0x40, 0x4d)
        def gun(bits):
            return sum(W[i] for i, (src, b) in enumerate(bits) if (src >> b) & 1)
        self.palette = []
        for i in range(32):
            lo, hi = self.b4[i], self.b5[i]
            r = gun([(hi, 1), (hi, 2), (hi, 3), (hi, 4), (hi, 5)])
            g = gun([(hi, 6), (hi, 7), (lo, 0), (lo, 1), (lo, 2)])
            b = gun([(lo, 3), (lo, 4), (lo, 5), (lo, 6), (lo, 7)])
            self.palette.append((r, g, b))

        # Flatten the two lookup stages into direct pen -> RGB tables.
        # chars use physical colours 16..31, sprites 0..15.
        self.char_rgb = [self.palette[(self.e12[i] & 0x0f) + 0x10] for i in range(128)]
        self.spr_rgb  = [self.palette[self.e9[i] & 0x0f] for i in range(256)]

        self.tile_px = _decode_tiles(self.tiles)
        self.spr_px  = _decode_sprites(self.sprites)


def _decode_tiles(rom):
    """512 tiles -> list of 64-entry pixel lists, row-major, 2 bpp."""
    out = []
    for code in range(len(rom) // 16):
        base = code * 16
        px = [0] * 64
        for y in range(8):
            for x in range(8):
                b = rom[base + (8 if x >= 4 else 0) + y]
                k = x & 3
                px[y * 8 + x] = (((b >> (3 - k)) & 1) << 1) | ((b >> (7 - k)) & 1)
        out.append(px)
    return out


def _decode_sprites(rom):
    """256 sprites -> list of 256-entry pixel lists, row-major, 2 bpp."""
    out = []
    for code in range(len(rom) // 64):
        base = code * 64
        px = [0] * 256
        for y in range(16):
            for x in range(16):
                b = rom[base + 8 * (x >> 2) + y + (24 if y >= 8 else 0)]
                k = x & 3
                px[y * 16 + x] = (((b >> (3 - k)) & 1) << 1) | ((b >> (7 - k)) & 1)
        out.append(px)
    return out


# ------------------------------------------------------------------- state
def load_state(path):
    """Read a dump written by tools/dumpstate.lua."""
    regions, cur, meta = {}, None, {}
    for line in open(path):
        line = line.strip()
        if not line or line == 'END':
            continue
        if line[0].isupper() and not all(c in '0123456789abcdef' for c in line):
            cur = line
            regions[cur] = bytearray()
        elif cur is None:
            k, _, v = line.partition(' ')
            meta[k] = v
        else:
            regions[cur] += bytes.fromhex(line)
    return meta, regions


# ------------------------------------------------------------------ render
def render(rom, colorram, videoram, spriteram0, spriteram1, video_enable=True):
    """Produce the full 256x256 raster as a list of (r,g,b) tuples.

    Order is exactly MAME's screen_update: opaque category-0 tiles, then
    sprites, then opaque category-1 tiles on top.
    """
    black = (0, 0, 0)
    fb = [black] * (SCR_W * SCR_H)
    if not video_enable:
        return fb

    cat = bytearray(32 * 32)

    # --- pass 1: tilemap, category 0 only, fully opaque
    for ty in range(32):
        for tx in range(32):
            idx = ty * 32 + tx
            attr = colorram[idx]
            cat[idx] = (attr >> 4) & 1
            if cat[idx]:
                continue
            _draw_tile(rom, fb, tx, ty, videoram[idx], attr)

    # --- pass 2: sprites, offs 0x3E down to 0x10, later writes win
    for offs in range(0x3e, 0x0f, -2):
        sx = spriteram0[offs]
        code = spriteram0[offs + 1]
        sy = 241 - spriteram1[offs + 1]
        attr = spriteram1[offs]
        color = attr & 0x3f
        flipx = not (attr & 0x40)          # active when the bit is clear
        flipy = bool(attr & 0x80)
        px = rom.spr_px[code]
        lut = rom.spr_rgb
        cbase = color * 4
        for row in range(16):
            y = sy + row
            if not (0 <= y < SCR_H):
                continue
            sr = 15 - row if flipy else row
            o = y * SCR_W
            for col in range(16):
                x = sx + col
                if not (0 <= x < SCR_W):
                    continue
                p = px[sr * 16 + (15 - col if flipx else col)]
                if p:
                    fb[o + x] = lut[cbase + p]

    # --- pass 3: tilemap, category 1, opaque, on top of the sprites
    for ty in range(32):
        for tx in range(32):
            idx = ty * 32 + tx
            if cat[idx]:
                _draw_tile(rom, fb, tx, ty, videoram[idx], colorram[idx])
    return fb


def _draw_tile(rom, fb, tx, ty, code_lo, attr):
    code = code_lo + 256 * ((attr >> 5) & 1)
    color = attr & 0x1f
    flipx = bool(attr & 0x40)
    flipy = bool(attr & 0x80)
    px = rom.tile_px[code]
    lut = rom.char_rgb
    cbase = color * 4
    x0, y0 = tx * 8, ty * 8
    for row in range(8):
        sr = 7 - row if flipy else row
        o = (y0 + row) * SCR_W + x0
        for col in range(8):
            fb[o + col] = lut[cbase + px[sr * 8 + (7 - col if flipx else col)]]


def crop_visible(fb):
    """256x256 raster -> the 256x224 visible window as a flat RGB bytearray."""
    out = bytearray(VIS_W * VIS_H * 3)
    i = 0
    for y in range(VIS_Y0, VIS_Y1):
        for x in range(VIS_W):
            r, g, b = fb[y * SCR_W + x]
            out[i] = r; out[i + 1] = g; out[i + 2] = b
            i += 3
    return out


def rot90cw(w, h, img):
    """Rotate clockwise: dst(x,y) = src(y, h-1-x).  256x224 -> 224x256."""
    dw, dh = h, w
    out = bytearray(dw * dh * 3)
    for dy in range(dh):
        for dx in range(dw):
            sx, sy = dy, h - 1 - dx
            s = (sy * w + sx) * 3
            d = (dy * dw + dx) * 3
            out[d:d + 3] = img[s:s + 3]
    return dw, dh, out


def rot90ccw(w, h, img):
    """Rotate counter-clockwise: dst(x,y) = src(w-1-y, x)."""
    dw, dh = h, w
    out = bytearray(dw * dh * 3)
    for dy in range(dh):
        for dx in range(dw):
            sx, sy = w - 1 - dy, dx
            s = (sy * w + sx) * 3
            d = (dy * dw + dx) * 3
            out[d:d + 3] = img[s:s + 3]
    return dw, dh, out
