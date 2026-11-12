#!/usr/bin/env python3
"""Conditional branches right behind the instruction that writes their register (make -C verilator
bpstress, after bp_stress): the pipelined core takes the branch's flags from a carry-free zero test
of the fast result (rtl/cpu/ev4_core.v, fz / fsg; docs/design/cpu-perf.md 9). Every producer kind
(ADDL ADDQ SUBL SUBQ LDA LDAH AND BIC BIS ORNOT XOR EQV, register and literal forms) followed at
once by each of the eight integer branches, on operands picked to make the 64-bit and the 32-bit
results zero, all ones, the sign bit and their neighbours, branching forward (predicted not taken)
and backward (predicted taken). The image runs on tools/alphaemu (-P) and the core's retire trace
must equal alphaemu's (tests/cpu/bp_stress.sh with GEN=brz_stress.py); the taken / not-taken
history is shifted into a checksum stored at TOHOST + 8 / + 16.

  brz_stress.py SEED OUT.bin
"""
import sys, os, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from alphaasm import Prog

seed, out = int(sys.argv[1]), sys.argv[2]
rnd = random.Random(seed)
p = Prog()
T0, T1, T2, T3 = 1, 2, 3, 4
S0, S1, S5, GP = 9, 10, 14, 29
M = (1 << 64) - 1
CB = (0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F)     # BLBC BEQ BLT BLE BLBS BNE BGE BGT
# (opcode, function, kind): 1 add, 2 subtract, 3 logical
OPS = [(0x10, 0x00, 'addl'), (0x10, 0x20, 'addq'), (0x10, 0x09, 'subl'), (0x10, 0x29, 'subq'),
       (0x11, 0x00, 'and'), (0x11, 0x08, 'bic'), (0x11, 0x20, 'bis'), (0x11, 0x28, 'ornot'),
       (0x11, 0x40, 'xor'), (0x11, 0x48, 'eqv'), ('lda', 0, 'lda'), ('ldah', 0, 'ldah')]
EDGE = [0, 1, 2, 3, M, M - 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x100000000, 0xFFFFFFFF00000000,
        0x8000000000000000, 0x7FFFFFFFFFFFFFFF, 0x0000000100000001, 0xFFFFFFFF80000000, 0x80000001,
        0x00000000FFFF0000, 0xFFFFFFFFFFFF8000, 0x8000, 0x10000]


def val():
    r = rnd.random()
    if r < 0.6: return rnd.choice(EDGE)
    if r < 0.8: return rnd.getrandbits(64)
    return rnd.getrandbits(rnd.choice((8, 16, 31, 32, 33)))


def partner(a, name):
    """b for a: often the one that makes the result (or its low longword) zero, all ones or a sign"""
    r = rnd.random()
    if name in ('addq', 'addl'):
        c = [(-a) & M, (-a + (1 << 32)) & M, (-a - 1) & M, (-a + 1) & M, (-a + (1 << 63)) & M]
    elif name in ('subq', 'subl'):
        c = [a, a ^ (1 << 32), (a + 1) & M, (a - 1) & M, a ^ (1 << 63), a ^ 0xFFFFFFFF00000000]
    else:
        c = [a, ~a & M, 0, M, a ^ (1 << 63), (~a & M) ^ 1]
    return rnd.choice(c) if r < 0.6 else val()


# the operand table: pairs of quadwords at GP
cases = []
for i in range(1400):
    op = OPS[i % len(OPS)]
    a = val()
    b = partner(a, op[2])
    cases.append((op, a, b, CB[(i // len(OPS)) % 8] if i < 96 * 8 else rnd.choice(CB), rnd.random() < 0.3,
                  rnd.random() < 0.35))

p.org(0); p.br(31, 'init')
for off in (0x20, 0x60, 0xE0, 0x1E0, 0x3E0, 0x7E0, 0x8E0, 0x9E0, 0x11E0, 0x13E0, 0x17E0):
    p.org(off); p.lda(0, 31, off >> 4); p.br(31, 'trap')
p.org(0x3000); p.label('trap')
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16)
p.sll(0, 0, 1, 1); p.bis(1, 1, 1, 1)
p.hw_stq_p(1, 0, 6)
p.label('spin0'); p.br(31, 'spin0')

p.org(0x4000); p.label('init')
p.lda(1, 31, 0x420); p.hw_mtpr(1, 0x4e)                    # ABOX_CTL: DC_ENA | SPE_2
p.lda(1, 31, 3); p.sll(1, 1, 1, 41); p.hw_mtpr(1, 0x22)    # ICCSR: FPE (42), MAP (41)
p.hw_mtpr(31, 0x29)                                        # PS: kernel
p.lda(S5, 31, -1); p.sll(S5, S5, S5, 42)                   # KSEG base
p.lda(2, 31, 0x6000); p.bis(2, S5, 2)
p.hw_mtpr(2, 0x24)                                         # EXC_ADDR
p.nop(); p.nop(); p.nop()
p.hw_rei()

p.org(0x6000)
p.lda(GP, 31, 0x10); p.sll(GP, GP, GP, 16); p.bis(GP, S5, GP)   # GP = KSEG + 0x100000
p.bis(31, 31, S0); p.bis(31, 31, S1)
for n, (op, a, b, cb, lit, back) in enumerate(cases):
    o = 16 * (n % 2048)
    if o > 32760:
        p.lda(T3, GP, 0); p.ldah(T3, T3, o >> 16); o = o & 0xFFFF
        base = T3
    else:
        base = GP
    p.ldq(T0, o, base); p.ldq(T1, o + 8, base)
    p.sll(S0, 31, S0, 1)                                   # the history: taken 0, not taken 1
    p.addq(S1, T0, S1); p.xor(S1, T1, S1)
    skip, top, after = 'k%d' % n, 'b%d' % n, 'a%d' % n
    if back:
        p.br(31, after + 'f')
        p.label(top)
        p.addq(S1, 31, S1, 3)                              # the backward branch's target
        p.br(31, after)
        p.label(after + 'f')
    # the producer, then the branch at once
    if op[0] in ('lda', 'ldah'):
        # the displacement that cancels the operand's low (LDA) or next (LDAH) 16 bits, or another
        h = (a >> (16 if op[0] == 'ldah' else 0)) & 0xFFFF
        d = h - 0x10000 if h & 0x8000 else h
        d = -d if lit and d != -0x8000 else (d if rnd.random() < 0.5 else rnd.randrange(-0x8000, 0x8000))
        (p.lda if op[0] == 'lda' else p.ldah)(T2, T0, d)
    elif lit:
        p.opr(op[0], op[1], T0, 31, T2, b & 0xFF)
    else:
        p.opr(op[0], op[1], T0, T1, T2)
    if back:
        p.bra(cb, T2, top)
    else:
        p.bra(cb, T2, skip)
    p.addq(S0, 31, S0, 1)
    p.addq(S1, T2, S1)
    if back:
        p.label(after)
    else:
        p.label(skip)
    p.addq(S1, T2, S1); p.sll(S1, 31, T3, 7); p.xor(S1, T3, S1)
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16); p.bis(6, S5, 6)
p.stq(S0, 8, 6); p.stq(S1, 16, 6)
p.lda(1, 31, 1); p.stq(1, 0, 6)
p.label('spin'); p.br(31, 'spin')

# the data, past the code: GP = KSEG + 0x100000 (PA 0x100000)
p.org(0x100000)
for n, (op, a, b, cb, lit, back) in enumerate(cases[:2048]):
    p.quad(a); p.quad(b)

open(out, 'wb').write(p.assemble())
