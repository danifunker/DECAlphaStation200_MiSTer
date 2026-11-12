#!/usr/bin/env python3
"""A tiny Alpha assembler in plain Python for the bench images (no binutils needed): the
instructions the T3 tests use. Programs are Python lists built with the helpers below; labels
and `.org` are resolved in two passes.

    from alphaasm import *
    p = Prog()
    p.org(0); p.br(31, 'init')
    p.org(0x60); p.lda(0, 31, 77); p.br(31, 'fail')
    p.label('init'); ...
    open('x.bin', 'wb').write(p.assemble())

Registers are numbers (0-31); FP registers in FP instructions likewise. Branch targets and
`lda`'s displacement take a label name or a number.
"""
import struct

R = {'v0': 0, 't0': 1, 't1': 2, 't2': 3, 't3': 4, 't4': 5, 't5': 6, 't6': 7, 't7': 8, 's0': 9, 's1': 10, 's2': 11,
     's3': 12, 's4': 13, 's5': 14, 'fp': 15, 'a0': 16, 'a1': 17, 'a2': 18, 'a3': 19, 'a4': 20, 'a5': 21, 't8': 22,
     't9': 23, 't10': 24, 't11': 25, 'ra': 26, 't12': 27, 'at': 28, 'gp': 29, 'sp': 30, 'zero': 31}


