#!/usr/bin/env python3
"""Test vectors for rtl/cpu/ev4_fpu.v from fpmodel.py (docs/design/fpu.md).

One line per vector, hex: IR FA FB DYN RESULT FPCR6 EXC7 TRAP.
For every legal function code (cpu.md 8.1, each qualifier) --n random
operand sets plus the directed edge cases, then --mix vectors with random
operations back to back.

  gen_fpu.py [--n 20000] [--mix 200000] [--seed 1] [--jobs 3] [--only ADDT,...] > fpu.vec
"""
import argparse
import multiprocessing
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fpmodel import model, legal, FMT  # noqa: E402

M64 = (1 << 64) - 1

# base operations: name -> (opcode, function code without the trap/rounding bits)
BASE = {}
for nm, f in (('ADD', 0), ('SUB', 1), ('MUL', 2), ('DIV', 3)):
    BASE[nm + 'S'] = (0x16, 0x00 | f)
    BASE[nm + 'T'] = (0x16, 0x20 | f)
    BASE[nm + 'F'] = (0x15, 0x00 | f)
    BASE[nm + 'G'] = (0x15, 0x20 | f)
BASE.update({'CMPTUN': (0x16, 0x24), 'CMPTEQ': (0x16, 0x25), 'CMPTLT': (0x16, 0x26),
             'CMPTLE': (0x16, 0x27), 'CVTTS': (0x16, 0x2C), 'CVTTQ': (0x16, 0x2F),
             'CVTQS': (0x16, 0x3C), 'CVTQT': (0x16, 0x3E),
             'CMPGEQ': (0x15, 0x25), 'CMPGLT': (0x15, 0x26), 'CMPGLE': (0x15, 0x27),
             'CVTGF': (0x15, 0x2C), 'CVTGD': (0x15, 0x2D), 'CVTDG': (0x15, 0x1E),
             'CVTGQ': (0x15, 0x2F), 'CVTQF': (0x15, 0x3C), 'CVTQG': (0x15, 0x3E)})


def codes(name):
    """Every legal function code of a base op (CVTST rides with CVTTS)."""
    opc, f = BASE[name]
    out = []
    for hi in range(32):                        # trap [10:8], rounding [7:6]
        fn = (hi << 6) | f
        ir = (opc << 26) | (31 << 21) | (31 << 16) | (fn << 5) | 31
        if legal(ir):
            out.append(ir)
    return out


# ---------------------------------------------------------------- operands
def fields(fmt):
    """(frac bits, register exponent of E = 0, Emin, Emax) for the register format."""
    p, emin, emax = FMT[fmt]
    bias = {'T': 1023, 'S': 1023, 'G': 1025, 'F': 1025, 'D': 129}[fmt]
    return p - 1, bias, emin, emax


def rand_frac(r, nb):
    k = r.random()
    if k < 0.40:
        return r.getrandbits(nb)
    if k < 0.55:                                 # few significant bits: exact results and ties
        t = r.randint(1, nb)
        return r.getrandbits(t) << (nb - t)
    if k < 0.65:                                 # sparse
        v = 0
        for _ in range(r.randint(1, 3)):
            v |= 1 << r.randrange(nb)
        return v
    if k < 0.75:                                 # all ones, minus a little
        return ((1 << nb) - 1) ^ (r.getrandbits(r.randint(0, 4)))
    if k < 0.85:
        return r.getrandbits(r.randint(0, 4))    # 1.000..0x
    if k < 0.92:                                 # long runs
        a, b = sorted((r.randrange(nb + 1), r.randrange(nb + 1)))
        return ((1 << b) - 1) ^ ((1 << a) - 1)
    return 0


def rand_E(r, emin, emax):
    k = r.random()
    if k < 0.35:
        return r.randint(emin, emax)
    if k < 0.55:
        return r.randint(-8, 8)
    if k < 0.70:
        return r.randint(emin, emin + 4)
    if k < 0.85:
        return r.randint(emax - 4, emax)
    return r.randint(max(emin, -70), min(emax, 70))


