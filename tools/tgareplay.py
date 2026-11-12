#!/usr/bin/env python3
"""Replay a TGA trace (rtl/mister/dbg_trace.v, OSD Serial port = TGA trace) on a VRAM dump with
the 21030 semantics docs/design/tga.md describes (the same as rtl/tga/tga.v and tb_tga's
reference), and compare the result with a second dump.

usage: tgareplay.py BEFORE.bin TRACE.log [AFTER.bin] [--width 800] [--base 4096] [--list]
                    [--diff-png OUT.png] [--who X,Y ...]

  --list      print each copy op with its block and the source bytes it takes
  --who X,Y   which ops wrote pixel (X, Y) (8 bpp, pixel = base + y*width + x), and what
              they wrote, in order
The dump is 2 MB, 8 bpp. Modes replayed: simple 00 (byte enables + one-shot/persistent pixel
mask), stipple 01/05, fill 2D/21/25, copy 07 (pairs), COPY64 160-17C, raster op 3 only (others
are reported).
"""
import argparse, sys

ap = argparse.ArgumentParser()
ap.add_argument('before'); ap.add_argument('trace'); ap.add_argument('after', nargs='?')
ap.add_argument('--width', type=int, default=800); ap.add_argument('--base', type=int, default=4096)
ap.add_argument('--list', action='store_true'); ap.add_argument('--diff-png')
ap.add_argument('--who', action='append', default=[])
ap.add_argument('--height', type=int, default=600)
ap.add_argument('--ideal', action='store_true', help='check a pure window move against the before dump')
ap.add_argument('--out', help='write the replayed VRAM to this file')
a = ap.parse_args()

vram = bytearray(open(a.before, 'rb').read())
W, B = a.width, a.base
who = set()
for s in a.who:
    x, y = map(int, s.split(','))
    who.add(B + y * W + x)

st = dict(mode=0, rop=3, pshift=0, pm=0xFFFFFFFF, pxm=0xFFFFFFFF, os=False, fg=0, bg=0,
          c64s=[0] * 4, datar=0, gadr=0, bc0=0, bc1=0,
          lw=1024, le=0, lei1=0, lei2=0, lai1=0, lai2=0, llen=0, la=0)   # the Bresenham engine (21030 6.2.12)
copy_flag = False
cp_src = None          # copy mode: the source's first byte
prev = None            # the shifter's residue: (nominal start, length, bytes)
nop = 0
nwrites = 0
warned = set()


def pxm():
    return st['pxm']


def pxm_done():
    """after a frame buffer operation: a one-shot mask reinitializes to all ones (21030 4.4.21.3;
    it does not revert to the value written persistently before)"""
    if st['os']:
        st['pxm'] = 0xFFFFFFFF; st['os'] = False


def sh():
    v = st['pshift']
    return v - 16 if v & 8 else v


def ropf(c, s, d):
    """the X11 function code c on source s and destination d (bytes)"""
    r = 0
    if c & 8: r |= ~s & ~d
    if c & 4: r |= ~s & d
    if c & 2: r |= s & ~d
    if c & 1: r |= s & d
    return r & 0xFF


def write_px(addr, val, line, rop=True):
    global nwrites
    if rop:
        val = ropf(st['rop'] & 0xF, val, vram[addr])
    pm = st['pm'] >> (8 * (addr & 3)) & 0xFF
    val = (val & pm) | (vram[addr] & ~pm)
    if addr in who:
        x = (addr - B) % W; y = (addr - B) // W
        print('  pixel (%d,%d) <- %02x (was %02x) by line %d: %s' % (x, y, val, vram[addr], line, lines[line].strip()))
    vram[addr] = val
    nwrites += 1