class Prog:
    def __init__(self):
        self.items = []          # (kind, ...) : ('org', addr) | ('label', name) | ('insn', fn) | ('data', bytes)
        self.labels = {}

    # ------------------------------------------------------------ layout
    def org(self, a): self.items.append(('org', a))
    def label(self, n): self.items.append(('label', n))
    def quad(self, *vals):
        for v in vals: self.items.append(('data', struct.pack('<Q', v & 0xFFFFFFFFFFFFFFFF)))
    def long(self, *vals):
        for v in vals: self.items.append(('data', struct.pack('<I', v & 0xFFFFFFFF)))
    def align(self, n):
        self.items.append(('align', n))

    def _emit(self, fn): self.items.append(('insn', fn))

    def _res(self, x, pc=None):
        if isinstance(x, str):
            return self.labels[x]
        return x

    # ------------------------------------------------------------ formats
    def mem(self, op, ra, disp, rb):
        self._emit(lambda pc: (op << 26) | (ra << 21) | (rb << 16) | (self._res(disp) & 0xFFFF))
    def opr(self, op, fn, ra, rb, rc, lit=None):
        if lit is None:
            self._emit(lambda pc: (op << 26) | (ra << 21) | (rb << 16) | (fn << 5) | rc)
        else:
            self._emit(lambda pc: (op << 26) | (ra << 21) | ((lit & 0xFF) << 13) | (1 << 12) | (fn << 5) | rc)
    def bra(self, op, ra, target):
        def f(pc):
            d = (self._res(target) - (pc + 4)) >> 2
            return (op << 26) | (ra << 21) | (d & 0x1FFFFF)
        self._emit(f)
    def fop(self, op, fn, fa, fb, fc):
        self._emit(lambda pc: (op << 26) | (fa << 21) | (fb << 16) | (fn << 5) | fc)
    def word(self, w): self._emit(lambda pc: w)

    # ------------------------------------------------------------ mnemonics
    def lda(self, ra, rb, d): self.mem(0x08, ra, d, rb)
    def ldah(self, ra, rb, d): self.mem(0x09, ra, d, rb)
    def ldq(self, ra, d, rb): self.mem(0x29, ra, d, rb)
    def ldl(self, ra, d, rb): self.mem(0x28, ra, d, rb)
    def stq(self, ra, d, rb): self.mem(0x2D, ra, d, rb)
    def stl(self, ra, d, rb): self.mem(0x2C, ra, d, rb)
    def ldq_u(self, ra, d, rb): self.mem(0x0B, ra, d, rb)
    def stq_u(self, ra, d, rb): self.mem(0x0F, ra, d, rb)
    def lds(self, fa, d, rb): self.mem(0x22, fa, d, rb)
    def ldt(self, fa, d, rb): self.mem(0x23, fa, d, rb)
    def sts(self, fa, d, rb): self.mem(0x26, fa, d, rb)
    def stt(self, fa, d, rb): self.mem(0x27, fa, d, rb)
    def addq(self, ra, rb, rc, lit=None): self.opr(0x10, 0x20, ra, rb, rc, lit)
    def subq(self, ra, rb, rc, lit=None): self.opr(0x10, 0x29, ra, rb, rc, lit)
    def addl(self, ra, rb, rc, lit=None): self.opr(0x10, 0x00, ra, rb, rc, lit)
    def cmpeq(self, ra, rb, rc, lit=None): self.opr(0x10, 0x2D, ra, rb, rc, lit)
    def cmpult(self, ra, rb, rc, lit=None): self.opr(0x10, 0x1D, ra, rb, rc, lit)
    def cmplt(self, ra, rb, rc, lit=None): self.opr(0x10, 0x4D, ra, rb, rc, lit)
    def cmoveq(self, ra, rb, rc, lit=None): self.opr(0x11, 0x24, ra, rb, rc, lit)
    def cmovne(self, ra, rb, rc, lit=None): self.opr(0x11, 0x26, ra, rb, rc, lit)
    def bis(self, ra, rb, rc, lit=None): self.opr(0x11, 0x20, ra, rb, rc, lit)
    def and_(self, ra, rb, rc, lit=None): self.opr(0x11, 0x00, ra, rb, rc, lit)
    def xor(self, ra, rb, rc, lit=None): self.opr(0x11, 0x40, ra, rb, rc, lit)
    def sll(self, ra, rb, rc, lit=None): self.opr(0x12, 0x39, ra, rb, rc, lit)
    def srl(self, ra, rb, rc, lit=None): self.opr(0x12, 0x34, ra, rb, rc, lit)
    def zapnot(self, ra, rb, rc, lit=None): self.opr(0x12, 0x31, ra, rb, rc, lit)
    def insbl(self, ra, rb, rc, lit=None): self.opr(0x12, 0x0B, ra, rb, rc, lit)
    def mskbl(self, ra, rb, rc, lit=None): self.opr(0x12, 0x02, ra, rb, rc, lit)
    def nop(self): self.opr(0x11, 0x20, 31, 31, 31)
    def br(self, ra, t): self.bra(0x30, ra, t)
    def bsr(self, ra, t): self.bra(0x34, ra, t)
    def beq(self, ra, t): self.bra(0x39, ra, t)
    def bne(self, ra, t): self.bra(0x3D, ra, t)
    def blt(self, ra, t): self.bra(0x3A, ra, t)
    def fbeq(self, fa, t): self.bra(0x31, fa, t)
    def fbne(self, fa, t): self.bra(0x35, fa, t)
    def ret(self, rb=26): self._emit(lambda pc: (0x1A << 26) | (31 << 21) | (rb << 16) | (2 << 14) | 1)
    def jsr(self, ra, rb): self._emit(lambda pc: (0x1A << 26) | (ra << 21) | (rb << 16) | (1 << 14))
    def trapb(self): self.word(0x63FF0000)
    def mb(self): self.word(0x63FF4000)
    def call_pal(self, f): self.word(f & 0x3FFFFFF)
    def hw_rei(self): self.word(0x7BFF8000)
    # HW_MTPR/HW_MFPR carry the register in both Ra and Rb (gas does; the chip reads Rb for MTPR)
    def hw_mtpr(self, ra, idx): self.word((0x1D << 26) | (ra << 21) | (ra << 16) | (idx & 0xFFFF))
    def hw_mfpr(self, ra, idx): self.word((0x19 << 26) | (ra << 21) | (ra << 16) | (idx & 0xFFFF))
    def hw_stq_p(self, ra, d, rb): self.word((0x1F << 26) | (ra << 21) | (rb << 16) | 0xC000 | (d & 0xFFF))   # /P quadword
    # IEEE FP: function codes with the trap/rounding qualifiers in the caller's value
    def cmptlt(self, fa, fb, fc, q=0x500): self.fop(0x16, 0x0A6 | q, fa, fb, fc)      # /SU = 0x500
    def cmpteq(self, fa, fb, fc, q=0x500): self.fop(0x16, 0x0A5 | q, fa, fb, fc)
    def cmptle(self, fa, fb, fc, q=0x500): self.fop(0x16, 0x0A7 | q, fa, fb, fc)
    def addt(self, fa, fb, fc, q=0x0C0): self.fop(0x16, 0x0A0 | q, fa, fb, fc)        # /SUI... caller picks
    def cpys(self, fa, fb, fc): self.fop(0x17, 0x020, fa, fb, fc)
    def mt_fpcr(self, fa): self.fop(0x17, 0x024, fa, fa, fa)

    # ------------------------------------------------------------ assembly
    def assemble(self):
        for _ in range(2):          # pass 1 collects labels, pass 2 resolves
            pc = 0; out = bytearray()
            for it in self.items:
                k = it[0]
                if k == 'org':
                    if it[1] < len(out): raise ValueError('org %x goes backwards' % it[1])
                    out += b'\0' * (it[1] - len(out)); pc = it[1]
                elif k == 'align':
                    while len(out) % it[1]: out += b'\0'
                    pc = len(out)
                elif k == 'label':
                    self.labels[it[1]] = pc
                elif k == 'data':
                    out += it[1]; pc = len(out)
                else:
                    try: w = it[1](pc)
                    except KeyError: w = 0
                    out += struct.pack('<I', w & 0xFFFFFFFF); pc = len(out)
        return bytes(out)
