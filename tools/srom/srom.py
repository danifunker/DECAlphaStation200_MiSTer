#!/usr/bin/env python3
"""21064 (EV4) serial-ROM bitstream packer and decoder.

The 21064 loads its I-cache from a serial ROM after reset. Per 32-byte
I-cache block the bits arrive least-significant bit first in this order
(HRM EC-Q9ZUA-TE Table 6-21 read LSB first; AS200 Technical Information
EK-PCDSA-TI ch. 8; DEC's own packer ebtools srom.c codeToEv4()):

    LW0, LW2, LW4, LW6 (32 bits each), TAG (21), ASN (6), ASM (1), V (1),
    LW1, LW3, LW5, LW7 (32 bits each), BHT (8)            = 293 bits

LWn is the n-th longword (instruction) of the block. The bitstream is a
byte file in which bit 0 of byte 0 is the first bit shifted in.

The chip shifts 256 blocks (75,008 bits). The AS200's SROM is a Xilinx
XC1765D, a 65,536-bit serial PROM, so only 65536 // 293 = 223 whole blocks
(7136 bytes of code) fit; the remaining 197 bits of the part and whatever
the chip shifts after the end of the part fall in blocks 223..255, which
must not be valid with tag 0 (an all-zero tail gives V = 0).

Commands
    decode BITSTREAM OUT.bin [--all]
        Writes the I-cache image (the run of valid blocks from block 0, as
        DEC's dumps do; --all writes every whole block) and prints one line of
        metadata per block.
    encode IMAGE.bin OUT.bitstream [--size BITS] [--no-checksum]
        Every 32-byte block of IMAGE (the last one padded with 0x00000000, as
        DEC's srom.c pads) gets V=1, ASM=1, TAG=0, ASN=0, BHT=0. The rest of the part (default
        65,536 bits = XC1765D) is zero: V=0 blocks and a zero tail. The last
        byte of the part is the DEC 3000 SROM check byte (see checksum) unless
        --no-checksum.
    deinterleave ROM.bin OUTPREFIX
        Splits a byte-wide ROM holding 8 serial streams (bit i of every byte
        = stream i, the DEC 3000 27C512 layout) into OUTPREFIX0.bin .. 7.bin.
    checksum BITSTREAM
        Prints the DEC 3000 SROM check byte of a stream: c = 0; for every byte
        but the last: c = rotl8(c, 1) + byte (mod 256). Matches the last byte
        of all eight DEC 3000 M800 V6.1 streams.
    hex IMAGE.bin OUT.hex [--words N]
        $readmemh file of little-endian 64-bit words (one per line, word k =
        bytes 8k..8k+7), padded with zeros to N words (default 1024 = 8 KB).
"""

import argparse
import sys

BLOCK_BITS = 293
BLOCK_BYTES = 32
ICACHE_BLOCKS = 256
XC1765D_BITS = 65536


def checksum(stream: bytes) -> int:
    c = 0
    for b in stream[:-1]:
        c = ((c << 1) | (c >> 7)) & 0xFF
        c = (c + b) & 0xFF
    return c


def decode_blocks(stream: bytes):
    """Yield (lw[8], tag, asn, asm, v, bht) for each whole block."""
    n = len(stream) * 8 // BLOCK_BITS
    v_all = int.from_bytes(stream, 'little')
    for i in range(n):
        x = v_all >> (i * BLOCK_BITS)
        lw = [0] * 8

        def take(bits):
            nonlocal x
            r = x & ((1 << bits) - 1)
            x >>= bits
            return r
        for k in (0, 2, 4, 6):
            lw[k] = take(32)
        tag = take(21)
        asn = take(6)
        asm = take(1)
        v = take(1)
        for k in (1, 3, 5, 7):
            lw[k] = take(32)
        bht = take(8)
        yield lw, tag, asn, asm, v, bht


def encode_block(lw, tag=0, asn=0, asm=1, v=1, bht=0) -> int:
    fields = [(lw[0], 32), (lw[2], 32), (lw[4], 32), (lw[6], 32),
              (tag, 21), (asn, 6), (asm, 1), (v, 1),
              (lw[1], 32), (lw[3], 32), (lw[5], 32), (lw[7], 32), (bht, 8)]
    x = 0
    pos = 0
    for val, bits in fields:
        assert 0 <= val < (1 << bits)
        x |= val << pos
        pos += bits
    assert pos == BLOCK_BITS
    return x


