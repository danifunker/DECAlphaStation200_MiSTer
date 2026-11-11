#!/usr/bin/env python3
"""Write-buffer stress for the pipelined core (make -C verilator wbstress): a straight line of
pseudo-random STQ / STL into a 64 KB region (eight times the D-cache, so lines leave the cache
and come back from memory through D-fills), mixed with loads of what was stored. The stores
favour a few recent lines, so they join write-buffer entries, hit entries that are on the bus
and fill the buffer. This script keeps its own copy of the memory: the image carries the sum
the loads must give and the sum of the whole region read back at the end, and stores 1 to
TOHOST (PA 0x800000) when both match, else 2 (loads) or 3 (the final read). Same frame as
perf_bench.py.

  wb_stress.py SEED OUT.bin
"""
import sys, os, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from alphaasm import Prog

seed, out = int(sys.argv[1]), sys.argv[2]
rnd = random.Random(seed)
p = Prog()
T0, T1, T2, T3, T4, S0, S1, S5, A0 = 1, 2, 3, 4, 5, 9, 10, 14, 16
M = (1 << 64) - 1
SIZE = 0x10000

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
p.lda(1, 31, 1); p.sll(1, 1, 1, 41); p.hw_mtpr(1, 0x22)    # ICCSR: MAP
p.hw_mtpr(31, 0x29)                                        # PS: kernel
p.lda(S5, 31, -1); p.sll(S5, S5, S5, 42)                   # KSEG base
p.lda(2, 31, 0x6000); p.bis(2, S5, 2)
p.hw_mtpr(2, 0x24)                                         # EXC_ADDR
p.nop(); p.nop(); p.nop()
p.hw_rei()

mem = bytearray(SIZE)
val, lsum = 0x123456789, 0
recent = [0]

p.org(0x6000)
p.lda(A0, 31, 0x40); p.sll(A0, A0, A0, 16); p.bis(A0, S5, A0)  # the region: PA 0x400000
p.lda(A0, A0, 0x4000); p.lda(A0, A0, 0x4000)               # A0 = its middle
p.lda(T1, 31, 0x4567); p.sll(T1, T1, T1, 20); p.lda(T1, T1, 0x6789)
val = (0x4567 << 20) + 0x6789
for n in range(3500):
    r = rnd.random()
    if r < 0.6:
        line = rnd.choice(recent)
    else:
        line = rnd.randrange(SIZE // 32)
        recent = (recent + [line])[-5:]
    a = line * 32 + rnd.randrange(8) * 4
    if rnd.random() < 0.25:                                # a load of what memory holds now
        a &= ~7
        p.ldq(T0, a - 0x8000, A0)
        p.addq(S1, T0, S1)
        lsum = (lsum + int.from_bytes(mem[a:a + 8], 'little')) & M
        continue
    imm = rnd.randrange(-0x8000, 0x8000)
    p.sll(T1, 31, T2, 3); p.srl(T1, 31, T3, 7); p.xor(T2, T3, T1); p.lda(T1, T1, imm)
    val = ((((val << 3) & M) ^ (val >> 7)) + imm) & M
    if rnd.random() < 0.5:
        a &= ~7
        p.stq(T1, a - 0x8000, A0); mem[a:a + 8] = val.to_bytes(8, 'little')
    else:
        p.stl(T1, a - 0x8000, A0); mem[a:a + 4] = (val & 0xFFFFFFFF).to_bytes(4, 'little')
    if rnd.random() < 0.05:                                # let the buffer drain now and then
        for k in range(rnd.randrange(40)): p.nop()

# the loads' sum
p.lda(T4, 31, 2); p.sll(T4, T4, T4, 16); p.bis(T4, S5, T4)
p.ldq(T0, 0, T4)
p.cmpeq(T0, S1, T0)
p.lda(T3, 31, 2)
p.beq(T0, 'done')
# the whole region, read back
p.lda(T2, 31, SIZE // 8 // 2); p.addq(T2, T2, T2)
p.lda(A0, A0, -0x8000)
p.label('rd')
p.ldq(T0, 0, A0)
p.lda(A0, A0, 8)
p.addq(S0, T0, S0)
p.subq(T2, 31, T2, 1)
p.bne(T2, 'rd')
p.ldq(T0, 8, T4)
p.cmpeq(T0, S0, T0)
p.lda(T3, 31, 3)
p.beq(T0, 'done')
p.lda(T3, 31, 1)
p.label('done')
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16); p.bis(6, S5, 6)
p.stq(T3, 0, 6)
p.label('spin'); p.br(31, 'spin')

fsum = sum(int.from_bytes(mem[i:i + 8], 'little') for i in range(0, SIZE, 8)) & M
p.org(0x20000); p.quad(lsum); p.quad(fsum)
open(out, 'wb').write(p.assemble())
