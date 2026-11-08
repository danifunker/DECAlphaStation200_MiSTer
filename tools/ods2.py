#!/usr/bin/env python3
"""A minimal ODS-2 (Files-11 level 2) reader for VMS CD images and disk images.

  ods2.py IMAGE ls  [DIR...]            list a directory (default [000000])
  ods2.py IMAGE get [DIR.]NAME OUT      copy a file out (the latest version)
  ods2.py IMAGE cat [DIR.]NAME          to stdout

DIR is a dotted path, [VMS$COMMON.SYS$LDR]; the file is matched case-insensitively,
with or without the version. Only the volume's first index file header set (RVN 1,
all headers inside the index file's first extent) and format 1-3 retrieval pointers:
enough for the OpenVMS distribution CDs (the 512-byte LBN layout; an ISO-9660
hybrid's ODS-2 home block is still at LBN 1).
"""
import struct, sys

BLK = 512


class Ods2:
    def __init__(self, path):
        self.f = open(path, 'rb')
        hb = self.rd(1)
        self.cluster = struct.unpack_from('<H', hb, 14)[0]
        self.ibmapvbn = struct.unpack_from('<H', hb, 22)[0]
        self.ibmaplbn = struct.unpack_from('<I', hb, 24)[0]
        self.ibmapsize = struct.unpack_from('<H', hb, 32)[0]
        if struct.unpack_from('<H', hb, 12)[0] & 0xFF00 != 0x0200:
            raise SystemExit('not an ODS-2 home block at LBN 1 (struclev %04x)'
                             % struct.unpack_from('<H', hb, 12)[0])
        self.hdr0 = self.ibmaplbn + self.ibmapsize            # LBN of file header 1

    def rd(self, lbn, n=1):
        self.f.seek(lbn * BLK)
        return self.f.read(n * BLK)

    def header(self, fid):
        h = self.rd(self.hdr0 + fid - 1)
        if struct.unpack_from('<H', h, 8)[0] != fid:
            raise SystemExit('file header %d not where expected' % fid)
        return h

    @staticmethod
    def retrieval(h):
        """the (count, lbn) extents of a header"""
        mpoff = h[1] * 2
        n = h[58]
        w = struct.unpack_from('<%dH' % n, h, mpoff)
        out, i = [], 0
        while i < n:
            fmt = w[i] >> 14
            if fmt == 0:
                i += 1
            elif fmt == 1:
                cnt = (w[i] & 0xFF) + 1; lbn = ((w[i] >> 8) & 0x3F) << 16 | w[i + 1]
                out.append((cnt, lbn)); i += 2
            elif fmt == 2:
                cnt = (w[i] & 0x3FFF) + 1; lbn = w[i + 1] | w[i + 2] << 16
                out.append((cnt, lbn)); i += 3
            else:
                cnt = ((w[i] & 0x3FFF) << 16 | w[i + 1]) + 1; lbn = w[i + 2] | w[i + 3] << 16
                out.append((cnt, lbn)); i += 4
        return out

    def read_file(self, fid):
        h = self.header(fid)
        ra = 20
        efblk = struct.unpack_from('<H', h, ra + 8)[0] << 16 | struct.unpack_from('<H', h, ra + 10)[0]
        ffbyte = struct.unpack_from('<H', h, ra + 12)[0]
        data = b''.join(self.rd(lbn, cnt) for cnt, lbn in self.retrieval(h))
        size = (efblk - 1) * BLK + ffbyte if efblk else 0
        return data[:size]

    def listdir(self, fid):
        """[(name, version, fid)]"""
        d = self.read_file(fid)
        out = []
        for b in range(0, len(d), BLK):
            p = b
            while p < b + BLK:
                size = struct.unpack_from('<H', d, p)[0]
                if size == 0xFFFF: break
                cnt = d[p + 5]
                name = d[p + 6:p + 6 + cnt].decode('latin-1')
                q = p + 6 + ((cnt + 1) & ~1)
                while q < p + 2 + size:
                    ver, fnum, fseq, frvn = struct.unpack_from('<HHHH', d, q)
                    out.append((name, ver, fnum | (frvn & 0xFF) << 16))
                    q += 8
                p += 2 + size
        return out

    def lookup(self, dirpath, name=None):
        fid = 4                                                    # [000000]
        for part in [p for p in dirpath.strip('[]').split('.') if p and p != '000000']:
            ents = [e for e in self.listdir(fid) if e[0].upper() == part.upper() + '.DIR']
            if not ents: raise SystemExit('no directory %s' % part)
            fid = ents[0][2]
        if name is None: return fid
        nm = name.upper()
        if ';' in nm: nm, ver = nm.split(';'); ver = int(ver)
        else: ver = None
        ents = [e for e in self.listdir(fid) if e[0].upper() == nm and (ver is None or e[1] == ver)]
        if not ents: raise SystemExit('no file %s in %s' % (name, dirpath))
        return max(ents, key=lambda e: e[1])[2]


def split(spec):
    if ']' in spec:
        d, n = spec.split(']'); return d + ']', n
    return '[000000]', spec


def main():
    v = Ods2(sys.argv[1])
    cmd = sys.argv[2]
    if cmd == 'ls':
        for d in sys.argv[3:] or ['[000000]']:
            for name, ver, fid in v.listdir(v.lookup(d)):
                print('%-40s;%-3d (%d)' % (name, ver, fid))
    elif cmd in ('get', 'cat'):
        d, n = split(sys.argv[3])
        data = v.read_file(v.lookup(d, n))
        if cmd == 'get':
            open(sys.argv[4], 'wb').write(data); print('%d bytes' % len(data))
        else:
            sys.stdout.buffer.write(data)


if __name__ == '__main__':
    main()
