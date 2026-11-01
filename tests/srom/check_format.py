#!/usr/bin/env python3
"""Check tools/srom/srom.py against the DEC 3000 M800 SROM V6.1 dump.

    python3 -I tests/srom/check_format.py scratch/roms/dec3000_m800_srom6.1

1. full-srom.bin (27C512, 8 interleaved streams) -> deinterleave: every stream
   equals bitstreams/srom<i>-bitstream.bin.
2. decode(stream i) equals images/srom<i>-image.bin byte for byte.
3. encode(decode(stream)) reproduces every valid block of the stream bit for
   bit (V=1 blocks with TAG/ASN/ASM/BHT as DEC set them: all 0/0/1/0).
4. The stream's last byte is the rotate-add check byte.
5. encode(decode(stream)) with the default zero padding and check byte equals
   the whole stream (DEC padded with V=0 zero blocks and a zero tail).
Exits 0 when all pass; prints SKIP and exits 0 if the dump is absent.
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools', 'srom'))
import srom  # noqa: E402


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        HERE, '..', '..', 'scratch', 'roms', 'dec3000_m800_srom6.1')
    full = os.path.join(d, 'full-srom.bin')
    if not os.path.exists(full):
        print('SKIP: no', full)
        return 0
    fails = 0
    with tempfile.TemporaryDirectory() as t:
        srom.main(['deinterleave', full, os.path.join(t, 's')])
        for i in range(8):
            s = open(os.path.join(t, f's{i}.bin'), 'rb').read()
            ref_bs = open(os.path.join(d, 'bitstreams', f'srom{i}-bitstream.bin'), 'rb').read()
            ref_im = open(os.path.join(d, 'images', f'srom{i}-image.bin'), 'rb').read()
            blocks = list(srom.decode_blocks(s))
            image = b''
            for lw, tag, asn, asm, v, bht in blocks:
                if v != 1:
                    break
                image += b''.join(w.to_bytes(4, 'little') for w in lw)
            nv = len(image) // 32
            # 3: re-encode the valid blocks and compare the bits they occupy
            enc = srom.encode(image, len(s) * 8, with_checksum=False)
            mask = (1 << (nv * srom.BLOCK_BITS)) - 1
            re_ok = (int.from_bytes(enc, 'little') & mask) == (int.from_bytes(s, 'little') & mask)
            meta = {(tag, asn, asm, bht) for lw, tag, asn, asm, v, bht in blocks[:nv]}
            whole = srom.encode(image, len(s) * 8) == s
            ok = [s == ref_bs, image == ref_im, re_ok, srom.checksum(s) == s[-1], whole]
            print(f'stream {i}: {nv:3d} valid blocks, meta {sorted(meta)}, '
                  f'bitstream {"ok" if ok[0] else "FAIL"}, image {"ok" if ok[1] else "FAIL"}, '
                  f're-encode {"ok" if ok[2] else "FAIL"}, check byte {s[-1]:02x} '
                  f'{"ok" if ok[3] else "FAIL"}, whole stream {"ok" if ok[4] else "FAIL"}')
            fails += ok.count(False)
    print('PASS' if not fails else f'FAIL ({fails})')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
