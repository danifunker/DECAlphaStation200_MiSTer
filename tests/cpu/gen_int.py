#!/usr/bin/env python3
"""T0 integer tests for the 21064 (docs/CPU_TEST_PLAN.md): self-checking
assembly bodies for every EV4 integer operate instruction, LDA/LDAH, the
loads and stores, branches and jumps. Expected values come from the model
below, written from the Alpha Architecture Reference Manual's pseudocode;
running the same bodies under `qemu-alpha -cpu ev4` (rt/user.S) checks the
model against QEMU, and the PALmode build runs them on the RTL.

    gen_int.py OUTDIR        writes OUTDIR/<suite>.S, one file per suite

Each test leaves its number in $0; on a mismatch it branches to `fail` with
the result in $4 and the expected value in $3 (rt/t0.h reports it).
"""
import os
import random
import sys

M64 = (1 << 64) - 1


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s64(v):
    return sext(v, 64)


def u64(v):
    return v & M64


def zap(x, m):
    for i in range(8):
        if (m >> i) & 1:
            x &= ~(0xFF << (8 * i))
    return u64(x)


XMASK = {'b': 0x01, 'w': 0x03, 'l': 0x0F, 'q': 0xFF}


def ext_l(a, b, x):
    return zap(u64(a) >> ((b & 7) * 8), ~XMASK[x] & 0xFF)


def ext_h(a, b, x):
    loc = (64 - (b & 7) * 8) & 63
    return zap(u64(a << loc), ~XMASK[x] & 0xFF)


def ins_l(a, b, x):
    bm = (XMASK[x] << (b & 7)) & 0xFF
    return zap(u64(a << ((b & 7) * 8)), ~bm & 0xFF)


def ins_h(a, b, x):
    bm = (XMASK[x] << (b & 7)) >> 8
    loc = (64 - (b & 7) * 8) & 63
    return zap(u64(a) >> loc, ~bm & 0xFF)


def msk_l(a, b, x):
    return zap(a, (XMASK[x] << (b & 7)) & 0xFF)


def msk_h(a, b, x):
    return zap(a, (XMASK[x] << (b & 7)) >> 8)


def cmpbge(a, b):
    r = 0
    for i in range(8):
        if ((a >> (8 * i)) & 0xFF) >= ((b >> (8 * i)) & 0xFF):
            r |= 1 << i
    return r


def lw(v):          # longword result: sign-extended low 32 bits
    return u64(sext(v, 32))


# name -> (function(a, b, c) -> result or None for "would trap", kind)
# kind: 'op' plain, 'cmov' (c is the old Rc), 'v' (overflow form, no-trap pairs only)
def add_v32(a, b, sub=False):
    r = sext(a, 32) - sext(b, 32) if sub else sext(a, 32) + sext(b, 32)
    return None if r != sext(r, 32) else lw(r)


def add_v64(a, b, sub=False):
    r = s64(a) - s64(b) if sub else s64(a) + s64(b)
    return None if r != s64(r) else u64(r)


def mul_v32(a, b):
    r = sext(a, 32) * sext(b, 32)
    return None if r != sext(r, 32) else lw(r)


def mul_v64(a, b):
    r = s64(a) * s64(b)
    return None if r != s64(r) else u64(r)


