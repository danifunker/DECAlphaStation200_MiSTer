#!/usr/bin/env python3
"""T3 prefetch: loads to R31 / F31 are prefetch hints and never fault (ARM 4.11: LDL/LDQ R31
PREFETCH, LDS F31 PREFETCH_M, LDT F31 PREFETCH_MEN; LDQ_U R31 is UNOP). A PALmode image at PA 0
(icmode=1), pass/fail to TOHOST (PA 0x800000) like T0: 1 = pass, (n << 1) | 1 = step n failed
(+8 = got, +16 = expected).

  1  with no DTB entry at all, `ldl r31`, `ldq r31`, `ldq_u r31`, `lds f31`, `ldt f31` from VA
     0x200000 retire with no DTB_MISS / D_FAULT (the vectors count into $20)
  2  the same with the FPU disabled (ICCSR.FPE = 0): no FEN either
  3  a plain `ldl r1` from the same VA does take DTB_MISS (the test's fault path works)
  4  with a mapped page, `ldl r31` leaves $31 at 0 and `ldq r2` works (a sanity check)

OpenVMS 8.4's first boot died with an ACCVIO in CDSA's initialization: its shareables prefetch
0x200 past an object with `lds $f31,512(a0)`, often into an unmapped page (docs/gaps.md). Built
with tools/alphaasm.py: make -C verilator t3-prefetch
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from alphaasm import Prog

p = Prog()
TOHOST_HI = 0x80

p.org(0); p.br(31, 'init')


def vec(off, code):
    p.org(off); p.lda(0, 31, code); p.br(31, 'fail')


def skip_vec(off, mark):                                  # count the fault in $20, step over the instruction
    p.org(off)
    p.hw_mfpr(22, 0x44)                                   # MM_CSR
    p.hw_mfpr(23, 0x45)                                   # VA (unlocks)
    p.lda(20, 20, mark)
    p.hw_mfpr(24, 0x24); p.lda(24, 24, 4); p.hw_mtpr(24, 0x24)
    p.nop(); p.nop(); p.nop()
    p.hw_rei()


skip_vec(0x01E0, 1)                                       # D_FAULT
vec(0x03E0, 90); vec(0x07E0, 91); vec(0x08E0, 93)
skip_vec(0x09E0, 0x100)                                   # DTB_MISS
vec(0x13E0, 92)
p.org(0x17E0)                                             # FEN: count it, step over
p.lda(20, 20, 0x10000)
p.hw_mfpr(24, 0x24); p.lda(24, 24, 4); p.hw_mtpr(24, 0x24)
p.nop(); p.nop(); p.nop()
p.hw_rei()


def check(n):                                             # $4 got, $3 expected
    p.cmpeq(4, 3, 5); p.lda(0, 31, n); p.beq(5, 'fail')


def prefetches():
    p.ldl(31, 0, 11); p.ldq(31, 8, 11); p.ldq_u(31, 16, 11); p.lds(31, 24, 11); p.ldt(31, 32, 11)


p.org(0x4000); p.label('init')
p.hw_mtpr(31, 0x29)                                       # PS = kernel
p.hw_mtpr(31, 0x26)                                       # ITBZAP
p.hw_mtpr(31, 0x46)                                       # DTBZAP: nothing mapped
p.lda(11, 31, 0x20); p.sll(11, 11, 11, 16)                # $11 = VA 0x200000
p.lda(1, 31, 1); p.sll(1, 1, 1, 42); p.hw_mtpr(1, 0x22)   # ICCSR: FPE (bit 42)

# ---- 1: the five prefetch forms, nothing mapped: no fault
p.bis(31, 31, 20)
prefetches()
p.bis(20, 31, 4); p.bis(31, 31, 3); check(1)

# ---- 2: FPU disabled: still no fault (no FEN)
p.hw_mtpr(31, 0x22)                                       # ICCSR = 0: FPE off
p.bis(31, 31, 20)
prefetches()
p.bis(20, 31, 4); p.bis(31, 31, 3); check(2)
p.lda(1, 31, 1); p.sll(1, 1, 1, 42); p.hw_mtpr(1, 0x22)

# ---- 3: a real load does fault (DTB_MISS)
p.bis(31, 31, 20)
p.ldl(1, 0, 11)
p.bis(20, 31, 4); p.lda(3, 31, 0x100); check(3)

# ---- 4: a mapped page: VA 0x200000 -> PA 0x100000, KRE | KWE; ldl r31 is harmless, ldq r2 works
p.lda(10, 31, 0x10); p.sll(10, 10, 10, 16)                # $10 = PA 0x100000
p.hw_mtpr(31, 0x40)                                       # TB_CTL: GH = 0
p.hw_mtpr(11, 0x20)                                       # TB_TAG
p.sll(10, 10, 2, 19)                                      # PFN << 32
p.lda(3, 31, 0x1100 >> 1); p.sll(3, 3, 3, 1)              # KRE | KWE (PTE[12], PTE[8])
p.bis(2, 3, 2)
p.hw_mtpr(2, 0x42)                                        # DTB_PTE
p.lda(7, 31, 0x1234); p.stq(7, 8, 11)
p.bis(31, 31, 20)
p.ldl(31, 0, 11); p.ldq(2, 8, 11)
p.bis(20, 31, 4); p.bis(31, 31, 3); check(4)
p.bis(2, 31, 4); p.lda(3, 31, 0x1234); check(4)
p.bis(31, 31, 4); p.bis(31, 31, 3); check(4)              # $31 reads 0

p.label('pass')
p.lda(6, 31, TOHOST_HI); p.sll(6, 6, 6, 16)
p.lda(1, 31, 1); p.hw_stq_p(1, 0, 6)
p.label('spin'); p.br(31, 'spin')

p.label('fail')
p.lda(6, 31, TOHOST_HI); p.sll(6, 6, 6, 16)
p.hw_stq_p(4, 8, 6); p.hw_stq_p(3, 16, 6)
p.sll(0, 0, 1, 1); p.bis(1, 1, 1, 1)
p.hw_stq_p(1, 0, 6)
p.label('spin2'); p.br(31, 'spin2')

open(sys.argv[1], 'wb').write(p.assemble())