def line_setup(idx, d):
    """a slope (idx 8-15) or slope-no-go (0-7) register write: the manual's set-up (6.2.12.1)"""
    oct = idx & 7; xmaj = bool(oct & 4)
    dx = d & 0xFFFF; dy = d >> 16 & 0xFFFF
    dmaj, dmin = (dx, dy) if xmaj else (dy, dx)
    majp = bool(oct & 2) if xmaj else bool(oct & 1)
    minp = bool(oct & 1) if xmaj else bool(oct & 2)
    mode = st['mode']
    errinc = (1 if majp else 0) if mode & 0x2000 else ((1 if oct & 1 else 0) if xmaj else (0 if oct & 2 else 1))
    amaj = 1 if xmaj else st['lw']; amin = st['lw'] if xmaj else 1
    st['lai1'] = amaj if majp else -amaj
    st['lai2'] = (amin if minp else -amin) + st['lai1']
    st['le'] = (2 * dmin - dmaj - 1 + errinc) >> 1
    st['lei1'] = dmin; st['lei2'] = dmaj - dmin
    st['llen'] = (dmaj + (1 if mode & 0x8000 else 0)) & 15
    st['la'] = st['gadr'] & 0x1FFFFF


def line_draw(pat, ln):
    """draw Length pixels (0 = 16) from the engine's address with the 16-bit mask pat"""
    n = st['llen'] or 16
    mode = st['mode'] & 0xFF
    for i in range(n):
        p = st['la'] & 0x1FFFFF
        bit = pat >> i & 1
        if bit:
            write_px(p, st['fg'] >> (8 * (p & 3)) & 0xFF, ln)
        elif mode == 0x02:
            write_px(p, st['bg'] >> (8 * (p & 3)) & 0xFF, ln)
        if st['le'] < 0:
            st['la'] += st['lai1']; st['le'] += st['lei1']
        else:
            st['la'] += st['lai2']; st['le'] -= st['lei2']
    st['llen'] = 0


def src_read(ns, length, shift):
    """the source bytes a copy block at nominal [ns, ns+length) takes with the pixel shift:
    byte k comes from ns - shift + k; bytes outside the nominal block come from the previous
    read (the residue) when it has them, else from VRAM"""
    global prev
    snap = bytes(vram[ns:ns + length])
    out = bytearray(length)
    for k in range(length):
        ad = ns - shift + k
        if ns <= ad < ns + length:
            out[k] = snap[ad - ns]
        elif prev and prev[0] <= ad < prev[0] + prev[1]:
            out[k] = prev[2][ad - prev[0]]
        else:
            out[k] = vram[ad]
    prev = (ns, length, snap)
    return out