OPS = {
    # INTA (opcode 10)
    'addl':   lambda a, b, c: lw(a + b),
    's4addl': lambda a, b, c: lw(a * 4 + b),
    'subl':   lambda a, b, c: lw(a - b),
    's4subl': lambda a, b, c: lw(a * 4 - b),
    'cmpbge': lambda a, b, c: cmpbge(a, b),
    's8addl': lambda a, b, c: lw(a * 8 + b),
    's8subl': lambda a, b, c: lw(a * 8 - b),
    'cmpult': lambda a, b, c: int(u64(a) < u64(b)),
    'addq':   lambda a, b, c: u64(a + b),
    's4addq': lambda a, b, c: u64(a * 4 + b),
    'subq':   lambda a, b, c: u64(a - b),
    's4subq': lambda a, b, c: u64(a * 4 - b),
    'cmpeq':  lambda a, b, c: int(u64(a) == u64(b)),
    's8addq': lambda a, b, c: u64(a * 8 + b),
    's8subq': lambda a, b, c: u64(a * 8 - b),
    'cmpule': lambda a, b, c: int(u64(a) <= u64(b)),
    'addl/v': lambda a, b, c: add_v32(a, b),
    'subl/v': lambda a, b, c: add_v32(a, b, True),
    'cmplt':  lambda a, b, c: int(s64(a) < s64(b)),
    'addq/v': lambda a, b, c: add_v64(a, b),
    'subq/v': lambda a, b, c: add_v64(a, b, True),
    'cmple':  lambda a, b, c: int(s64(a) <= s64(b)),
    # INTL (opcode 11)
    'and':     lambda a, b, c: a & b,
    'bic':     lambda a, b, c: a & ~b & M64,
    'cmovlbs': lambda a, b, c: b if a & 1 else c,
    'cmovlbc': lambda a, b, c: c if a & 1 else b,
    'bis':     lambda a, b, c: a | b,
    'cmoveq':  lambda a, b, c: b if a == 0 else c,
    'cmovne':  lambda a, b, c: b if a != 0 else c,
    'ornot':   lambda a, b, c: (a | ~b) & M64,
    'xor':     lambda a, b, c: a ^ b,
    'cmovlt':  lambda a, b, c: b if s64(a) < 0 else c,
    'cmovge':  lambda a, b, c: b if s64(a) >= 0 else c,
    'eqv':     lambda a, b, c: (a ^ ~b) & M64,
    'cmovle':  lambda a, b, c: b if s64(a) <= 0 else c,
    'cmovgt':  lambda a, b, c: b if s64(a) > 0 else c,
    # INTS (opcode 12)
    'mskbl':  lambda a, b, c: msk_l(a, b, 'b'),
    'extbl':  lambda a, b, c: ext_l(a, b, 'b'),
    'insbl':  lambda a, b, c: ins_l(a, b, 'b'),
    'mskwl':  lambda a, b, c: msk_l(a, b, 'w'),
    'extwl':  lambda a, b, c: ext_l(a, b, 'w'),
    'inswl':  lambda a, b, c: ins_l(a, b, 'w'),
    'mskll':  lambda a, b, c: msk_l(a, b, 'l'),
    'extll':  lambda a, b, c: ext_l(a, b, 'l'),
    'insll':  lambda a, b, c: ins_l(a, b, 'l'),
    'zap':    lambda a, b, c: zap(a, b & 0xFF),
    'zapnot': lambda a, b, c: zap(a, ~b & 0xFF),
    'mskql':  lambda a, b, c: msk_l(a, b, 'q'),
    'srl':    lambda a, b, c: u64(a) >> (b & 63),
    'extql':  lambda a, b, c: ext_l(a, b, 'q'),
    'sll':    lambda a, b, c: u64(a << (b & 63)),
    'insql':  lambda a, b, c: ins_l(a, b, 'q'),
    'sra':    lambda a, b, c: u64(s64(a) >> (b & 63)),
    'mskwh':  lambda a, b, c: msk_h(a, b, 'w'),
    'inswh':  lambda a, b, c: ins_h(a, b, 'w'),
    'extwh':  lambda a, b, c: ext_h(a, b, 'w'),
    'msklh':  lambda a, b, c: msk_h(a, b, 'l'),
    'inslh':  lambda a, b, c: ins_h(a, b, 'l'),
    'extlh':  lambda a, b, c: ext_h(a, b, 'l'),
    'mskqh':  lambda a, b, c: msk_h(a, b, 'q'),
    'insqh':  lambda a, b, c: ins_h(a, b, 'q'),
    'extqh':  lambda a, b, c: ext_h(a, b, 'q'),
    # INTM (opcode 13)
    'mull':   lambda a, b, c: lw(a * b),
    'mulq':   lambda a, b, c: u64(a * b),
    'umulh':  lambda a, b, c: (u64(a) * u64(b)) >> 64,
    'mull/v': lambda a, b, c: mul_v32(a, b),
    'mulq/v': lambda a, b, c: mul_v64(a, b),
}

SUITES = {
    'inta': [k for k in list(OPS)[:22]],
    'intl': [k for k in list(OPS)[22:36]],
    'ints': [k for k in list(OPS)[36:62]],
    'intm': [k for k in list(OPS)[62:]],
}