def enc(fmt, s, E, f):
    nb, bias, _, _ = fields(fmt)
    if fmt == 'D':
        return s << 63 | (E + bias) << 55 | f
    if fmt in ('S', 'F'):
        return s << 63 | (E + bias) << 52 | f << 29
    return s << 63 | (E + bias) << 52 | f


def special(r, fmt):
    """Zeros and non-finite encodings."""
    nb, bias, emin, emax = fields(fmt)
    s = r.getrandbits(1)
    fsh = 29 if fmt in ('S', 'F') else 0
    nz = (r.getrandbits(nb) or 1) << fsh
    if fmt in ('T', 'S'):
        return r.choice([s << 63, s << 63 | nz,                    # zero, denormal
                         s << 63 | 0x7FF << 52,                    # infinity
                         s << 63 | 0x7FF << 52 | nz])              # NaN
    if fmt == 'D':
        return r.choice([0, 1 << 63, 1 << 63 | r.getrandbits(55), r.getrandbits(55) or 1])
    return r.choice([0, 0, 1 << 63, 1 << 63 | nz, nz])            # true zero, reserved, dirty


def rand_val(r, fmt, E=None):
    nb, bias, emin, emax = fields(fmt)
    if E is None:
        if r.random() < 0.05:
            return special(r, fmt)
        E = rand_E(r, emin, emax)
    E = max(emin, min(emax, E))
    return enc(fmt, r.getrandbits(1), E, rand_frac(r, nb))


def unpackE(fmt, v):
    nb, bias, _, _ = fields(fmt)
    e = (v >> 55) & 0xFF if fmt == 'D' else (v >> 52) & 0x7FF
    return e - bias


def near(r, fmt, a):
    """An operand close to a: same or nearby exponent, nearby fraction."""
    nb, bias, emin, emax = fields(fmt)
    if ((a >> 52) & 0x7FF) == 0:
        return rand_val(r, fmt)
    E = unpackE(fmt, a) + r.choice([0, 0, 0, 1, -1, 2, -2, r.randint(-60, 60)])
    E = max(emin, min(emax, E))
    fsh = 29 if fmt in ('S', 'F') else 0
    f = (a >> fsh) & ((1 << nb) - 1)
    f = (f + r.randint(-3, 3)) & ((1 << nb) - 1) if r.random() < 0.5 else rand_frac(r, nb)
    return enc(fmt, r.getrandbits(1), E, f)


def rand_int(r):
    k = r.random()
    if k < 0.3:
        v = r.getrandbits(64)
    elif k < 0.6:
        v = r.getrandbits(r.randint(0, 64))
    elif k < 0.8:                                # ties for 24/53 bits: a short pattern then zeros
        t = r.randint(20, 64)
        v = (r.getrandbits(r.randint(1, 26)) | 1) << (t - 26) if t > 26 else r.getrandbits(t)
        v &= M64
    else:
        v = (1 << r.randint(0, 63)) + r.randint(-2, 2)
        v &= M64
    if r.random() < 0.5:
        v = (-v) & M64
    return v


def toint_val(r, fmt):
    """Floating values for CVTxQ: around the integers, the 2**63 boundary."""
    nb, bias, emin, emax = fields(fmt)
    k = r.random()
    if k < 0.05:
        return special(r, fmt)
    if k < 0.65:
        E = r.randint(-3, 66)
    elif k < 0.80:
        E = r.choice([62, 63, 64])
    else:
        E = rand_E(r, emin, emax)
    return enc(fmt, r.getrandbits(1), E, rand_frac(r, nb))


