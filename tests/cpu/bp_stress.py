#!/usr/bin/env python3
"""Control-flow stress for the pipelined core's branch prediction (make -C verilator bpstress):
a pseudo-random program of nested counted loops, data-dependent branches of every kind (on an
ALU result, a compare, a load, an old register), calls by BSR, JSR through a table and
JSR_COROUTINE, returns by RET, JMP, JSR_COROUTINE and through another register, a function that
returns past two instructions of its caller (they spoil the checksum if they retire), a
recursion deeper than the return stack, a computed JMP, and BSR used as a plain jump (the
return stack goes out of step). About 12 KB of code (the I-cache is 8 KB). No reference in this
script: the image runs on tools/alphaemu (-P) and the core's retire trace must equal alphaemu's
line for line (tests/cpu/bp_stress.sh); with random interrupts, where the traces differ by the
handler, the checksums stored at TOHOST + 8 / + 16 must.

  bp_stress.py SEED OUT.bin
"""
import sys, os, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from alphaasm import Prog

seed, out = int(sys.argv[1]), sys.argv[2]
rnd = random.Random(seed)
p = Prog()
T0, T1, T2, T3, T5 = 1, 2, 3, 4, 6
S0, S1, C0, C1, S5, TB, A0, RA, PV, GP, SP = 9, 10, 11, 12, 14, 15, 16, 26, 27, 29, 30
CNT = (C0, C1)
CB = (0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F)     # BLBC BEQ BLT BLE BLBS BNE BGE BGT
NF = 18
TABLE = 0x20000
nlab = 0


def new():
    global nlab
    nlab += 1
    return 'L%d' % nlab


def jmp(ra, rb, hint):
    p.word((0x1A << 26) | (ra << 21) | (rb << 16) | (hint << 14))


p.org(0); p.br(31, 'init')
def vec(off, code):
    p.org(off); p.lda(0, 31, code); p.br(31, 'fail')
vec(0x0020, 78); vec(0x0060, 77)
p.org(0x00E0)                                              # INTERRUPT: the bench's irq_h[0], transparent
p.hw_mtpr(1, 0x80)
p.lda(1, 31, 0x70); p.sll(1, 1, 1, 16)
p.hw_stq_p(31, 0, 1)
p.hw_mfpr(1, 0x80)
p.hw_rei()
vec(0x01E0, 78); vec(0x03E0, 78); vec(0x07E0, 78); vec(0x08E0, 78); vec(0x09E0, 78)
vec(0x11E0, 78); vec(0x13E0, 78); vec(0x17E0, 78)
p.org(0x3000); p.label('fail')
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16)
p.hw_stq_p(0, 0, 6)
p.label('spin0'); p.br(31, 'spin0')

p.org(0x4000); p.label('init')
p.lda(1, 31, 0x420); p.hw_mtpr(1, 0x4e)                    # ABOX_CTL: DC_ENA | SPE_2
p.lda(1, 31, 1); p.sll(1, 1, 1, 41); p.hw_mtpr(1, 0x22)    # ICCSR: MAP
p.hw_mtpr(31, 0x29)                                        # PS: kernel
p.lda(1, 31, 0x200); p.hw_mtpr(1, 0x30)                    # HIER: irq_h[0]
p.lda(S5, 31, -1); p.sll(S5, S5, S5, 42)                   # KSEG base
p.lda(2, 31, 0x6000); p.bis(2, S5, 2)
p.hw_mtpr(2, 0x24)                                         # EXC_ADDR
p.nop(); p.nop(); p.nop()
p.hw_rei()


class Ctx:
    def __init__(self, fi, cap, leaf):
        self.fi, self.cap, self.leaf = fi, cap, leaf
        self.mult, self.cost, self.ld = 1, 0, 0


cost = [0] * NF
kind = [None] * NF


def mix(k):
    p.sll(S1, 31, T0, 13); p.xor(S1, T0, S1); p.srl(S1, 31, T0, 7); p.xor(S1, T0, S1)
    p.sll(S1, 31, T0, 17); p.xor(S1, T0, S1)
    p.addq(S0, S0, T0); p.xor(T0, S1, S0); p.lda(S0, S0, k)


def simple(c):
    r = rnd.randrange(8)
    if r < 2:
        mix(rnd.randrange(1, 0x7000))
    elif r < 4:
        p.lda(S0, S0, rnd.randrange(1, 0x7000))
    elif r == 4:
        p.stq(rnd.choice((S0, S1)), rnd.randrange(-0x1000, 0x1000) * 8, GP)
    elif r == 5:
        p.ldq(T1, rnd.randrange(-0x1000, 0x1000) * 8, GP); p.addq(S0, T1, S0)
    elif r == 6:
        a, b = rnd.choice((S0, S1, T1, T3)), rnd.choice((S0, S1, T1, T3))
        rnd.choice((p.addq, p.subq, p.xor, p.bis, p.cmpult, p.cmpeq))(a, b, T3)
        p.addq(S0, S0, T0); p.addq(T0, T3, S0)
    else:
        for k in range(rnd.randrange(1, 4)): p.nop()


