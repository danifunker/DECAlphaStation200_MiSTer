#!/usr/bin/env python3
"""Check that the pipelined core ran the SROM it loaded into the I-cache:
every retired instruction whose PC lies inside the SROM image (PALmode,
physical PC < image size) must be the image's word at that PC.

    check_sromload.py IMAGE.bin TRACE
"""
import struct
import sys

img = open(sys.argv[1], 'rb').read()
n = bad = 0
first = None
for line in open(sys.argv[2]):
    f = line.split()
    pc, insn = int(f[0], 16), int(f[1], 16)
    if pc + 4 <= len(img):
        n += 1
        if first is None:
            first = pc
        want = struct.unpack_from('<I', img, pc)[0]
        if insn != want:
            bad += 1
            if bad <= 10:
                print(f'pc {pc:#x}: retired {insn:08x}, image has {want:08x}')
print(f'check_sromload: {n} instructions retired from the SROM image (first PC {first:#x}), {bad} mismatches')
sys.exit(1 if bad or not n or first != 0 else 0)
