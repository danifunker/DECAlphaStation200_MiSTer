#!/usr/bin/env python3
# The NVRAM image's TOY CMOS block (rtl/mister/nvsave.v): an 8,704-byte AS200.nvr is the 8 KB
# flashbus NVRAM and block 16, whose bytes 0-3 are "CMOS" and bytes 128-255 the CMOS 00h-7Fh
# (3Fh: 1 boots the ARC console, anything else SRM; with the OSD Console = NVRAM file).
#
#   tools/nvr_cmos.py FILE                  show the size, the marker and 3Fh
#   tools/nvr_cmos.py FILE --pad [-o OUT]   add block 16 (marker, CMOS zero) to an 8 KB image
#   tools/nvr_cmos.py FILE --console srm|arc [-o OUT]   set 3Fh (pads first if needed)
#
# Without -o the file is rewritten in place.
import argparse, sys

NV, BLK = 8192, 512
MARK = b'CMOS'

def show(d):
    if len(d) < NV + BLK:
        return '%d bytes: no CMOS block (the core keeps no CMOS; 3Fh reads 0 = SRM)' % len(d)
    b = d[NV:NV + BLK]
    if b[:4] != MARK:
        return '%d bytes: block 16 without the marker (loads nothing; 3Fh reads 0 = SRM)' % len(d)
    c = b[128 + 0x3F]
    return '%d bytes: CMOS kept, 3Fh = %02x (%s)' % (len(d), c, 'ARC' if c == 1 else 'SRM')

def pad(d):
    if len(d) < NV:
        sys.exit('shorter than 8 KB: not an NVRAM image')
    d = bytearray(d[:NV + BLK]) + bytearray(max(0, NV + BLK - len(d)))
    if d[NV:NV + 4] != MARK:
        d[NV:NV + BLK] = MARK + bytes(BLK - 4)
    return d

ap = argparse.ArgumentParser()
ap.add_argument('file')
ap.add_argument('--pad', action='store_true')
ap.add_argument('--console', choices=['srm', 'arc'])
ap.add_argument('-o', '--out')
a = ap.parse_args()
d = open(a.file, 'rb').read()
if not a.pad and not a.console:
    print(show(d))
    sys.exit(0)
d = pad(d)
if a.console:
    d[NV + 128 + 0x3F] = 1 if a.console == 'arc' else 0
open(a.out or a.file, 'wb').write(d)
print(show(bytes(d)))
