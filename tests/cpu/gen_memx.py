#!/usr/bin/env python3
"""T0 'memx': a random memory stress suite for the D-cache (tests/cpu/README.md).

Thousands of loads and stores (quadword, longword, and the EV4 byte/word sequences:
ldq_u/ext, ldq_u/ins/msk/stq_u) on a few lines that collide in the 8 KB direct-mapped
D-cache (8 KB apart), through two superpages: SPE_2 (KSEG, 0xFFFFFC00_00000000 + PA) and
SPE_1 (0xFFFFFFFF_80000000 + PA<29:0>) aliasing the same physical lines. Stores land right
behind missing loads and evictions. Not self-checking: the retire trace is compared with
alphaemu's (make -C verilator memx).  usage: gen_memx.py OUT.S [seed] [ops]
"""
import random, sys

out = sys.argv[1]
rnd = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
nops = int(sys.argv[3]) if len(sys.argv) > 3 else 4000
PA = 0x100000                                   # the data region
DATA = list(range(10, 18))                      # $10-$17 data
L = []
w = L.append
w('#define T0_SPE1')
w('#include "t0.h"')
w('TEST_BEGIN')
# $9: the region through SPE_2 (KSEG); $8: the same through SPE_1
w('\tlda\t$9, -1($31)')
w('\tsll\t$9, 42, $9')
w('\tldah\t$1, %d($31)' % (PA >> 16))
w('\tbis\t$9, $1, $9')
w('\tldah\t$8, -32768($31)')                    # 0xFFFFFFFF80000000
w('\tbis\t$8, $1, $8')
for r in DATA:                                  # seed values
    w('\tlda\t$%d, %d($31)' % (r, rnd.randrange(-32768, 32767)))
    w('\tsll\t$%d, %d, $%d' % (r, rnd.randrange(0, 40), r))
    w('\txor\t$%d, %d, $%d' % (r, rnd.randrange(0, 255), r))

def off():
    # 4 aliasing slots (8 KB apart) x 3 lines x 4 quadwords, plus a byte offset
    return rnd.randrange(4) * 8192 + rnd.randrange(3) * 32 + rnd.randrange(4) * 8

def base():
    return '$9' if rnd.random() < 0.5 else '$8'

for _ in range(nops):
    k = rnd.random()
    d = '$%d' % rnd.choice(DATA)
    s2 = '$%d' % rnd.choice(DATA)
    b = base()
    o = off()
    if k < 0.18:
        w('\tstq\t%s, %d(%s)' % (d, o, b))
    elif k < 0.36:
        w('\tldq\t%s, %d(%s)' % (d, o, b))
    elif k < 0.46:
        w('\tstl\t%s, %d(%s)' % (d, o + rnd.choice((0, 4)), b))
    elif k < 0.56:
        w('\tldl\t%s, %d(%s)' % (d, o + rnd.choice((0, 4)), b))
    elif k < 0.66:                              # a byte or word store, EV4 style
        n = rnd.choice(('b', 'w'))
        bo = o + (rnd.randrange(8) if n == 'b' else rnd.randrange(4) * 2)
        w('\tlda\t$22, %d(%s)' % (bo, b))
        w('\tldq_u\t$18, 0($22)')
        w('\tins%sl\t%s, $22, $19' % (n, s2))
        w('\tmsk%sl\t$18, $22, $18' % n)
        w('\tbis\t$18, $19, $18')
        w('\tstq_u\t$18, 0($22)')
    elif k < 0.74:                              # a byte or word load
        n = rnd.choice(('b', 'w'))
        bo = o + (rnd.randrange(8) if n == 'b' else rnd.randrange(4) * 2)
        w('\tlda\t$22, %d(%s)' % (bo, b))
        w('\tldq_u\t$18, 0($22)')
        w('\text%sl\t$18, $22, %s' % (n, d))
    elif k < 0.80:                              # store then load the same address at once
        w('\tstq\t%s, %d(%s)' % (s2, o, b))
        w('\tldq\t%s, %d(%s)' % (d, o, '$8' if b == '$9' else '$9'))
    elif k < 0.85:                              # load-miss, store into the line, load it back
        w('\tldq\t$21, %d(%s)' % (o ^ 8, b))
        w('\tstl\t%s, %d(%s)' % (s2, o, b))
        w('\tldl\t%s, %d(%s)' % (d, o, b))
    else:                                       # arithmetic on the data
        op = rnd.choice(('addq', 'subq', 'xor', 'bis', 's4addq', 'zapnot'))
        if op == 'zapnot':
            w('\tzapnot\t%s, %d, %s' % (s2, rnd.randrange(256), d))
        else:
            w('\t%s\t%s, %s, %s' % (op, '$%d' % rnd.choice(DATA), s2, d))
# a checksum of the registers and the region into $4, so a difference shows at the end too
w('\tbis\t$31, $31, $4')
for r in DATA:
    w('\txor\t$4, $%d, $4' % r)
for slot in range(4):
    for q in range(12):
        w('\tldq\t$18, %d($9)' % (slot * 8192 + q * 8))
        w('\taddq\t$4, $18, $4')
w('TEST_PASS')
w('TEST_END')
open(out, 'w').write('\n'.join(L) + '\n')