lines = open(a.trace, errors='replace').read().splitlines()
copy_ops = []           # (destination - source + shift, destination pixels)
for ln, line in enumerate(lines):
    line = line.strip()
    if not line:
        continue
    if line[0] == 'D':
        print('line %d: %s events lost' % (ln, line[1:])); continue
    if line[0] == 'Q':                  # a read of the copy buffer registers: it ends the drain-next state
        copy_flag = False
        if a.list: print('%5d copy buffer read %03x' % (ln, int(line[1:4], 16)))
        continue
    if line[0] == 'R' and line[1:4].upper() == '04C' and st['mode'] & 0xFF not in (0x02, 0x06):
        # the continue register outside the line modes: the mode's frame buffer write at the address
        # register (XFree86's tga driver draws its fills, stipples and copies this way)
        g = st['gadr'] & 0x1FFFFF; d = int(line[5:13], 16); m8 = st['mode'] & 0xFF
        if m8 in (0x2D, 0x21, 0x25, 0x23):
            d = (d & 0x7FF) | (g & 3) << 16      # a fill starts at the address register's byte
        line = 'W%02x F %06x %08x' % (m8, g, d)
    if line[0] == 'R':
        off = int(line[1:4], 16); d = int(line[5:13], 16)
        if off == 0x20: st['fg'] = d
        elif off == 0x24: st['bg'] = d
        elif off == 0x28: st['pm'] = d
        elif off == 0x2C: st['pxm'] = d; st['os'] = True
        elif off == 0x30: st['mode'] = d & 0xFFFF; copy_flag = False
        elif off == 0x34: st['rop'] = d & 0xFFF
        elif off == 0x38: st['pshift'] = d & 0xF
        elif off == 0x3C: st['gadr'] = d; st['la'] = d & 0x1FFFFF   # the engine's address (a continue starts here)
        elif off == 0x9C: st['lw'] = d & 0xFFFF
        elif off == 0x48:
            e = d >> 15; st['le'] = e - 0x20000 if e & 0x10000 else e; st['llen'] = d & 15
        elif off == 0x4C and st['mode'] & 0xFF in (0x02, 0x06): line_draw(d & 0xFFFF, ln)
        elif 0x100 <= off < 0x140 and st['mode'] & 0xFF in (0x02, 0x06):
            line_setup((off - 0x100) >> 2, d)
            if off >= 0x120: line_draw(st['datar'] & 0xFFFF, ln)
        elif off == 0x5C: st['pxm'] = d; st['os'] = False
        elif off == 0x80: st['datar'] = d
        elif off == 0x140: st['bc0'] = d
        elif off == 0x144: st['bc1'] = d
        elif off in (0x160, 0x168, 0x170, 0x178):
            st['c64s'][(off - 0x160) >> 3] = d; copy_flag = True
        elif off in (0x164, 0x16C, 0x174, 0x17C):
            s = st['c64s'][(off - 0x164) >> 3] & 0x1FFFFF; dd = d & 0x1FFFFF
            copy_flag = False
            bwd = sh() < 0
            ns = (s & ~7) - 56 if bwd else s
            ds = (dd & ~7) - 56 if bwd else dd
            out = src_read(ns, 64, sh())
            nop += 1
            if a.list:
                print('%5d COPY64 %06x->%06x sh %+d: block %06x..%06x <- %06x..%06x' %
                      (ln, s, dd, sh(), ds, ds + 63, ns - sh(), ns - sh() + 63))
            copy_ops.append((ds - ns + sh(), set(range(ds, ds + 64))))
            for k in range(64):
                write_px(ds + k, out[k], ln)
        elif off == 0x54 and st['mode'] in (0x2D, 0x21, 0x25):
            fill(st['gadr'] & 0x1FFFFF, (d & 0x7FF) + 1, ln)
        continue
    if line[0] != 'W' or len(line) < 21:     # (a capture's last line can be cut short)
        continue
    try:
        mode = int(line[1:3], 16); be = int(line[4], 16); off = int(line[6:12], 16); d = int(line[13:21], 16)
    except ValueError:
        print('line %d: malformed, skipped: %r' % (ln, line)); continue
    m = pxm(); pxm_done()
    if mode in (0x01, 0x05, 0x03):
        base = off & ~3
        for i in range(32):
            if mode == 0x01 and not (m >> i & 1):   # the pixel mask: opaque stipple only (4.4.21)
                continue
            if d >> i & 1:
                write_px(base + i, st['fg'] >> (8 * ((base + i) & 3)) & 0xFF, ln)
            elif mode == 0x01:
                write_px(base + i, st['bg'] >> (8 * ((base + i) & 3)) & 0xFF, ln)
    elif mode == 0x0D:
        # block stipple: 32 pixels from the longword, set bits get block colour 0/1 (pixel & 7), no rop,
        # no pixel mask
        base = off & ~3
        for i in range(32):
            if not (d >> i & 1):
                continue
            p = base + i
            write_px(p, (st['bc1'] if p & 4 else st['bc0']) >> (8 * (p & 3)) & 0xFF, ln, rop=False)
    elif mode in (0x2D, 0x21, 0x25, 0x23):
        p0 = (off & ~3) + (d >> 16 & 3); n = (d & 0x7FF) + 1
        stip = st['datar']
        for i in range(n):
            p = p0 + i
            bit = stip >> ((p - (off & ~3)) & 31) & 1  # the data register repeats every 32 pixels from the longword
            if mode == 0x2D:
                if bit:
                    write_px(p, (st['bc1'] if p & 4 else st['bc0']) >> (8 * (p & 3)) & 0xFF, ln, rop=False)
                else:
                    pass
            elif mode == 0x21:
                write_px(p, (st['fg'] if bit else st['bg']) >> (8 * (p & 3)) & 0xFF, ln)
            elif bit:
                write_px(p, st['fg'] >> (8 * (p & 3)) & 0xFF, ln)
    elif mode == 0x07:
        bwd = sh() < 0
        blk = (off & ~7) - 24 if bwd else off & ~3
        if not copy_flag:
            copy_flag = True
            cp_src = src_read(blk, 32, sh())
            cp_from = blk
            if a.list:
                print('%5d copy src %06x sh %+d: block %06x..%06x <- %06x..%06x' %
                      (ln, off, sh(), blk, blk + 31, blk - sh(), blk - sh() + 31))
        else:
            copy_flag = False
            nop += 1
            if a.list:
                print('%5d copy dst %06x mask %08x: block %06x..%06x' % (ln, off, d, blk, blk + 31))
            px = set()
            for k in range(32):
                o = (k + 8 - (off & 7)) & 31          # the in-order bit; the lanes as tga.v
                bit = (o if o < 8 else o + 16 if o < 16 else o if o < 24 else o - 16) if bwd else k
                if d >> bit & 1:                       # no pixel mask in copy mode (4.4.21)
                    write_px(blk + k, cp_src[k], ln); px.add(blk + k)
            copy_ops.append((blk - cp_from + sh(), px))
    elif mode in (0x02, 0x06):
        # a line segment from this address (data<17:16> its low bits), data<15:0> the mask
        st['la'] = (off & ~3) | (d >> 16 & 3); line_draw(d & 0xFFFF, ln)
    else:
        # simple
        for k in range(4):
            if be >> k & 1 and (m >> k & 1):
                write_px(off + k, d >> (8 * k) & 0xFF, ln)
        if mode not in (0, 0x2000) and mode not in warned:
            warned.add(mode); print('line %d: mode %04x taken as simple' % (ln, mode))

