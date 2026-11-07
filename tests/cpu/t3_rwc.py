#!/usr/bin/env python3
"""T3 rwc: HW_LD with RWC (ir[13], "read with write check": the PAL's PROBEW) on the DTB's
protection. A PALmode image at PA 0 (icmode=1), pass/fail to TOHOST (PA 0x800000) like T0:
1 = pass, (n << 1) | 1 = step n failed (+8 = got, +16 = expected).

  1  a DTB entry VA 0x200000 -> PA 0x100000 with KRE | KWE | URE: a plain HW_LD with
     ALT_MODE = user reads it (no fault)
  2  the same load with RWC takes D_FAULT (0x1E0) with MM_CSR.ACV (user has no write)
  3  with ALT_MODE = kernel the RWC load passes (KWE)
  4  a mapping with UWE and FOW: the RWC load takes D_FAULT with MM_CSR.FOW, a plain
     ALT load does not

OpenVMS 7.3's installer died with an ACCVIO because PROBEW (a HW_LD/RWC in user mode)
said a supervisor-stack page was user-writable (docs/gaps.md). Built with tools/alphaasm.py
(no binutils needed): make -C verilator t3-rwc
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from alphaasm import Prog

p = Prog()
TOHOST_HI = 0x80

p.org(0); p.br(31, 'init')


def vec(off, code):
    p.org(off); p.lda(0, 31, code); p.br(31, 'fail')


p.org(0x01E0)                                             # D_FAULT: note it, step over the load
p.hw_mfpr(22, 0x44)                                       # MM_CSR
p.hw_mfpr(23, 0x45)                                       # VA (unlocks)
p.lda(20, 31, 2)
p.br(31, 'skip')
vec(0x03E0, 90); vec(0x07E0, 91); vec(0x08E0, 93)
p.org(0x09E0); p.lda(0, 31, 94); p.br(31, 'fail')         # DTB_MISS: unexpected
vec(0x13E0, 92)
p.label('skip')
p.hw_mfpr(24, 0x24); p.lda(24, 24, 4); p.hw_mtpr(24, 0x24)
p.nop(); p.nop(); p.nop()
p.hw_rei()


def hw_ldq(ra, d, rb, flags):                             # HW_LD quadword: flags = ALT 0x4000, RWC 0x2000
    p.word((0x1B << 26) | (ra << 21) | (rb << 16) | 0x1000 | flags | (d & 0xFFF))


def check(n):                                             # $4 got, $3 expected
    p.cmpeq(4, 3, 5); p.lda(0, 31, n); p.beq(5, 'fail')


def map_page(prot):                                       # VA 0x200000 -> PA 0x100000, GH 0, prot = PTE[15:8]
    p.hw_mtpr(31, 0x46)                                   # DTBZAP
    p.hw_mtpr(31, 0x40)                                   # TB_CTL: GH = 0
    p.hw_mtpr(11, 0x20)                                   # TB_TAG
    p.sll(10, 10, 2, 19)                                  # PFN << 32 = PA << 19
    p.lda(3, 31, prot >> 1); p.sll(3, 3, 3, 1)             # (0x9904 would sign-extend in one lda)
    p.bis(2, 3, 2)
    p.hw_mtpr(2, 0x42)                                    # DTB_PTE


p.org(0x4000); p.label('init')
p.hw_mtpr(31, 0x29)                                       # PS = kernel
p.hw_mtpr(31, 0x26)                                       # ITBZAP
p.lda(10, 31, 0x10); p.sll(10, 10, 10, 16)                # $10 = PA 0x100000
p.lda(11, 31, 0x20); p.sll(11, 11, 11, 16)                # $11 = VA 0x200000
p.lda(1, 31, 0x18); p.hw_mtpr(1, 0x4F)                    # ALT_MODE = user

# ---- 1: KRE | KWE | URE: a user ALT read passes
map_page(0x1900)
p.bis(31, 31, 20)
hw_ldq(7, 8, 11, 0x4000)
p.bis(20, 31, 4); p.bis(31, 31, 3); check(1)

# ---- 2: the RWC load faults with ACV
hw_ldq(7, 8, 11, 0x6000)
p.bis(20, 31, 4); p.lda(3, 31, 2); check(2)
p.and_(22, 22, 4, 2); p.lda(3, 31, 2); check(2)           # MM_CSR.ACV

# ---- 3: kernel ALT mode: KWE lets the RWC load through
p.hw_mtpr(31, 0x4F)                                       # ALT_MODE = kernel
p.bis(31, 31, 20)
hw_ldq(7, 8, 11, 0x6000)
p.bis(20, 31, 4); p.bis(31, 31, 3); check(3)

# ---- 4: UWE | URE | KWE | KRE with FOW (PTE[2]): the RWC load takes FOW, a plain load does not
p.lda(1, 31, 0x18); p.hw_mtpr(1, 0x4F)                    # ALT_MODE = user
map_page(0x9904)
p.bis(31, 31, 20)
hw_ldq(7, 8, 11, 0x4000)
p.bis(20, 31, 4); p.bis(31, 31, 3); check(4)
hw_ldq(7, 8, 11, 0x6000)
p.bis(20, 31, 4); p.lda(3, 31, 2); check(4)
p.and_(22, 22, 4, 8); p.lda(3, 31, 8); check(4)           # MM_CSR.FOW

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