def encode(image: bytes, size_bits=XC1765D_BITS, with_checksum=True) -> bytes:
    if len(image) % 4:
        image += bytes(4 - len(image) % 4)
    if len(image) % BLOCK_BYTES:
        image += bytes(BLOCK_BYTES - len(image) % BLOCK_BYTES)
    nblocks = len(image) // BLOCK_BYTES
    cap = size_bits // BLOCK_BITS
    if nblocks > min(cap, ICACHE_BLOCKS):
        raise SystemExit(f'image is {nblocks} blocks ({len(image)} bytes); '
                         f'the part holds {min(cap, ICACHE_BLOCKS)} '
                         f'({min(cap, ICACHE_BLOCKS) * BLOCK_BYTES} bytes)')
    x = 0
    for i in range(nblocks):
        blk = image[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES]
        lw = [int.from_bytes(blk[4 * k:4 * k + 4], 'little') for k in range(8)]
        x |= encode_block(lw) << (i * BLOCK_BITS)
    out = bytearray(x.to_bytes(size_bits // 8, 'little'))
    if with_checksum:
        if nblocks * BLOCK_BITS > size_bits - 8:
            raise SystemExit('no room for the check byte; use --no-checksum')
        out[-1] = checksum(bytes(out))
    return bytes(out)


def cmd_decode(a):
    stream = open(a.bitstream, 'rb').read()
    words = []
    valid_run = True
    nvalid = 0
    for i, (lw, tag, asn, asm, v, bht) in enumerate(decode_blocks(stream)):
        print('%04x: TAG %6X, V %X, ASN %2X, ASM %X, BHT %2X'
              % (i * BLOCK_BYTES, tag, v, asn, asm, bht))
        valid_run = valid_run and v == 1
        if valid_run:
            nvalid += 1
        if valid_run or a.all:
            words += lw
    with open(a.out, 'wb') as f:
        for w in words:
            f.write(w.to_bytes(4, 'little'))
    nbits = len(stream) * 8
    nb = nbits // BLOCK_BITS
    print(f'# {nbits} bits = {nb} whole blocks + {nbits - nb * BLOCK_BITS} bits; '
          f'{nvalid} valid blocks from 0 ({nvalid * BLOCK_BYTES} bytes); '
          f'check byte {stream[-1]:02x}, computed {checksum(stream):02x}')


def cmd_encode(a):
    image = open(a.image, 'rb').read()
    out = encode(image, a.size, not a.no_checksum)
    open(a.out, 'wb').write(out)
    nb = (len(image) + BLOCK_BYTES - 1) // BLOCK_BYTES
    print(f'{a.image}: {len(image)} bytes, {nb} blocks -> {a.out}: '
          f'{len(out) * 8} bits, check byte {out[-1]:02x}')


def cmd_deinterleave(a):
    rom = open(a.rom, 'rb').read()
    if len(rom) % 8:
        raise SystemExit('ROM size must be a multiple of 8 bytes')
    for i in range(8):
        out = bytearray(len(rom) // 8)
        for j, b in enumerate(rom):
            if (b >> i) & 1:
                out[j >> 3] |= 1 << (j & 7)
        open(f'{a.prefix}{i}.bin', 'wb').write(out)


def cmd_checksum(a):
    s = open(a.bitstream, 'rb').read()
    c = checksum(s)
    print(f'{c:02x} (last byte {s[-1]:02x}: {"match" if c == s[-1] else "MISMATCH"})')
    return 0 if c == s[-1] else 1


def cmd_hex(a):
    image = open(a.image, 'rb').read()
    if len(image) > a.words * 8:
        raise SystemExit(f'image is {len(image)} bytes, more than {a.words} words')
    image += bytes(a.words * 8 - len(image))
    with open(a.out, 'w') as f:
        for k in range(a.words):
            f.write('%016x\n' % int.from_bytes(image[8 * k:8 * k + 8], 'little'))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('decode')
    d.add_argument('bitstream')
    d.add_argument('out')
    d.add_argument('--all', action='store_true')
    d.set_defaults(fn=cmd_decode)
    e = sub.add_parser('encode')
    e.add_argument('image')
    e.add_argument('out')
    e.add_argument('--size', type=int, default=XC1765D_BITS,
                   help='part size in bits (default 65536, XC1765D)')
    e.add_argument('--no-checksum', action='store_true')
    e.set_defaults(fn=cmd_encode)
    i = sub.add_parser('deinterleave')
    i.add_argument('rom')
    i.add_argument('prefix')
    i.set_defaults(fn=cmd_deinterleave)
    c = sub.add_parser('checksum')
    c.add_argument('bitstream')
    c.set_defaults(fn=cmd_checksum)
    h = sub.add_parser('hex')
    h.add_argument('image')
    h.add_argument('out')
    h.add_argument('--words', type=int, default=1024)
    h.set_defaults(fn=cmd_hex)
    a = p.parse_args(argv)
    return a.fn(a) or 0


if __name__ == '__main__':
    sys.exit(main())