print('%d copy ops, %d pixel writes' % (nop, nwrites))
if a.out:
    open(a.out, 'wb').write(vram)
if a.ideal and a.after:
    # a pure window move: every destination pixel of the copies should hold the source pixel
    # from the before dump, offset by the move. The move is the commonest (destination - source
    # + shift) over the copy ops; only those ops' destinations are checked
    after = open(a.after, 'rb').read()
    before = open(a.before, 'rb').read()
    from collections import Counter
    cnt = Counter(delta for delta, _ in copy_ops)
    delta = cnt.most_common(1)[0][0]
    dy = (delta + W // 2) // W; dx = delta - dy * W
    dst = set()
    for dl, px in copy_ops:
        if dl == delta: dst |= px
    xs = [(p - B) % W for p in dst]; ys = [(p - B) // W for p in dst]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    print('move dx %d dy %d (%d of %d copy ops); they cover x %d..%d y %d..%d' % (dx, dy, cnt[delta], len(copy_ops), x0, x1, y0, y1))
    bad = {}
    for p in sorted(dst):
        x = (p - B) % W; y = (p - B) // W
        if after[p] != before[p - delta]:
            bad.setdefault(x, []).append(y)
    for x in sorted(bad):
        ys = bad[x]
        print('  x %3d: %d rows wrong (y %d..%d): after %s, expected %s' % (x, len(ys), ys[0], ys[-1],
              ' '.join('%02x' % after[B + y * W + x] for y in ys[:6]), ' '.join('%02x' % before[B + y * W + x - delta] for y in ys[:6])))
if a.after:
    after = open(a.after, 'rb').read()
    diff = [i for i in range(B, min(len(after), len(vram))) if after[i] != vram[i]]
    print('%d bytes differ from the after dump' % len(diff))
    rows = {}
    for i in diff:
        rows.setdefault((i - B) // W, []).append((i - B) % W)
    for y in sorted(rows)[:40]:
        xs = rows[y]
        print('  y %4d: x %s%s' % (y, ' '.join('%d(%02x/%02x)' % (x, vram[B + y * W + x], after[B + y * W + x]) for x in xs[:12]),
                                   ' ...' if len(xs) > 12 else ''))
    if a.diff_png:
        from PIL import Image
        im = Image.new('RGB', (W, a.height))
        px = im.load()
        for y in range(a.height):
            for x in range(W):
                v = after[B + y * W + x]
                px[x, y] = (v, v, v)
        for i in diff:
            x = (i - B) % W; y = (i - B) // W
            if y < a.height: px[x, y] = (255, 0, 0)
        im.save(a.diff_png)