def prep():
    """A value to branch on; returns its register."""
    k = rnd.randrange(6)
    if k == 0:
        p.and_(S1, 31, T2, rnd.randrange(1, 16)); r = T2
    elif k == 1:
        p.srl(S1, 31, T2, rnd.randrange(1, 40)); p.and_(T2, 31, T2, 0xFF)
        p.cmpult(T2, 31, T2, rnd.randrange(256)); r = T2
    elif k == 2:
        p.ldq(T2, rnd.randrange(-0x1000, 0x1000) * 8, GP)
        if rnd.random() < 0.5: p.xor(T2, S1, T2)
        r = T2
    elif k == 3:
        p.subq(S1, S0, T2); r = T2
    elif k == 4:
        p.cmpeq(S1, S0, T2); r = T2                         # nearly always 0
    else:
        r = rnd.choice((S0, S1))
    for k in range(rnd.choice((0, 0, 0, 1, 2))):
        rnd.choice((p.nop, lambda: p.lda(S0, S0, 3)))()
    return r


def gen_if(c):
    r = prep()
    l1, l2 = new(), new()
    p.bra(rnd.choice(CB), r, l1)
    block(c, rnd.randrange(1, 4))
    if rnd.random() < 0.4:
        p.br(31, l2); p.label(l1); block(c, rnd.randrange(1, 3)); p.label(l2)
    else:
        p.label(l1)
    c.cost += c.mult * 6


def gen_loop(c):
    cnt = CNT[c.ld]
    if rnd.random() < 0.5:
        n = rnd.randrange(1, 6); p.lda(cnt, 31, n)
    else:
        n = 4; p.and_(S1, 31, cnt, 3); p.addq(cnt, 31, cnt, 1)
    top, done = new(), new()
    p.label(top)
    c.mult *= n; c.ld += 1
    block(c, rnd.randrange(1, 5))
    c.ld -= 1
    v = rnd.randrange(4)
    p.subq(cnt, 31, cnt, 1)
    if v == 0:
        p.bne(cnt, top)
    elif v == 1:
        p.bra(0x3F, cnt, top)                               # BGT
    elif v == 2:
        p.beq(cnt, done); p.br(31, top); p.label(done)
    else:                                                   # leaves early on data
        p.beq(cnt, done); r = prep(); p.bra(rnd.choice(CB), r, top); p.label(done)
    c.cost += c.mult * 8
    c.mult //= n


def gen_call(c):
    if rnd.random() < 0.15 and c.cost + c.mult * 150 < c.cap:
        n = rnd.randrange(2, 10)
        p.lda(A0, 31, n); p.bsr(RA, 'frec'); c.cost += c.mult * 16 * n
        return
    cands = [j for j in range(c.fi + 1, NF) if c.cost + c.mult * (cost[j] + 4) < c.cap]
    if not cands:
        p.lda(S0, S0, 0x11); return
    j = rnd.choice(cands); c.cost += c.mult * (cost[j] + 4)
    v = rnd.randrange(5)
    if v < 2:
        p.bsr(RA, 'f%d' % j)
    elif v == 2:
        p.ldq(PV, 8 * j, TB); p.jsr(RA, PV)
    elif v == 3:
        p.ldq(PV, 8 * j, TB); p.nop(); jmp(RA, PV, 3)       # JSR_COROUTINE as a call
    else:
        p.ldq(PV, 8 * j, TB); p.lda(S0, S0, 5); jmp(RA, PV, 0)   # a call with JMP's hint
    if kind[j] == 'skip':                                   # never run: the callee returns past them
        p.lda(S0, S0, 0x7001); p.lda(S1, S1, 0x7003)


def gen_switch(c):
    cases = [new() for k in range(4)]
    tab, end = new(), new()
    p.and_(S1, 31, T2, 3); p.sll(T2, 31, T2, 3)
    p.br(T5, tab)                                           # T5 = the table's address, or 4 below
    p.align(8)
    for k in cases:
        p._emit(lambda pc, k=k: p.labels[k] & 0xFFFFFFFF); p.long(0xFFFFFC00)
    p.label(tab)
    p.lda(T5, T5, 4); p.opr(0x11, 0x08, T5, 31, T5, 7)      # BIC: up to the quadword
    p.addq(T5, T2, T5); p.ldq(T5, 0, T5); jmp(31, T5, rnd.choice((0, 0, 2)))
    for k in cases:
        p.label(k); p.lda(S0, S0, rnd.randrange(1, 0x7000))
        if rnd.random() < 0.5: simple(c)
        if k != cases[-1]: p.br(31, end)
    p.label(end)
    c.cost += c.mult * 12


