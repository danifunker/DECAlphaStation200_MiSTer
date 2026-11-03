#!/usr/bin/env python3
"""Minimal NT registry hive reader: regf.py HIVE PATH  (lists subkeys and values of PATH)."""
import struct, sys

d = open(sys.argv[1], 'rb').read()
B = 0x1000


def cell(off):
    return B + off + 4


def nk(off):
    c = cell(off)
    assert d[c:c + 2] == b'nk', hex(off)
    nsub = struct.unpack_from('<I', d, c + 0x14)[0]
    subl = struct.unpack_from('<I', d, c + 0x1C)[0]
    nval = struct.unpack_from('<I', d, c + 0x24)[0]
    vall = struct.unpack_from('<I', d, c + 0x28)[0]
    nlen = struct.unpack_from('<H', d, c + 0x48)[0]
    name = d[c + 0x4C:c + 0x4C + nlen].decode('latin1')
    return name, nsub, subl, nval, vall


def subkeys(off):
    name, nsub, subl, nval, vall = nk(off)
    if nsub == 0:
        return []
    out = []

    def walk(lo):
        c = cell(lo)
        sig = d[c:c + 2]
        n = struct.unpack_from('<H', d, c + 2)[0]
        if sig in (b'lf', b'lh'):
            for i in range(n):
                out.append(struct.unpack_from('<I', d, c + 4 + 8 * i)[0])
        elif sig in (b'li',):
            for i in range(n):
                out.append(struct.unpack_from('<I', d, c + 4 + 4 * i)[0])
        elif sig == b'ri':
            for i in range(n):
                walk(struct.unpack_from('<I', d, c + 4 + 4 * i)[0])
    walk(subl)
    return out


def values(off):
    name, nsub, subl, nval, vall = nk(off)
    res = []
    for i in range(nval):
        vo = struct.unpack_from('<I', d, cell(vall) + 4 * i)[0]
        c = cell(vo)
        nlen, dlen, doff, typ = struct.unpack_from('<HIII', d, c + 2)
        vname = d[c + 0x14:c + 0x14 + nlen].decode('latin1') or '(default)'
        if dlen & 0x80000000:
            data = struct.pack('<I', doff)[:dlen & 0x7fffffff]
        else:
            data = d[cell(doff):cell(doff) + dlen]
        if typ in (1, 2, 7):
            v = data.decode('utf-16le', 'replace').rstrip('\0')
        elif typ == 4:
            v = hex(struct.unpack_from('<I', data)[0]) if len(data) >= 4 else data.hex()
        else:
            v = data[:64].hex()
        res.append((vname, typ, v))
    return res


root = struct.unpack_from('<I', d, 0x24)[0]
k = root
for part in [p for p in sys.argv[2].split('\\') if p]:
    for s in subkeys(k):
        if nk(s)[0].lower() == part.lower():
            k = s
            break
    else:
        sys.exit('no key ' + part)
for s in subkeys(k):
    print('[%s]' % nk(s)[0])
for vname, typ, v in values(k):
    print('%s (%d) = %s' % (vname, typ, v))
