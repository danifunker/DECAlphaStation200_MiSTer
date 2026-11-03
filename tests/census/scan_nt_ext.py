#!/usr/bin/env python3
"""First cut of the NT instruction census (docs/CPU_TEST_PLAN.md 4): counts non-EV4 encodings
(BWX, FIX, CIX, MVI) and AMASK/IMPLVER inside the function bodies (.pdata) of every Alpha PE
image in an NTFS partition image's system32 and system32/drivers (needs ntfsprogs).

    scan_nt_ext.py NTFS_PARTITION_IMAGE
"""
import collections, struct, subprocess, sys

img = sys.argv[1]
def files(d):
    out = subprocess.run(['ntfsls', '-p', d, img], capture_output=True, text=True).stdout.split()
    return [d + '/' + n for n in out if n.lower().endswith(('.dll', '.exe', '.sys', '.cpl', '.drv', '.ocx'))]
def classify(w):
    op = w >> 26; fn7 = (w >> 5) & 0x7f; fn11 = (w >> 5) & 0x7ff
    if op in (0x0A, 0x0C, 0x0D, 0x0E): return 'BWX'
    if op == 0x11 and fn7 == 0x61: return 'AMASK'
    if op == 0x11 and fn7 == 0x6C: return 'IMPLVER'
    if op == 0x1C:
        if fn7 in (0x00, 0x01): return 'BWX'
        if fn7 in (0x30, 0x32, 0x33): return 'CIX'
        if fn7 in (0x70, 0x78): return 'FIX'
        if fn7 in (0x31, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F): return 'MVI'
    if op == 0x14: return 'FIX'
    return None
res = {}
for path in files('/WINNT/system32') + files('/WINNT/system32/drivers'):
    d = subprocess.run(['ntfscat', img, path], capture_output=True).stdout
    if d[:2] != b'MZ': continue
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    if d[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', d, pe+4)[0] != 0x184: continue
    nsec = struct.unpack_from('<H', d, pe+6)[0]; opt = struct.unpack_from('<H', d, pe+20)[0]
    c = collections.Counter()
    base = struct.unpack_from('<I', d, pe + 24 + 28)[0]
    secs = []
    for k in range(nsec):
        sh = pe + 24 + opt + 40 * k
        vsz, va, rsz, roff = struct.unpack_from('<IIII', d, sh + 8)
        secs.append((va, max(vsz, rsz), roff))
    def off(rva):
        for va, sz, ro in secs:
            if va <= rva < va + sz: return ro + rva - va
        return None
    prva, psz = struct.unpack_from('<II', d, pe + 24 + 96 + 8 * 3)      # the exception directory (.pdata)
    po = off(prva) if prva else None
    if po is None: continue
    for e in range(psz // 20):
        b, en = struct.unpack_from('<II', d, po + 20 * e)
        fo = off(b - base)
        if fo is None or en <= b or en - b > 0x100000: continue
        for o in range(fo, fo + (en - b) - 3, 4):
            k2 = classify(struct.unpack_from('<I', d, o)[0])
            if k2: c[k2] += 1
    if c: res[path] = c
for p, c in sorted(res.items()):
    print('%-48s %s' % (p.split('/', 2)[2], ' '.join('%s=%d' % kv for kv in sorted(c.items()))))
