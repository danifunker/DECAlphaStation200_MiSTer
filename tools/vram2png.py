#!/usr/bin/env python3
"""The TGA's VRAM (tb_sys --vram-every, 2 MB) as a PNG: 8 bits a pixel, linear,
lines of WIDTH bytes from byte BASE (the console's VVBR = 1: 0x1000). Without a
palette, index 0 is black and the others a grey ramp.

usage: vram2png.py VRAM.bin OUT.png [--base 0x1000] [--width 1024] [--height 768]
"""
import argparse
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument('vram')
ap.add_argument('out')
ap.add_argument('--base', type=lambda v: int(v, 0), default=0x1000)
ap.add_argument('--width', type=int, default=1024)
ap.add_argument('--height', type=int, default=768)
a = ap.parse_args()
d = open(a.vram, 'rb').read()
px = d[a.base:a.base + a.width * a.height].ljust(a.width * a.height, b'\0')
lut = bytes([0] + [min(255, 96 + i) for i in range(1, 256)])
Image.frombytes('L', (a.width, a.height), px.translate(lut)).save(a.out)