def operands(r, name):
    """(fa, fb) for one vector of a base op."""
    if name in ('CVTQS', 'CVTQT', 'CVTQF', 'CVTQG'):
        return 0, rand_int(r)
    if name in ('CVTTQ', 'CVTGQ'):
        return 0, toint_val(r, 'T' if name == 'CVTTQ' else 'G')
    if name == 'CVTTS':
        if r.random() < 0.3:                     # canonical S values (the CVTST operands)
            return 0, rand_val(r, 'S')
        if r.random() < 0.6:                     # around the S range and its edges
            _, emin, emax = FMT['S']
            E = r.choice([r.randint(emin - 30, emin + 2), r.randint(emax - 2, emax + 3),
                          r.randint(emin, emax)])
            return 0, enc('T', r.getrandbits(1), E, rand_frac(r, 52))
        return 0, rand_val(r, 'T')
    if name == 'CVTGF':
        if r.random() < 0.6:
            _, emin, emax = FMT['F']
            E = r.choice([r.randint(emin - 30, emin + 2), r.randint(emax - 2, emax + 3),
                          r.randint(emin, emax)])
            return 0, enc('G', r.getrandbits(1), E, rand_frac(r, 52))
        return 0, rand_val(r, 'G')
    if name == 'CVTGD':
        _, emin, emax = FMT['D']
        E = r.choice([r.randint(emin - 4, emin + 2), r.randint(emax - 2, emax + 4),
                      r.randint(emin, emax), None])
        return 0, (rand_val(r, 'G') if E is None else enc('G', r.getrandbits(1), E, rand_frac(r, 52)))
    if name == 'CVTDG':
        return 0, rand_val(r, 'D')
    fmt = name[-1] if name[-1] in 'STFG' else ('T' if name.startswith('CMPT') else 'G')
    a = rand_val(r, fmt)
    k = r.random()
    if k < 0.35:
        b = near(r, fmt, a)
    elif k < 0.55 and name[:3] in ('MUL', 'DIV') and (a >> 52) & 0x7FF:
        # aim the result exponent at the range edges
        _, emin, emax = FMT[fmt]
        tgt = r.choice([emin - 2, emin - 1, emin - 1, emin, emin + 1, emax - 1, emax, emax, emax + 1])
        Ea = unpackE(fmt, a)
        Eb = tgt - Ea if name[:3] == 'MUL' else Ea - tgt
        nb = fields(fmt)[0]
        if FMT[fmt][1] <= Eb <= FMT[fmt][2]:
            fb = r.choice([0, 0, rand_frac(r, nb), (1 << nb) - 1, 1])
            b = enc(fmt, r.getrandbits(1), Eb, fb)
        else:
            b = rand_val(r, fmt)
    elif k < 0.70 and name[:3] in ('ADD', 'SUB') and (a >> 52) & 0x7FF:
        # tiny results: both near the bottom of the range
        _, emin, emax = FMT[fmt]
        a = enc(fmt, r.getrandbits(1), r.randint(emin, emin + 2), rand_frac(r, fields(fmt)[0]))
        b = near(r, fmt, a)
    else:
        b = rand_val(r, fmt)
    if r.random() < 0.5:
        a, b = b, a
    return a, b


