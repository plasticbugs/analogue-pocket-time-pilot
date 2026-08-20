#!/usr/bin/env python3
"""Build the Pocket .rom image for the Time Pilot core from a MAME romset.

A core is FPGA gateware: it cannot unzip a romset or run a script, so the ROM
image has to be assembled on a computer. This reads the .mra description and a
MAME `timeplt` romset -- either the zip or a directory of loose files -- checks
every part's CRC32, concatenates them in the order the .mra gives, and verifies
the finished image against the md5 recorded in the .mra.

Nothing but Python 3 is required. The same .mra also works with the standard
MiSTer mra tools if you already have them.

Usage:
    mra_build.py <file.mra> <romset.zip|romset_dir> [out.rom]
    mra_build.py timeplt.mra timeplt.zip
    mra_build.py timeplt.mra ~/roms/timeplt/
"""
import sys, os, zipfile, hashlib, zlib
import xml.etree.ElementTree as ET


def load_parts(path):
    """Map lowercase member name -> bytes, from a zip or a directory."""
    out = {}
    if os.path.isdir(path):
        for entry in os.scandir(path):
            if entry.is_file():
                with open(entry.path, 'rb') as f:
                    out[entry.name.lower()] = f.read()
        if not out:
            sys.exit(f'error: {path} contains no files')
        return out

    if not os.path.exists(path):
        sys.exit(f'error: {path} not found')
    try:
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                if not info.is_dir():
                    out[os.path.basename(info.filename).lower()] = zf.read(info)
    except zipfile.BadZipFile:
        sys.exit(f'error: {path} is neither a directory nor a readable zip')
    return out


def get_part(parts, node):
    name = node.get('name')
    if name is None:
        sys.exit('error: <part> without a name attribute is not supported')
    data = parts.get(name.lower())
    if data is None:
        sys.exit(f'error: {name} missing from the romset')
    crc = node.get('crc')
    if crc is not None:
        actual = zlib.crc32(data) & 0xffffffff
        if actual != int(crc, 16):
            sys.exit(f'error: {name} CRC {actual:08x}, expected {int(crc, 16):08x} '
                     '(wrong romset, or a bad dump)')
    off = int(node.get('offset', '0'), 0)
    length = node.get('length')
    data = data[off:off + int(length, 0)] if length else data[off:]
    return name, data


def build(mra_path, romset_path, verbose=False):
    root = ET.parse(mra_path).getroot()
    rom = next((r for r in root.iter('rom') if r.get('index', '0') == '0'), None)
    if rom is None:
        sys.exit('error: no <rom index="0"> in the mra file')

    parts = load_parts(romset_path)
    image = bytearray()
    for node in rom:
        if node.tag is ET.Comment:
            continue
        if node.tag != 'part':
            sys.exit(f'error: <{node.tag}> inside <rom> is not supported by this builder')
        name, data = get_part(parts, node)
        if verbose:
            print(f'  0x{len(image):05X}  {len(data):6d}  {name}')
        image += data

    got = hashlib.md5(image).hexdigest()
    want = rom.get('md5')
    if want and want.lower() not in ('none', 'ignore') and got != want.lower():
        sys.exit(f'error: built image md5 {got}, expected {want}\n'
                 '       the romset does not match the one this core was verified against')
    return bytes(image), got


def main():
    args = [a for a in sys.argv[1:] if a != '-v']
    verbose = '-v' in sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    mra, romset = args[0], args[1]
    out = args[2] if len(args) > 2 else None
    if out is None:
        name = ET.parse(mra).getroot().findtext('name') or 'output'
        out = name.lower().replace(' ', '_') + '.rom'

    if verbose:
        print(f'{mra} + {romset}:')
    image, md5 = build(mra, romset, verbose)
    with open(out, 'wb') as f:
        f.write(image)
    print(f'wrote {out} ({len(image)} bytes, md5 {md5}) - verified')
    print('copy it to  Assets/timeplt/common/  on your Pocket SD card')


if __name__ == '__main__':
    main()
