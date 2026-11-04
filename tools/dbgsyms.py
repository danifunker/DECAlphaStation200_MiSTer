#!/usr/bin/env python3
"""Symbols from an NT 4.0 .DBG file (IMAGE_SEPARATE_DEBUG_HEADER + COFF symbol table):
usage: dbgsyms.py FILE.DBG [ADDR...]   prints the image base and resolves each hex ADDR"""
import struct, sys, bisect

def load(path):
    d = open(path, 'rb').read()
    sig, flags, mach, chars, ts, csum, base, size, nsec, expsz, dbgsz, secalign = struct.unpack_from('<HHHHIIIIIIII', d, 0)
    off = 0x30 + 40 * nsec + expsz
    syms = []
    for i in range(dbgsz // 28):
        chars_, ts_, maj, mn, typ, dsz, dva, dptr = struct.unpack_from('<IIHHIIII', d, off + 28 * i)
        if typ == 1:     # COFF
            nsym, lva, nlin, lvalin, lo, hi, lod, hid = struct.unpack_from('<IIIIIIII', d, dptr)
            symoff = dptr + lva; strtab = symoff + 18 * nsym
            k = 0
            while k < nsym:
                e = d[symoff + 18 * k: symoff + 18 * k + 18]
                nm = e[:8]; val, sec, typ2, cls, aux = struct.unpack_from('<IhHBB', e, 8)
                if nm[:4] == b'\0\0\0\0':
                    so = struct.unpack_from('<I', nm, 4)[0]; name = d[strtab + so: d.index(b'\0', strtab + so)].decode(errors='replace')
                else: name = nm.rstrip(b'\0').decode(errors='replace')
                if sec > 0 and cls in (2, 3, 6):     # external, static, label
                    syms.append((val, name))
                k += 1 + aux
    return base, sorted(syms)

if __name__ == '__main__':
    base, syms = load(sys.argv[1]); addrs = [a for a, _ in syms]
    print('%s: base %08x, %d symbols' % (sys.argv[1], base, len(syms)))
    for a in sys.argv[2:]:
        v = int(a, 16); r = v - base; i = bisect.bisect_right(addrs, r) - 1
        print('  %08x  %s+0x%x' % (v, syms[i][1], r - syms[i][0]) if i >= 0 else '  %08x  ?' % v)
