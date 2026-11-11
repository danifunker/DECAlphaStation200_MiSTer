#!/usr/bin/env python3
"""Microbenchmarks for the pipelined core's cycle breakdown (make -C verilator perf): small loops
in the shape of compiled code, each isolating one cost. A PALmode image at PA 0 (icmode=1) that
turns the KSEG superpage and the D-cache on and leaves PALmode like rt/t0_pal.h, then runs the
body at KSEG + 0x6000 and stores 1 to TOHOST (PA 0x800000). Built with tools/alphaasm.py.

  perf_bench.py NAME OUT.bin

  calls       a non-leaf function (3 saves, a leaf call, 3 restores, ret) called 20000 times
  memcpy_in   2 KB copied quadword by quadword 200 times: source and target stay in the D-cache
  memcpy_out  256 KB copied once: every source line misses, every store goes to memory
  branchy     LFSR-driven conditional branches, no memory access
  loaduse     a 64-node linked list walked 2000 times (load -> address of the next load)
  stackmix    globals read, changed and written back, compares and branches, a small call:
              roughly the instruction mix of Dhrystone's main loop
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from alphaasm import Prog

name, out = sys.argv[1], sys.argv[2]
p = Prog()
V0, T0, T1, T2, T3, T4, S0, S1, S5, A0, A1, A2, RA, GP, SP = 0, 1, 2, 3, 4, 5, 9, 10, 14, 16, 17, 18, 26, 29, 30

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


def kaddr(r, hi):                                          # r = KSEG + (hi << 16)
    p.lda(r, 31, hi); p.sll(r, r, r, 16); p.bis(r, S5, r)


def count(r, n):                                           # r = n (up to 2^31)
    p.ldah(r, 31, (n + 0x8000) >> 16); p.lda(r, r, ((n & 0xFFFF) ^ 0x8000) - 0x8000)


p.org(0x6000)
kaddr(SP, 0x10)
kaddr(GP, 0x20)

if name == 'calls':
    count(S0, 20000)
    p.label('loop')
    p.bis(S0, 31, A0)
    p.bsr(RA, 'f')
    p.addq(V0, S1, S1)
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'loop')
    p.br(31, 'pass')
    p.label('f')
    p.lda(SP, SP, -32)
    p.stq(RA, 0, SP); p.stq(S0, 8, SP); p.stq(S1, 16, SP)
    p.bis(A0, 31, S0)
    p.addq(A0, 31, A0, 3)
    p.bsr(RA, 'g')
    p.addq(V0, S0, V0)
    p.ldq(RA, 0, SP); p.ldq(S0, 8, SP); p.ldq(S1, 16, SP)
    p.lda(SP, SP, 32)
    p.ret()
    p.label('g')
    p.sll(A0, 31, T0, 2)
    p.xor(T0, A0, V0)
    p.ret()

elif name in ('memcpy_in', 'memcpy_out'):
    reps, quads = (200, 256) if name == 'memcpy_in' else (1, 32768)
    count(S0, reps)
    p.label('rep')
    kaddr(A1, 0x20)                                        # source
    kaddr(A0, 0x40); p.lda(A0, A0, 0x1000)                 # target: other D-cache lines than the source
    count(A2, quads)
    p.label('loop')
    p.ldq(T0, 0, A1)
    p.lda(A1, A1, 8)
    p.stq(T0, 0, A0)
    p.lda(A0, A0, 8)
    p.subq(A2, 31, A2, 1)
    p.bne(A2, 'loop')
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'rep')

elif name == 'branchy':
    count(S0, 100000)
    p.lda(T0, 31, 0x2A5B)
    p.label('loop')
    p.srl(T0, 31, T1, 1)                                   # a 16-bit LFSR
    p.and_(T0, 31, T2, 1)
    p.beq(T2, 'noxor')
    p.lda(T3, 31, -0x4C00)                                 # 0xB400
    p.zapnot(T3, 31, T3, 3)
    p.xor(T1, T3, T1)
    p.label('noxor')
    p.bis(T1, 31, T0)
    p.and_(T0, 31, T2, 4)
    p.bne(T2, 'odd')
    p.addq(S1, 31, S1, 1)
    p.br(31, 'join')
    p.label('odd')
    p.subq(S1, 31, S1, 2)
    p.label('join')
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'loop')

elif name == 'loaduse':
    # build the list: node i at GP + 32 i, next in +0, a value in +8
    p.bis(GP, 31, T0); p.lda(T1, 31, 63)
    p.label('mk')
    p.lda(T2, T0, 32)
    p.stq(T2, 0, T0); p.stq(T1, 8, T0)
    p.bis(T2, 31, T0)
    p.subq(T1, 31, T1, 1)
    p.bne(T1, 'mk')
    p.stq(31, 0, T0); p.stq(31, 8, T0)
    count(S0, 2000)
    p.label('rep')
    p.bis(GP, 31, T0)
    p.label('loop')
    p.ldq(T1, 8, T0)
    p.ldq(T0, 0, T0)
    p.addq(S1, T1, S1)
    p.bne(T0, 'loop')
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'rep')

elif name == 'stackmix':
    count(S0, 20000)
    p.label('loop')
    p.ldq(T0, 0, GP)
    p.addq(T0, 31, T0, 1)
    p.stq(T0, 0, GP)
    p.ldl(T1, 8, GP)
    p.addl(T1, T0, T1)
    p.stl(T1, 8, GP)
    p.and_(T0, 31, T2, 3)
    p.beq(T2, 'skip')
    p.ldq(T3, 16, GP)
    p.xor(T3, T1, T3)
    p.stq(T3, 16, GP)
    p.label('skip')
    p.bis(T0, 31, A0)
    p.lda(A1, GP, 64)
    p.bsr(RA, 'f')
    p.cmpult(V0, T0, T4)
    p.bne(T4, 'less')
    p.stq(V0, 24, GP)
    p.label('less')
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'loop')
    p.br(31, 'pass')
    p.label('f')
    p.lda(SP, SP, -16)
    p.stq(RA, 0, SP); p.stq(S0, 8, SP)
    p.ldq(T2, 0, A1)
    p.addq(T2, A0, S0)
    p.stq(S0, 0, A1)
    p.stl(A0, 8, A1)
    p.bis(S0, 31, V0)
    p.ldq(RA, 0, SP); p.ldq(S0, 8, SP)
    p.lda(SP, SP, 16)
    p.ret()
else:
    sys.exit('unknown benchmark ' + name)

p.label('pass')
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16); p.bis(6, S5, 6)
p.lda(1, 31, 1); p.stq(1, 0, 6)
p.label('spin'); p.br(31, 'spin')

open(out, 'wb').write(p.assemble())
