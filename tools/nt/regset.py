#!/usr/bin/env python3
"""Set an inline REG_DWORD in an NT hive in place: regset.py HIVE KEYPATH VALUENAME NEWVALUE"""
import struct, sys, importlib.util

spec = importlib.util.spec_from_file_location('regf', __file__.replace('regset.py', 'regf.py'))
hive, path, vname, newv = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4], 0)
d = bytearray(open(hive, 'rb').read())
B = 0x1000


def cell(o):
    return B + o + 4


def nk(o):
    c = cell(o)
    assert d[c:c + 2] == b'nk'
    return (d[c + 0x4C:c + 0x4C + struct.unpack_from('<H', d, c + 0x48)[0]].decode('latin1'),
            struct.unpack_from('<I', d, c + 0x14)[0], struct.unpack_from('<I', d, c + 0x1C)[0],
            struct.unpack_from('<I', d, c + 0x24)[0], struct.unpack_from('<I', d, c + 0x28)[0])


def subkeys(o):
    _, n, sl, _, _ = nk(o)
    out = []
    if n == 0:
        return out
    c = cell(sl)
    sig = bytes(d[c:c + 2]); cnt = struct.unpack_from('<H', d, c + 2)[0]
    step = 8 if sig in (b'lf', b'lh') else 4
    for i in range(cnt):
        out.append(struct.unpack_from('<I', d, c + 4 + step * i)[0])
    return out


k = struct.unpack_from('<I', d, 0x24)[0]
for part in [p for p in path.split('\\') if p]:
    k = next(s for s in subkeys(k) if nk(s)[0].lower() == part.lower())
_, _, _, nval, vl = nk(k)
for i in range(nval):
    vo = struct.unpack_from('<I', d, cell(vl) + 4 * i)[0]
    c = cell(vo)
    nlen, dlen, doff, typ = struct.unpack_from('<HIII', d, c + 2)
    if d[c + 0x14:c + 0x14 + nlen].decode('latin1').lower() == vname.lower():
        assert typ == 4 and dlen == 0x80000004, (typ, hex(dlen))
        print('%s: %#x -> %#x' % (vname, doff, newv))
        struct.pack_into('<I', d, c + 8, newv)
        open(hive, 'wb').write(d)
        break
else:
    sys.exit('value not found')
