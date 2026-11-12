#!/usr/bin/env python3
"""FP pipeline stress for the pipelined core (make -C verilator fpstress): a straight line of
pseudo-random ADDT / SUBT / MULT / DIVT on twelve registers, dependent and independent, mixed
with STT / LDT over a 64 KB region (D-fills and write-buffer waits hold M2 while results come
back from the unit), integer loads of the stored bit patterns, CPYS, CMPTLT and FBxx on FP
values. FP operations flow through the unit several at a time (ev4_core, "FP arithmetic in
flight"), so the order and the forwarding of their results is what this checks; the bench's
random interrupts (IRQRATE) kill operations in flight and they run again. This script keeps its
own copy of the registers and the memory (Python floats are IEEE doubles, round to nearest; the
values are kept normal and nonzero, so nothing traps and nothing is inexact in a way that
matters): the image carries the sum the integer loads must give and the sum of the final
register bit patterns, and stores 1 to TOHOST (PA 0x800000) when both match, else 2 (loads),
3 (registers), 77 (an ARITH trap) or 78 (another PAL entry).

  fp_stress.py SEED OUT.bin
"""
import sys, os, random, struct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from alphaasm import Prog

seed, out = int(sys.argv[1]), sys.argv[2]
rnd = random.Random(seed)
p = Prog()
T0, T1, T3, T4, S0, S1, S5, A0 = 1, 2, 4, 5, 9, 10, 14, 16
M = (1 << 64) - 1
SIZE = 0x10000
NREG = 12                                                  # F1..F12; F13 takes compare results
CONST = 0x20000                                            # the constants, then the two sums


def bits(x): return struct.unpack('<Q', struct.pack('<d', x))[0]
def flt(b): return struct.unpack('<d', struct.pack('<Q', b))[0]


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
p.lda(1, 31, 3); p.sll(1, 1, 1, 41); p.hw_mtpr(1, 0x22)    # ICCSR: FPE, MAP
p.hw_mtpr(31, 0x29)                                        # PS: kernel
p.lda(1, 31, 0x200); p.hw_mtpr(1, 0x30)                    # HIER: irq_h[0]
p.lda(S5, 31, -1); p.sll(S5, S5, S5, 42)                   # KSEG base
p.lda(2, 31, 0x6000); p.bis(2, S5, 2)
p.hw_mtpr(2, 0x24)                                         # EXC_ADDR
p.nop(); p.nop(); p.nop()
p.hw_rei()

consts = [rnd.choice((-1, 1)) * rnd.uniform(0.5, 2.0) * 10.0 ** rnd.randrange(-3, 4) for _ in range(64)]
reg = [0.0] * (NREG + 1)
mem = bytearray(SIZE)
written = []
recent_l = [0]
recent_r = [1, 2]
lsum = 0

p.org(0x6000)
p.lda(A0, 31, 0x40); p.sll(A0, A0, A0, 16); p.bis(A0, S5, A0)  # the region: PA 0x400000
p.lda(A0, A0, 0x4000); p.lda(A0, A0, 0x4000)               # A0 = its middle
p.lda(T4, 31, CONST >> 16); p.sll(T4, T4, T4, 16); p.bis(T4, S5, T4)


def reload(r):
    k = rnd.randrange(len(consts))
    p.ldt(r, 8 * k, T4); reg[r] = consts[k]


def ok(x): return x == x and 1e-150 < abs(x) < 1e150


def src():
    return rnd.choice(recent_r) if rnd.random() < 0.6 else rnd.randrange(1, NREG + 1)


def wrote(r):
    global recent_r
    recent_r = (recent_r + [r])[-3:]


def addr():
    global recent_l
    if rnd.random() < 0.6:
        line = rnd.choice(recent_l)
    else:
        line = rnd.randrange(SIZE // 32)
        recent_l = (recent_l + [line])[-5:]
    return line * 32 + rnd.randrange(4) * 8


for r in range(1, NREG + 1): reload(r)
skip = 0
for n in range(3500):
    r = rnd.random()
    if r < 0.55:
        a, b, c = src(), src(), rnd.randrange(1, NREG + 1)
        k = rnd.choice((0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 3))
        x = (reg[a] + reg[b], reg[a] - reg[b], reg[a] * reg[b], reg[a] / reg[b])[k]
        if not ok(x):
            reload(c)
        else:
            p.fop(0x16, 0x0A0 + k, a, b, c); reg[c] = x
        wrote(c)
    elif r < 0.70:
        a, f = addr(), src()
        p.stt(f, a - 0x8000, A0); mem[a:a + 8] = struct.pack('<d', reg[f])
        if a not in written: written.append(a)
    elif r < 0.82:
        c = rnd.randrange(1, NREG + 1)
        if written:
            a = rnd.choice(written[-12:]) if rnd.random() < 0.7 else rnd.choice(written)
            p.ldt(c, a - 0x8000, A0); reg[c] = struct.unpack('<d', mem[a:a + 8])[0]
        else:
            reload(c)
        wrote(c)
    elif r < 0.87 and written:
        a = rnd.choice(written)
        p.ldq(T0, a - 0x8000, A0); p.addq(S1, T0, S1)
        lsum = (lsum + int.from_bytes(mem[a:a + 8], 'little')) & M
    elif r < 0.91:
        a, b, c = src(), src(), rnd.randrange(1, NREG + 1)
        p.cpys(a, b, c)
        reg[c] = flt((bits(reg[a]) & (1 << 63)) | (bits(reg[b]) & ~(1 << 63) & M))
        wrote(c)
    elif r < 0.97:
        # a branch on an FP value (never zero) or on a compare's result; the instruction a taken
        # branch skips would spoil a register
        a, b, v = src(), src(), rnd.randrange(1, NREG + 1)
        if rnd.random() < 0.5:
            p.fop(0x16, 0x0A6, a, b, 13)                   # CMPTLT
            t = reg[a] < reg[b]
            taken = rnd.random() < 0.5
            (p.fbne if t == taken else p.fbeq)(13, 'k%d' % skip)
        else:
            taken = rnd.random() < 0.5
            (p.fbne if taken else p.fbeq)(a, 'k%d' % skip)
        if taken:
            p.fop(0x16, 0x0A2, v, v, v)                    # skipped
        else:
            x = reg[v] * reg[v]
            if ok(x): p.fop(0x16, 0x0A2, v, v, v); reg[v] = x
            else: p.nop()
        p.label('k%d' % skip); skip += 1
    else:
        for k in range(rnd.randrange(6)): p.nop()

# the loads' sum
p.ldq(T0, 8 * len(consts), T4)
p.cmpeq(T0, S1, T0)
p.lda(T3, 31, 2)
p.beq(T0, 'done')
# the registers' bit patterns
for r in range(1, NREG + 1):
    p.stt(r, 8 * r - 0x8000, A0)
    p.ldq(T0, 8 * r - 0x8000, A0)
    p.addq(S0, T0, S0)
p.ldq(T0, 8 * len(consts) + 8, T4)
p.cmpeq(T0, S0, T0)
p.lda(T3, 31, 3)
p.beq(T0, 'done')
p.lda(T3, 31, 1)
p.label('done')
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16); p.bis(6, S5, 6)
p.stq(T3, 0, 6)
p.label('spin'); p.br(31, 'spin')

fsum = sum(bits(reg[r]) for r in range(1, NREG + 1)) & M
p.org(CONST)
p.quad(*[bits(x) for x in consts]); p.quad(lsum); p.quad(fsum)
open(out, 'wb').write(p.assemble())
