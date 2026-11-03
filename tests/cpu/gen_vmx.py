#!/usr/bin/env python3
"""T0 'vmx': random memory traffic through the DTB, with DTB misses (tests/cpu/README.md).

The data lives on 12 physical pages (PA 0x100000..) seen through 48 virtual pages
(VA 0x20000000 + n * 8 KB, more than the DTB's 32 entries, several VAs per physical page)
and through KSEG (SPE_2). Native DTB misses go to rt/t0_pal.h T0_DTBFILL's PAL handler,
which reads the PTE from a table at PA 0x7F0000 (written here, through KSEG, before the
traffic) and fills the DTB. Not self-checking: the native part of the retire trace is
compared with alphaemu's (tests/cpu/irq_sweep.sh, which also adds random interrupts);
the miss handler is transparent, so TB replacement and interrupts do not change it.
usage: gen_vmx.py OUT.S [seed] [ops]
"""
import random, sys

out = sys.argv[1]
rnd = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
nops = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
PA = 0x100000                                   # the data pages
NPP, NVP = 12, 48
VA = 0x20000000
PT = 0x7F0000                                   # the PTE table, one quadword per virtual page
DATA = list(range(10, 18))
pmap = [rnd.randrange(NPP) for _ in range(NVP)]
L = []
w = L.append
w('#define T0_SPE1')
w('#define T0_DTBFILL')
w('#include "t0.h"')
w('TEST_BEGIN')
w('\tlda\t$9, -1($31)')                         # $9: KSEG base (PA 0)
w('\tsll\t$9, 42, $9')
w('\tldah\t$8, %d($31)' % (VA >> 16))           # $8: the virtual region
w('\tldah\t$7, %d($9)' % (PT >> 16))            # $7: the PTE table through KSEG
for n in range(NVP):                            # PTE: PFN << 32 | KWE | KRE
    w('\tlda\t$1, %d($31)' % ((PA >> 13) + pmap[n]))
    w('\tsll\t$1, 32, $1')
    w('\tlda\t$1, 0x1100($1)')
    w('\tstq\t$1, %d($7)' % (n * 8))
w('\tmb')
for r in DATA:
    w('\tlda\t$%d, %d($31)' % (r, rnd.randrange(-32768, 32767)))
    w('\tsll\t$%d, %d, $%d' % (r, rnd.randrange(0, 40), r))
    w('\txor\t$%d, %d, $%d' % (r, rnd.randrange(0, 255), r))


def addr():
    """$22 = an address; returns the displacement to use with it"""
    line = rnd.randrange(4) * 32 + rnd.randrange(4) * 8
    if rnd.random() < 0.8:
        vp = rnd.randrange(NVP)
        off = vp * 8192 + line
        base = '$8'
    else:
        off = PA + rnd.randrange(NPP) * 8192 + line
        base = '$9'
    hi = (off + 0x8000) >> 16
    w('\tldah\t$22, %d(%s)' % (hi, base))
    return off - (hi << 16)


for _ in range(nops):
    k = rnd.random()
    d = '$%d' % rnd.choice(DATA)
    s2 = '$%d' % rnd.choice(DATA)
    if k < 0.2:
        w('\tstq\t%s, %d($22)' % (d, addr()))
    elif k < 0.4:
        w('\tldq\t%s, %d($22)' % (d, addr()))
    elif k < 0.5:
        w('\tstl\t%s, %d($22)' % (d, addr() + rnd.choice((0, 4))))
    elif k < 0.6:
        w('\tldl\t%s, %d($22)' % (d, addr() + rnd.choice((0, 4))))
    elif k < 0.7:                               # a byte or word store, EV4 style
        n = rnd.choice(('b', 'w'))
        o = addr() + (rnd.randrange(8) if n == 'b' else rnd.randrange(4) * 2)
        w('\tlda\t$22, %d($22)' % o)
        w('\tldq_u\t$18, 0($22)')
        w('\tins%sl\t%s, $22, $19' % (n, s2))
        w('\tmsk%sl\t$18, $22, $18' % n)
        w('\tbis\t$18, $19, $18')
        w('\tstq_u\t$18, 0($22)')
    elif k < 0.78:                              # a byte or word load
        n = rnd.choice(('b', 'w'))
        o = addr() + (rnd.randrange(8) if n == 'b' else rnd.randrange(4) * 2)
        w('\tlda\t$22, %d($22)' % o)
        w('\tldq_u\t$18, 0($22)')
        w('\text%sl\t$18, $22, %s' % (n, d))
    elif k < 0.84:                              # load, store, load in one line
        o = addr()
        w('\tldq\t$21, %d($22)' % (o ^ 8))
        w('\tstl\t%s, %d($22)' % (s2, o))
        w('\tldl\t%s, %d($22)' % (d, o))
    else:
        op = rnd.choice(('addq', 'subq', 'xor', 'bis', 's4addq', 'zapnot'))
        if op == 'zapnot':
            w('\tzapnot\t%s, %d, %s' % (s2, rnd.randrange(256), d))
        else:
            w('\t%s\t%s, %s, %s' % (op, '$%d' % rnd.choice(DATA), s2, d))
# a checksum of the registers and the physical pages
w('\tbis\t$31, $31, $4')
for r in DATA:
    w('\txor\t$4, $%d, $4' % r)
for p in range(NPP):
    for q in range(16):
        o = PA + p * 8192 + q * 8
        hi = (o + 0x8000) >> 16
        w('\tldah\t$22, %d($9)' % hi)
        w('\tldq\t$18, %d($22)' % (o - (hi << 16)))
        w('\taddq\t$4, $18, $4')
w('TEST_PASS')
w('TEST_END')
open(out, 'w').write('\n'.join(L) + '\n')