EDGE = [0, 1, 2, 3, 7, 8, 63, 64, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF,
        0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x100000000,
        0x7FFFFFFFFFFFFFFF, 0x8000000000000000, M64, M64 - 1,
        0x0123456789ABCDEF, 0xFEDCBA9876543210, 0xFFFFFFFF80000000,
        0x00000000FFFFFFFE, 0x5555555555555555, 0xAAAAAAAAAAAAAAAA]


class Gen:
    def __init__(self, seed):
        self.rnd = random.Random(seed)
        self.n = 0
        self.lines = []

    def rnd64(self):
        r = self.rnd.random()
        if r < 0.3:
            return self.rnd.choice(EDGE)
        if r < 0.45:
            return u64(sext(self.rnd.getrandbits(32), 32))    # longword-shaped
        if r < 0.55:
            return self.rnd.getrandbits(8)
        return self.rnd.getrandbits(64)

    def emit(self, s):
        self.lines.append(s)

    def test_op(self, op, a, b, c, lit=None, ra=1, rc=4):
        """One operate test. lit: use the 8-bit literal form with value lit.
        ra=31 makes Ra read as zero; rc=31 checks the write is discarded."""
        fn = OPS[op]
        av = 0 if ra == 31 else a
        bv = lit if lit is not None else b
        exp = fn(u64(av), u64(bv), u64(c))
        if exp is None:
            return False
        if rc == 31:
            exp = 0
        self.n += 1
        n = self.n
        self.emit(f'\t# {n}: {op} {av:#x}, {bv:#x} (old Rc {c:#x}) -> {exp:#x}')
        self.emit('\t.align 3')
        self.emit('\tnop')
        self.emit('\tbr\t$29, 1f')
        self.emit(f'\t.quad\t{u64(a):#018x}, {u64(b):#018x}, {u64(c):#018x}, {u64(exp):#018x}')
        self.emit(f'1:\tlda\t$0, {n}($31)')
        self.emit('\tldq\t$1, 0($29)')
        self.emit('\tldq\t$2, 8($29)')
        self.emit('\tldq\t$4, 16($29)')
        self.emit('\tldq\t$3, 24($29)')
        src_a = '$31' if ra == 31 else f'${ra}'
        src_b = f'{lit}' if lit is not None else '$2'
        if rc == 31:
            self.emit(f'\t{op}\t{src_a}, {src_b}, $31')
            self.emit('\tbis\t$31, $31, $4')       # result is R31 = 0
        else:
            self.emit(f'\t{op}\t{src_a}, {src_b}, $4')
        self.emit('\txor\t$4, $3, $5')
        self.emit('\tbne\t$5, fail')
        return True

    def suite_ops(self, ops, per_op=40, lits=10):
        for op in ops:
            done = 0
            tries = 0
            # edge pairs first, then random
            pairs = [(x, y) for x in EDGE[::5] for y in EDGE[::4]]
            while done < per_op and tries < per_op * 50:
                tries += 1
                if pairs:
                    a, b = pairs.pop(0)
                else:
                    a, b = self.rnd64(), self.rnd64()
                if op in ('sll', 'srl', 'sra') or op[:3] in ('ext', 'ins', 'msk'):
                    if self.rnd.random() < 0.5:
                        b = self.rnd.getrandbits(64)
                c = self.rnd64()
                if self.test_op(op, a, b, c):
                    done += 1
            for i in range(lits):
                a, c = self.rnd64(), self.rnd64()
                lit = [0, 1, 7, 8, 63, 64, 255, 128][i] if i < 8 else self.rnd.getrandbits(8)
                self.test_op(op, a, 0, c, lit=lit)
            # Ra = R31 and Rc = R31
            self.test_op(op, self.rnd64(), self.rnd64(), self.rnd64(), ra=31)
            self.test_op(op, self.rnd64(), self.rnd64(), self.rnd64(), rc=31)

    def suite_lda(self):
        for _ in range(60):
            base = self.rnd64()
            disp = sext(self.rnd.getrandbits(16), 16)
            for ins, exp in (('lda', u64(base + disp)), ('ldah', u64(base + disp * 65536))):
                self.n += 1
                self.emit(f'\t# {self.n}: {ins} {disp}({base:#x}) -> {exp:#x}')
                self.emit('\t.align 3')
                self.emit('\tnop')
                self.emit('\tbr\t$29, 1f')
                self.emit(f'\t.quad\t{base:#018x}, {exp:#018x}')
                self.emit(f'1:\tlda\t$0, {self.n}($31)')
                self.emit('\tldq\t$1, 0($29)')
                self.emit('\tldq\t$3, 8($29)')
                self.emit(f'\t{ins}\t$4, {disp}($1)')
                self.emit('\txor\t$4, $3, $5')
                self.emit('\tbne\t$5, fail')

    def suite_mem(self):
        """Loads and stores on a 64-byte scratch area inside the test (I-stream
        bytes are ordinary memory here). LDL sign-extends; LDQ_U/STQ_U ignore
        the low three address bits; byte/word access is built from them the
        way pre-BWX code does it."""
        for _ in range(40):
            vals = [self.rnd.getrandbits(64) for _ in range(4)]
            data = b''.join(v.to_bytes(8, 'little') for v in vals)
            q = self.rnd.randrange(4)
            off_l = self.rnd.randrange(8) * 4
            ldl = u64(sext(int.from_bytes(data[off_l:off_l + 4], 'little'), 32))
            off_u = self.rnd.randrange(32)
            ldqu = int.from_bytes(data[off_u & ~7:(off_u & ~7) + 8], 'little')
            for kind, exp, asm in (
                ('ldq', vals[q], [f'\tldq\t$4, {8 * q}($29)']),
                ('ldl', ldl, [f'\tldl\t$4, {off_l}($29)']),
                ('ldq_u', ldqu, [f'\tldq_u\t$4, {off_u}($29)']),
            ):
                self.n += 1
                self.emit(f'\t# {self.n}: {kind} -> {exp:#x}')
                self.emit('\t.align 3')
                self.emit('\tnop')
                self.emit('\tbr\t$29, 1f')
                self.emit('\t.quad\t' + ', '.join(f'{v:#018x}' for v in vals) + f', {exp:#018x}')
                self.emit(f'1:\tlda\t$0, {self.n}($31)')
                self.emit('\tldq\t$3, 32($29)')
                for l in asm:
                    self.emit(l)
                self.emit('\txor\t$4, $3, $5')
                self.emit('\tbne\t$5, fail')
            # stores: STQ, STL (low longword, upper half of the quadword kept),
            # STQ_U, then read back with LDQ
            sv = self.rnd.getrandbits(64)
            offq = self.rnd.randrange(4) * 8
            offl = self.rnd.randrange(8) * 4
            offu = self.rnd.randrange(32)
            for kind, off, size in (('stq', offq, 8), ('stl', offl, 4), ('stq_u', offu, 8)):
                buf = bytearray(data)
                a = off & ~7 if kind == 'stq_u' else off
                buf[a:a + size] = (sv & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
                qa = a & ~7
                exp = int.from_bytes(buf[qa:qa + 8], 'little')
                self.n += 1
                self.emit(f'\t# {self.n}: {kind} {sv:#x} at +{off} -> quad +{qa} = {exp:#x}')
                self.emit('\t.align 3')
                self.emit('\tnop')
                self.emit('\tbr\t$29, 1f')
                self.emit('\t.quad\t' + ', '.join(f'{v:#018x}' for v in vals) +
                          f', {sv:#018x}, {exp:#018x}')
                self.emit(f'1:\tlda\t$0, {self.n}($31)')
                self.emit('\tldq\t$1, 32($29)')
                self.emit('\tldq\t$3, 40($29)')
                self.emit(f'\t{kind}\t$1, {off}($29)')
                self.emit(f'\tldq\t$4, {qa}($29)')
                self.emit('\txor\t$4, $3, $5')
                self.emit('\tbne\t$5, fail')

    def suite_branch(self):
        """Conditional branches taken and not taken for each condition, BR/BSR
        link values, JMP/JSR/RET/JSR_COROUTINE targets and links."""
        conds = {
            'beq': lambda v: v == 0, 'bne': lambda v: v != 0,
            'blt': lambda v: s64(v) < 0, 'bge': lambda v: s64(v) >= 0,
            'ble': lambda v: s64(v) <= 0, 'bgt': lambda v: s64(v) > 0,
            'blbc': lambda v: not v & 1, 'blbs': lambda v: bool(v & 1),
        }
        vals = [0, 1, 2, M64, 0x8000000000000000, 0x7FFFFFFFFFFFFFFF, 0x100, 0xFFFFFFFE]
        for b, f in conds.items():
            for v in vals:
                taken = f(v)
                self.n += 1
                self.emit(f'\t# {self.n}: {b} {v:#x} -> {"taken" if taken else "not taken"}')
                self.emit('\t.align 3')
                self.emit('\tnop')
                self.emit('\tbr\t$29, 1f')
                self.emit(f'\t.quad\t{v:#018x}')
                self.emit(f'1:\tlda\t$0, {self.n}($31)')
                self.emit('\tldq\t$1, 0($29)')
                self.emit(f'\tlda\t$3, {int(taken)}($31)')
                self.emit('\tbis\t$31, $31, $4')
                self.emit(f'\t{b}\t$1, 2f')
                self.emit('\tbr\t$31, 3f')
                self.emit('2:\tlda\t$4, 1($31)')
                self.emit('3:\txor\t$4, $3, $5')
                self.emit('\tbne\t$5, fail')
        # BSR / BR link: the address of the next instruction
        for ins in ('br', 'bsr'):
            self.n += 1
            self.emit(f'\t# {self.n}: {ins} link = PC + 4')
            self.emit(f'\tlda\t$0, {self.n}($31)')
            self.emit('\tbr\t$3, 1f')
            self.emit(f'1:\t{ins}\t$4, 2f')
            self.emit('2:\tlda\t$3, 4($3)')
            self.emit('\txor\t$4, $3, $5')
            self.emit('\tbne\t$5, fail')
        # backward branch
        self.n += 1
        self.emit(f'\t# {self.n}: a backward-branch loop, 10 iterations')
        self.emit(f'\tlda\t$0, {self.n}($31)')
        self.emit('\tlda\t$1, 10($31)')
        self.emit('\tbis\t$31, $31, $4')
        self.emit('1:\taddq\t$4, 3, $4')
        self.emit('\tsubq\t$1, 1, $1')
        self.emit('\tbne\t$1, 1b')
        self.emit('\tlda\t$3, 30($31)')
        self.emit('\txor\t$4, $3, $5')
        self.emit('\tbne\t$5, fail')
        # JMP/JSR/RET/JSR_COROUTINE: target = Rb & ~3, link = PC + 4
        for ins in ('jmp', 'jsr', 'ret', 'jsr_coroutine'):
            for low in (0, 3):
                self.n += 1
                self.emit(f'\t# {self.n}: {ins} to a target with low bits {low}, link = PC + 4')
                self.emit(f'\tlda\t$0, {self.n}($31)')
                self.emit('\tbr\t$2, 1f')
                self.emit(f'1:\tlda\t$2, 2f-1b+{low}($2)')     # target | low bits
                self.emit('\tbr\t$3, 3f')
                self.emit(f'3:\tlda\t$3, 4f-3b+4($3)')         # expected link: the jump + 4
                self.emit(f'4:\t{ins}\t$4, ($2)')
                self.emit('\tbr\t$31, fail')                    # not reached
                self.emit('2:\txor\t$4, $3, $5')
                self.emit('\tbne\t$5, fail')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'build'
    os.makedirs(out, exist_ok=True)
    for i, (name, ops) in enumerate(list(SUITES.items()) + [('lda', None), ('mem', None), ('branch', None)]):
        g = Gen(0xA1F0 + i)
        if ops is not None:
            g.suite_ops(ops)
        else:
            getattr(g, 'suite_' + name)()
        with open(os.path.join(out, name + '.S'), 'w') as f:
            f.write(f'// T0 suite "{name}": {g.n} tests, generated by tests/cpu/gen_int.py\n')
            f.write('#include "t0.h"\n\tTEST_BEGIN\n')
            f.write('\n'.join(g.lines))
            f.write('\n\tTEST_PASS\n\tTEST_END\n')
        print(f'{name}: {g.n} tests')


if __name__ == '__main__':
    main()
