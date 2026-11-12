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
  missmix     a call whose frame and table share a D-cache index: D-misses behind stores
  fpmix       four doubles of one line read, added and stored back, and a call (Whetstone's shape)
  divq        libc's __divqu (FreeBSD 5.2.1, the EV4's division millicode: bit by bit top-bit
              searches, then shift and subtract) dividing 3 by 1, 2000 times: XFree86's tga driver
              divides by the bytes per pixel this way in its copy loops
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
p.lda(1, 31, 3); p.sll(1, 1, 1, 41); p.hw_mtpr(1, 0x22)    # ICCSR: FPE (42), MAP (41)
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
elif name == 'missmix':
    # a function whose frame and whose table share a D-cache index (8 KB apart): each call stores
    # into the frame, loads the table (a miss behind the stores) and loads the frame back (a miss)
    kaddr(A1, 0x20); p.lda(A1, A1, 0x2000 - 32)            # the table line: the frame's index
    count(S0, 20000)
    p.label('loop')
    p.bis(S0, 31, A0)
    p.bsr(RA, 'f')
    p.addq(V0, S1, S1)
    p.stq(S1, 0, GP)
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'loop')
    p.br(31, 'pass')
    p.label('f')
    p.lda(SP, SP, -32)
    p.stq(RA, 0, SP); p.stq(S0, 8, SP); p.stq(A0, 16, SP)
    p.ldq(T0, 0, A1)
    p.addq(T0, A0, V0)
    p.stq(V0, 64, GP)
    p.ldq(RA, 0, SP); p.ldq(S0, 8, SP)
    p.lda(SP, SP, 32)
    p.ret()

elif name == 'fpmix':
    # Whetstone's array module: four doubles of one line read, combined and written back, and a
    # call with a frame that saves an FP register
    count(S0, 20000)
    p.label('loop')
    p.ldt(1, 0, GP); p.ldt(2, 8, GP); p.ldt(3, 16, GP); p.ldt(4, 24, GP)
    p.addt(1, 2, 5); p.addt(5, 3, 5); p.addt(5, 4, 5)
    p.stt(5, 0, GP)
    p.addt(5, 2, 6); p.stt(6, 8, GP)
    p.addt(6, 3, 7); p.stt(7, 16, GP)
    p.addt(7, 4, 8); p.stt(8, 24, GP)
    p.lda(A1, GP, 64)
    p.bsr(RA, 'f')
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'loop')
    p.br(31, 'pass')
    p.label('f')
    p.lda(SP, SP, -32)
    p.stq(RA, 0, SP); p.stt(2, 8, SP)
    p.ldt(2, 0, A1)
    p.addt(2, 8, 2)
    p.stt(2, 0, A1)
    p.ldq(RA, 0, SP); p.ldt(2, 8, SP)
    p.lda(SP, SP, 32)
    p.ret()
elif name == 'divq':
    T9, T10, T11, T12 = 23, 24, 25, 27
    count(S0, 2000)
    p.label('loop')
    p.lda(T10, 31, 3); p.lda(T11, 31, 1)
    p.bsr(T9, 'div')
    p.addq(S1, T12, S1)
    p.subq(S0, 31, S0, 1)
    p.bne(S0, 'loop')
    p.br(31, 'pass')
    # __divqu: T12 = T10 / T11 (FreeBSD 5.2.1's libc, objdump of a static binary)
    p.label('div')
    p.lda(SP, SP, -64)
    p.stq(T0, 0, SP); p.stq(T1, 8, SP); p.stq(T2, 16, SP); p.stq(T3, 24, SP)
    p.stq(T10, 40, SP); p.stq(T11, 48, SP)
    p.bis(31, 31, T12)
    p.beq(T11, 'dret')
    p.cmpult(T10, T11, T2)
    p.bne(T2, 'dret')
    p.cmpeq(T10, T11, T2)
    p.cmovne(T2, 31, T12, 1)
    p.cmovne(T2, 31, T10)
    p.bne(T2, 'dret')
    p.lda(T3, 31, 1); p.bis(31, 31, T1); p.sll(T3, 31, T0, 63)
    p.label('bloop')
    p.and_(T11, T0, T2)
    p.bne(T2, 'abits')
    p.addq(T1, 31, T1, 1)
    p.srl(T0, 31, T0, 1)
    p.cmplt(T1, 31, T2, 63)
    p.bne(T2, 'bloop')
    p.label('abits')
    p.beq(T1, 'dodiv')
    p.lda(T3, 31, 1); p.sll(T3, 31, T0, 63)
    p.label('aloop')
    p.and_(T10, T0, T2)
    p.bne(T2, 'dodiv')
    p.subq(T1, 31, T1, 1)
    p.srl(T0, 31, T0, 1)
    p.bne(T1, 'aloop')
    p.label('dodiv')
    p.sll(T11, T1, T11)
    p.lda(T3, 31, 1); p.sll(T3, T1, T0)
    p.label('dloop')
    p.cmpult(T10, T11, T2)
    p.bis(T12, T0, T3)
    p.cmoveq(T2, T3, T12)
    p.subq(T10, T11, T3)
    p.cmoveq(T2, T3, T10)
    p.srl(T0, 31, T0, 1)
    p.srl(T11, 31, T11, 1)
    p.beq(T10, 'dret')
    p.bne(T0, 'dloop')
    p.label('dret')
    p.ldq(T0, 0, SP); p.ldq(T1, 8, SP); p.ldq(T2, 16, SP); p.ldq(T3, 24, SP)
    p.ldq(T10, 40, SP); p.ldq(T11, 48, SP)
    p.lda(SP, SP, 64)
    p.ret(T9)
else:
    sys.exit('unknown benchmark ' + name)

p.label('pass')
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16); p.bis(6, S5, 6)
p.lda(1, 31, 1); p.stq(1, 0, 6)
p.label('spin'); p.br(31, 'spin')

open(out, 'wb').write(p.assemble())