def gen_odd(c):
    r = rnd.randrange(3)
    l = new()
    if r == 0:
        p.bsr(T5, l); p.label(l); p.addq(S0, T5, S0)        # BSR as a jump: pushes, never returns
    elif r == 1:
        p.br(T5, l); p.lda(S0, S0, 0x7005); p.label(l); p.addq(S0, T5, S0)
    else:
        p.br(31, l); p.lda(S0, S0, 0x7007); p.lda(S0, S0, 0x7009); p.label(l)


def block(c, n):
    for k in range(n):
        n0 = len(p.items)
        r = rnd.random()
        if r < 0.40 or len(p.items) > 20000:
            simple(c)
        elif r < 0.62:
            gen_if(c); continue
        elif r < 0.74 and not c.leaf and c.ld < 2:
            gen_loop(c); continue
        elif r < 0.88 and not c.leaf:
            gen_call(c)
        elif r < 0.93:
            gen_switch(c); continue
        else:
            gen_odd(c)
        c.cost += c.mult * (len(p.items) - n0)


def gen_fn(i):
    k = kind[i]
    c = Ctx(i, 2500, k != 'frame')
    p.label('f%d' % i)
    if k == 'frame':
        p.lda(SP, SP, -32); p.stq(RA, 0, SP); p.stq(C0, 8, SP); p.stq(C1, 16, SP)
    block(c, rnd.randrange(3, 9))
    r = RA
    if k == 'frame':
        v = rnd.randrange(3)
        if v == 0: p.ldq(RA, 0, SP)
        p.ldq(C0, 8, SP); p.ldq(C1, 16, SP)
        if v == 1: p.ldq(RA, 0, SP)
        p.lda(SP, SP, 32)
        if v == 2: p.ldq(RA, -32, SP)                       # the load right before the return
    if k == 'skip': p.lda(RA, RA, 8)
    v = rnd.randrange(6)
    if v < 3: p.ret(RA)
    elif v == 3: jmp(31, RA, 0)
    elif v == 4: jmp(31, RA, 3)
    else: p.bis(RA, RA, T5); p.ret(T5)
    cost[i] = c.cost + 12


p.org(0x6000)
p.lda(GP, 31, 0x40); p.sll(GP, 31, GP, 16); p.bis(GP, S5, GP)
p.lda(GP, GP, 0x4000); p.lda(GP, GP, 0x4000)               # scratch: PA 0x400000 +- 32 KB
p.lda(SP, 31, 0x50); p.sll(SP, 31, SP, 16); p.bis(SP, S5, SP)   # stack below PA 0x500000
p.lda(TB, 31, TABLE >> 16); p.sll(TB, 31, TB, 16); p.bis(TB, S5, TB)
p.lda(S0, 31, 0x1234); p.lda(S1, 31, 0x5A5A + seed); p.sll(S1, 31, S1, 20); p.lda(S1, S1, 0x1357)
p.br(31, 'main')

# the recursion: A0 levels down, a checksum step on the way in and on the way out
p.label('frec')
p.lda(SP, SP, -16); p.stq(RA, 0, SP)
p.lda(S0, S0, 0x21)
p.beq(A0, 'frec1')
p.subq(A0, 31, A0, 1)
p.bsr(RA, 'frec')
p.addq(S0, S0, S0)
p.label('frec1')
p.ldq(RA, 0, SP); p.lda(SP, SP, 16)
p.ret(RA)

for i in range(NF - 1, -1, -1):
    kind[i] = rnd.choice(('frame', 'frame', 'frame', 'leaf', 'leaf', 'skip')) if i < NF - 4 else rnd.choice(('leaf', 'skip'))
    gen_fn(i)

p.label('main')
c = Ctx(-1, 40000, False)
p.lda(13, 31, 5)                                           # the whole of it five times, on other data
p.label('again')
block(c, 110)
p.subq(13, 31, 13, 1)
p.bne(13, 'again')
p.lda(6, 31, 0x80); p.sll(6, 31, 6, 16); p.bis(6, S5, 6)
p.stq(S0, 8, 6); p.stq(S1, 16, 6)
p.lda(T3, 31, 1)
p.stq(T3, 0, 6)
p.label('spin'); p.br(31, 'spin')

p.org(TABLE)
for i in range(NF):
    p._emit(lambda pc, i=i: p.labels['f%d' % i] & 0xFFFFFFFF); p.long(0xFFFFFC00)
img = p.assemble()
assert p.labels['main'] < TABLE - 0x4000, hex(p.labels['main'])
open(out, 'wb').write(img)
sys.stderr.write('bp_stress %d: code to %#x, about %d instructions\n' % (seed, p.labels['spin'], c.cost))