def directed(name):
    """Operand pairs from the edge values of the op's formats."""
    if name in ('CVTQS', 'CVTQT', 'CVTQF', 'CVTQG'):
        vals = [0, 1, M64, 1 << 63, (1 << 63) - 1, (1 << 53) - 1, 1 << 53, (1 << 53) + 1,
                (1 << 54) + 2, (1 << 54) + 3, (1 << 24) + 1, (1 << 25) + 1, (1 << 25) + 3,
                (1 << 64) - (1 << 53) - 1, (1 << 64) - (1 << 10)]
        vals += [(-v) & M64 for v in vals]
        return [(0, v) for v in vals]
    fmts = {'CVTTQ': 'T', 'CVTGQ': 'G', 'CVTTS': 'T', 'CVTGF': 'G', 'CVTGD': 'G', 'CVTDG': 'D'}
    fmt = fmts.get(name) or (name[-1] if name[-1] in 'STFG' else ('T' if name.startswith('CMPT') else 'G'))
    nb, bias, emin, emax = fields(fmt)
    ones = (1 << nb) - 1
    vals = []
    for s in (0, 1):
        for E, f in ((emin, 0), (emin, 1), (emin, ones), (emin + 1, 0), (emax, ones), (emax, ones - 1),
                     (emax, 0), (0, 0), (0, 1), (0, ones), (-1, ones), (1, 0), (52, 0), (62, ones),
                     (63, 0), (63, 1), (-2, 0), (-1, 0)):
            if emin <= E <= emax:
                vals.append(enc(fmt, s, E, f))
    r = random.Random(7)
    for _ in range(4):
        vals.append(special(r, fmt))
    if fmt in ('T', 'S'):
        vals += [0, 1 << 63, 0x7FF << 52, 0xFFF << 52, 0x7FF8 << 48, 0x7FF0 << 48 | 1, 1 << 29]
    tgt = {'CVTTS': 'S', 'CVTGF': 'F', 'CVTGD': 'D'}.get(name)
    if tgt:                                      # the destination's range edges
        _, temin, temax = FMT[tgt]
        tb = FMT[tgt][0] - 1                     # destination fraction bits
        for s in (0, 1):
            for E in (temin - 2, temin - 1, temin, temax, temax + 1):
                for f in (0, 1, ones, ones - 1, ones ^ ((1 << max(0, nb - tb)) - 1),
                          ones ^ ((1 << max(0, nb - tb)) - 1) ^ (1 << max(0, nb - tb - 1)) if nb > tb else 2,
                          1 << max(0, nb - tb - 1)):
                    vals.append(enc(fmt, s, E, f & ones))
    if name in ('CVTTQ', 'CVTGQ', 'CVTTS', 'CVTGF', 'CVTGD', 'CVTDG'):
        return [(0, v) for v in vals]
    return [(a, b) for a in vals for b in vals]


def gen_name(args):
    name, n, seed = args
    r = random.Random(f'{seed}-{name}')
    irs = codes(name)
    out = []
    pairs = directed(name) + [operands(r, name) for _ in range(n)]
    for a, b in pairs:
        for ir in irs:
            dyn = r.getrandbits(2)
            res = model(ir, a, b, dyn)
            out.append('%08x %016x %016x %x %016x %02x %02x %x\n' % ((ir, a, b, dyn) + res))
    return name, len(irs), ''.join(out)


def gen_mix(args):
    k, n, seed = args
    r = random.Random(f'{seed}-mix-{k}')
    names = sorted(BASE)
    allc = {nm: codes(nm) for nm in names}
    out = []
    for _ in range(n):
        nm = r.choice(names)
        if nm.startswith('DIV') and r.random() < 0.7:
            nm = r.choice([x for x in names if not x.startswith('DIV')])
        ir = r.choice(allc[nm])
        a, b = operands(r, nm)
        dyn = r.getrandbits(2)
        out.append('%08x %016x %016x %x %016x %02x %02x %x\n' % ((ir, a, b, dyn) + model(ir, a, b, dyn)))
    return ''.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=20000)
    ap.add_argument('--mix', type=int, default=200000)
    ap.add_argument('--seed', default='1')
    ap.add_argument('--jobs', type=int, default=3)
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    names = sorted(BASE) if not a.only else a.only.split(',')
    with multiprocessing.Pool(a.jobs) as pool:
        for name, nq, text in pool.imap_unordered(gen_name, [(nm, a.n, a.seed) for nm in names]):
            sys.stdout.write(text)
            sys.stderr.write(f'gen_fpu: {name}: {nq} codes\n')
        chunks = 16
        for text in pool.imap_unordered(gen_mix, [(k, a.mix // chunks, a.seed) for k in range(chunks)]):
            sys.stdout.write(text)
    sys.stdout.flush()


if __name__ == '__main__':
    main()
