#!/usr/bin/env python3
"""
fwextract.py - unpack DEC Alpha "WimC" firmware images (AlphaStation 200 / Avanti).

Format (determined from AS200 SRM v6.4-1 / ARC 4.49 / V7.0 update images,
cross-checked by running DEC's own decompressor stub in tools/alphaemu):

  ROM header (flash images only, 0x40 bytes):
     +00 u32 0x00000101   +04 u32 0xFFAA0055 (signature)
     +08 char[8] version  +10 char[8] "DEC"  +18 char[8] platform "AVANTI"
     +20 char[8] "ALPH"   +2C u32 length (not always exact - see notes)
     +30 char[12] image name ("AVANTI_SRM", "AVANTI_ARC", "AVANTI-DROM")
     +3C u32 0x11223344
  Compressed payload:
     "WimC" u32 csize, then either
        (a) raw DEFLATE data immediately            (ARC style, 8-byte header)
        (b) u32 0, u32 0, u32 load_address, DEFLATE (SRM style, 20-byte header)

Usage: fwextract.py <outdir> <file>...
Each WimC block is inflated to <outdir>/<file>.wimc@<offset>[.load_<addr>].bin;
nested WimC blocks and ROM headers inside the outputs are reported and extracted too.
"""
import os, re, struct, sys, zlib

SIG = b'\x01\x01\x00\x00\x55\x00\xaa\xff'

def romheaders(data):
    for m in re.finditer(re.escape(SIG), data):
        o = m.start()
        h = data[o:o + 0x40]
        if len(h) < 0x40:
            continue
        cs = lambda a, b: h[a:b].split(b'\0')[0].decode('latin1')
        yield o, dict(version=cs(8, 0x10), vendor=cs(0x10, 0x18), platform=cs(0x18, 0x20),
                      length=struct.unpack_from('<I', h, 0x2c)[0], name=cs(0x30, 0x3c))

def inflate_at(data, o):
    csize = struct.unpack_from('<I', data, o + 4)[0]
    for hdr in (8, 20):
        load = struct.unpack_from('<I', data, o + 16)[0] if hdr == 20 else None
        if hdr == 20 and struct.unpack_from('<II', data, o + 8) != (0, 0):
            continue
        try:
            d = zlib.decompressobj(-15)
            out = d.decompress(data[o + hdr:])
            if d.eof:
                return out, csize, load, hdr
        except zlib.error:
            pass
    return None, csize, None, None

def process(name, data, outdir, depth=0):
    ind = '  ' * depth
    for o, h in romheaders(data):
        print(f"{ind}{name}: ROM header @{o:#x}: {h}")
    for m in re.finditer(b'WimC', data):
        o = m.start()
        out, csize, load, hdr = inflate_at(data, o)
        if out is None:
            print(f"{ind}{name}: WimC @{o:#x} csize={csize:#x}: could not inflate (false match or truncated)")
            continue
        base = os.path.basename(name)
        fn = f"{base}.wimc@{o:#x}" + (f".load_{load:#x}" if load is not None else "") + ".bin"
        path = os.path.join(outdir, fn)
        with open(path, 'wb') as f:
            f.write(out)
        print(f"{ind}{name}: WimC @{o:#x} hdr={hdr} csize={csize:#x} load={load if load is None else hex(load)} -> {fn} ({len(out):#x} bytes)")
        process(path, out, outdir, depth + 1)

def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    for fn in sys.argv[2:]:
        with open(fn, 'rb') as f:
            process(fn, f.read(), outdir)

if __name__ == '__main__':
    main()
