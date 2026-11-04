#!/usr/bin/env python3
"""T3: FP loads feeding FP compares (the NT 4.0 + IE 4.01 STOP 0x3B hunt, 2026-11-04): a native
loop does `lds` then `cmptlt/su` on 16.0f in several shapes (back to back, with gaps, right after
a store to the same longword, after an `sts` of the value, after a legitimately trapping compare
on a NaN that an NT-style ARITH handler completes), and fails on any arithmetic trap it did not
expect or any wrong compare result. Built with tools/alphaasm.py (no binutils needed):
    python3 tests/cpu/t3_fpld.py OUT.bin
Run it on the pipelined core with the bench's stress knobs:
    IRQRATE=150 IRQSEED=3 MEMDELAY=20 FASTLINE=1 verilator/obj_pipe/Vev4_core OUT.bin --max 30000000
TOHOST (PA 0x800000) gets 1 for pass, else the failing step: 77 an unexpected ARITH, 78 a
PAL entry that should not happen, 1x a wrong compare result in shape x (see below).
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tools'))
from alphaasm import Prog

p = Prog()
KSEG_HI = -1 << 42                    # 0xFFFFFC0000000000
BUF = 0x100000                        # the floats
TOHOST = 0x800000
IRQACK_HI = 0x70                      # PA 0x700000: the bench drops irq_h[0]
N = 2000

p.org(0); p.br(31, 'init')
# ---- PAL entries
def vec(off, code):
    p.org(off); p.lda(0, 31, code); p.br(31, 'fail')
vec(0x0020, 78)                                           # MCHK
p.org(0x0060); p.br(31, 'arith')                          # ARITH: the handler below (as NT's PALcode does it)
p.org(0x00E0)                                             # INTERRUPT: the bench's irq_h[0], transparent
p.hw_mtpr(1, 0x80)
p.lda(1, 31, IRQACK_HI); p.sll(1, 1, 1, 16)
p.hw_stq_p(31, 0, 1)
p.hw_mfpr(1, 0x80)
p.hw_rei()
vec(0x01E0, 78); vec(0x03E0, 78); vec(0x07E0, 78); vec(0x08E0, 78); vec(0x09E0, 78)
vec(0x11E0, 78); vec(0x13E0, 78); vec(0x17E0, 78)

# ---- the ARITH handler (PALmode, above the vectors)
p.org(0x3000); p.label('arith')
p.hw_mfpr(22, 0x2a)                                       # EXC_SUM (the MSK bit F31)
p.hw_mtpr(31, 0x2a)                                       # clear the summary
for _ in range(31): p.hw_mfpr(23, 0x2a)                   # MSK F30..F0
p.hw_mfpr(24, 0x24)                                       # EXC_ADDR: (A | 2) - 2, bic 2 -> the next PC
p.subq(24, 24, 24, 2)
p.opr(0x11, 0x08, 24, 24, 24, 2)                          # bic $24,2,$24
p.hw_mtpr(24, 0x24)
p.beq(9, 'arith_bad')                                     # $9 = 0: no trap was expected
p.addq(20, 20, 20, 1)                                     # count the expected ones
p.nop(); p.nop(); p.nop()
p.hw_rei()
p.label('arith_bad'); p.lda(0, 31, 77); p.br(31, 'fail')

# ---- init (PALmode)
p.org(0x4000); p.label('init')
p.lda(1, 31, 0x420); p.hw_mtpr(1, 0x4e)                   # ABOX_CTL: DC_ENA, SPE_2
p.lda(1, 31, 3); p.sll(1, 1, 1, 41); p.hw_mtpr(1, 0x22)   # ICCSR: FPE (42), MAP (41)
p.hw_mtpr(31, 0x29)                                       # PS: kernel
p.lda(1, 31, 0x200); p.hw_mtpr(1, 0x30)                   # HIER: irq_h[0]
p.lda(3, 31, -1); p.sll(3, 3, 3, 42)                      # $3 = KSEG base
p.lda(10, 31, 0x10); p.sll(10, 10, 10, 16); p.bis(10, 3, 10)    # $10 = KSEG | BUF
p.lda(6, 31, 0x80); p.sll(6, 6, 6, 16); p.bis(6, 3, 6)          # $6 = KSEG | TOHOST
p.lda(2, 31, 'body'); p.bis(2, 3, 2)                      # native entry (bit 0 clear)
p.hw_mtpr(2, 0x24)
p.nop(); p.nop(); p.nop()
p.hw_rei()

# ---- native body
p.align(8)
p.label('body')
p.ldah(12, 31, 0x4180)                                    # $12 = 0x41800000 = 16.0f
p.stl(12, 0, 10); p.stl(12, 4, 10); p.stl(12, 12, 10); p.stl(12, 16, 10)
p.ldah(13, 31, 0x7fc0); p.stl(13, 8, 10)                  # a quiet NaN at 8: a compare on it traps (/SU)
p.lda(11, 31, N)
p.bis(31, 31, 9)                                          # $9 = 0: no trap expected
p.bis(31, 31, 20)
p.label('loop')
# A: back to back
p.lds(0, 0, 10); p.cmptlt(0, 31, 1); p.trapb(); p.fbne(1, 'f10')
# B: a store to the same longword right before the load (the store -> load merge)
p.stl(12, 4, 10); p.lds(0, 4, 10); p.cmptlt(0, 31, 1); p.trapb(); p.fbne(1, 'f11')
# C: a gap of one, D: of two
p.lds(0, 0, 10); p.nop(); p.cmptlt(0, 31, 1); p.trapb(); p.fbne(1, 'f12')
p.lds(0, 0, 10); p.nop(); p.nop(); p.cmptlt(0, 31, 1); p.trapb(); p.fbne(1, 'f13')
# E: a legitimate trap first (the NaN), completed by the handler, then the clean pair
p.lda(9, 31, 1)
p.lds(2, 8, 10); p.cmptlt(2, 31, 3); p.trapb()
p.bis(31, 31, 9)
p.lds(0, 0, 10); p.cmptlt(0, 31, 1); p.trapb(); p.fbne(1, 'f14')
# F: sts of the value, then the load of it
p.sts(0, 12, 10); p.lds(4, 12, 10); p.cmptlt(4, 31, 5); p.trapb(); p.fbne(5, 'f15')
# G: equality must hold (2.0 -> nonzero)
p.cmpteq(0, 0, 6); p.trapb(); p.fbeq(6, 'f16')
# H: a quadword-crossing pair: the other longword of the quadword stored just before
p.stl(12, 16, 10); p.lds(7, 16, 10); p.cmptlt(7, 31, 8); p.trapb(); p.fbne(8, 'f17')
p.subq(11, 11, 11, 1); p.bne(11, 'loop')
# the expected traps: one per iteration
p.lda(4, 31, N); p.cmpeq(20, 4, 5); p.beq(5, 'f18')
p.label('pass'); p.lda(5, 31, 1); p.stq(5, 0, 6); p.mb()
p.label('hang'); p.br(31, 'hang')
for i in range(10, 19):
    p.label('f%d' % i); p.lda(0, 31, i); p.br(31, 'fail')
p.label('fail'); p.lda(1, 31, 0x80); p.sll(1, 1, 1, 16); p.lda(3, 31, -1); p.sll(3, 3, 3, 42); p.bis(1, 3, 1)
p.stq(0, 0, 1); p.mb()
p.label('hang2'); p.br(31, 'hang2')

out = sys.argv[1] if len(sys.argv) > 1 else 'build/pal/t3_fpld.bin'
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
open(out, 'wb').write(p.assemble())
print('wrote', out, len(p.assemble()), 'bytes; body at %x' % p.labels['body'])
