#!/usr/bin/env python3
"""Second reading of fpmodel.py: QEMU's Alpha emulation (qemu-alpha -cpu ev4).

For every base operation, --n operand sets through every function code are
run in a libc-free user program (each vector: load Fa, Fb and an FPCR with
the vector's DYN, the instruction, MF_FPCR, write the result and the FPCR to
stdout). Only vectors the model says do not trap are run (a trap would be a
SIGFPE). Compared: the result, and FPCR INE/IOV where the 21064 and QEMU agree
by design. Known differences, reported separately, not counted as errors:
  - QEMU rounds VAX "normal" to nearest even; the VAX rule is ties away from
    zero (ARM 4.7.5), so on an exact tie QEMU's result is 1 LSB off.
  - QEMU sets FPCR[INE] for divides; the 21064 never does (HRM 2.6).
  - Underflow without /U: QEMU flushes to a signed zero; EV4 writes true zero.
  - Results that round up to MIN (ARM 4.7.5): QEMU underflows (tininess before rounding).
  - QEMU maps G onto T, so both ends of the G range (exponents 1, 2, 2046, 2047) are lost.
  - QEMU writes F results with the F exponent not mapped to the register's 11 bits.
  - CVTST of a register that is not a canonical S value is UNPREDICTABLE (ARM 4.7.1).
  - FPCR INE/IOV bits are counted as information only (QEMU records them differently).

  qemu_check.py [--n 300] [--only ADDG,...]   (default: the IEEE operations and CMPGxx)
"""
import argparse
import os
import random
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpmodel                                   # noqa: E402
from gen_fpu import BASE, codes, operands, directed   # noqa: E402

CC = 'alpha-linux-gnu-gcc'
QEMU = ['qemu-alpha', '-cpu', 'ev4']


def build_and_run(vecs, tmp):
    """vecs: [(ir, fa, fb, dyn)] -> list of (result, fpcr) for the vectors run before any crash."""
    lines = ['\t.set noreorder', '\t.set noat', '\t.text', '\t.globl _start', '_start:',
             '\tlda $30, -64($30)', '\tbr $2, code', 'tbl:']
    for ir, a, b, dyn in vecs:
        lines.append('\t.quad 0x%x, 0x%x, 0x%x' % (a, b, dyn << 58))
    lines.append('code:')
    for ir, a, b, dyn in vecs:
        ir = (ir & ~((31 << 21) | (31 << 16) | 31)) | (1 << 21) | (2 << 16) | 4   # f1 op f2 -> f4
        if (ir >> 5) & 0xF >= 8:                     # conversions: Fa = f31
            ir |= 31 << 21
        lines += ['\tldt $f1, 0($2)', '\tldt $f2, 8($2)', '\tldt $f3, 16($2)', '\tmt_fpcr $f3',
                  '\texcb', '\t.long 0x%08x' % ir, '\texcb', '\tmf_fpcr $f5',
                  '\tstt $f4, 0($30)', '\tstt $f5, 8($30)',
                  '\tlda $0, 4($31)', '\tlda $16, 1($31)', '\tbis $30, $30, $17', '\tlda $18, 16($31)',
                  '\tcall_pal 0x83', '\tlda $2, 24($2)']
    lines += ['\tlda $0, 1($31)', '\tbis $31, $31, $16', '\tcall_pal 0x83']
    s = os.path.join(tmp, 'q.S')
    x = os.path.join(tmp, 'q')
    with open(s, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    subprocess.run([CC, '-nostdlib', '-static', '-mcpu=ev4', '-o', x, s], check=True)
    p = subprocess.run(QEMU + [x], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out = p.stdout
    return [struct.unpack('<QQ', out[i:i + 16]) for i in range(0, len(out) - 15, 16)]


# QEMU's VAX arithmetic and conversions are not a usable reference (1.0 + 1.5 = 2.0 in ADDG,
# F results with unmapped exponents, traps on CVTGQ/CVTGF/...), so by default only the IEEE
# operations and the VAX compares are run; --only runs any of them.
DEFAULT = sorted(n for n in BASE if BASE[n][0] == 0x16) + ['CMPGEQ', 'CMPGLE', 'CMPGLT']
MINS = (0x0010000000000000, 0x3810000000000000, 0x0080000000000000)   # T/G, S/F, D smallest normals


def canon_s(r):
    e = (r >> 52) & 0x7FF
    return r & ((1 << 29) - 1) == 0 and (e in (0, 0x7FF) or 897 <= e <= 1150)


def classify(name, v, qr):
    ir, fa, fb, dyn, res, fpcr = v
    vax = ir >> 26 == 0x15
    fn = (ir >> 5) & 0x7FF
    if qr == res:
        return 'same'
    if not vax and fn in (0x2AC, 0x6AC) and not canon_s(fb):
        return 'unpred'                          # CVTST of a non-S value: UNPREDICTABLE (ARM 4.7.1)
    if vax and (fn >> 6) & 3 == 2 and fpmodel.model(ir, fa, fb, dyn, vax_rne=True)[0] == qr:
        return 'tie'                             # QEMU's nearest even vs the VAX tie rule
    if fpcr & 8 and qr & ~(1 << 63) == 0:
        return 'unf'                             # true zero here, a signed zero in QEMU
    if res & ~(1 << 63) in MINS and qr & ~(1 << 63) == 0:
        return 'minedge'                         # rounds up to MIN (ARM 4.7.5); QEMU flushes
    if vax and qr == (res - (896 << 52)) & ((1 << 64) - 1):
        return 'fbug'                            # QEMU writes F results with the 8-bit F exponent unmapped
    if vax and any(((x >> 52) & 0x7FF) in (1, 2, 2046, 2047) for x in (fa, fb, res)):
        return 'grange'                          # QEMU maps G onto T: both ends of the G range are lost
    return 'bad'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=300)
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    names = DEFAULT if not a.only else a.only.split(',')
    keys = ('same', 'tie', 'unf', 'minedge', 'grange', 'fbug', 'unpred', 'bad', 'qtrap')
    tot = dict.fromkeys(keys + ('flags',), 0)
    shown = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name in names:
            r = random.Random('q-' + name)
            pairs = directed(name)[:400] + [operands(r, name) for _ in range(a.n)]
            vecs = []
            for fa, fb in pairs:
                for ir in codes(name):
                    dyn = r.getrandbits(2)
                    res, fpcr, exc, trap = fpmodel.model(ir, fa, fb, dyn)
                    if not trap:
                        vecs.append((ir, fa, fb, dyn, res, fpcr))
            st = dict.fromkeys(keys + ('flags',), 0)
            i = 0
            while i < len(vecs):
                chunk = vecs[i:i + 3000]
                got = build_and_run([v[:4] for v in chunk], tmp)
                for v, (qr, qf) in zip(chunk, got):
                    c = classify(name, v, qr)
                    st[c] += 1
                    if c == 'same' and (qf >> 52) & 0x30 != v[5] & 0x30:
                        st['flags'] += 1                 # INE/IOV recorded differently (information only)
                    if c == 'bad' and shown < 25:
                        shown += 1
                        print('%-6s %08x fa %016x fb %016x dyn %d: model %016x fpcr %02x, qemu %016x fpcr %02x'
                              % ((name,) + v + (qr, (qf >> 52) & 0x3F)))
                if len(got) < len(chunk):                # QEMU trapped on this one: skip it
                    v = chunk[len(got)]
                    if (v[0] >> 5) & 0x7FF in (0x2AC, 0x6AC) and v[0] >> 26 == 0x16 and not canon_s(v[2]):
                        st['unpred'] += 1
                    elif v[4] & ~(1 << 63) in MINS:
                        st['minedge'] += 1               # QEMU's underflow trap at the MIN edge
                    else:
                        st['qtrap'] += 1
                        if shown < 25:
                            shown += 1
                            print('%-6s %08x fa %016x fb %016x: QEMU traps, the model does not' % ((name,) + v[:3]))
                    i += len(got) + 1
                else:
                    i += len(chunk)
            print('%-7s %6d: %6d same, %4d VAX ties, %4d unf, %4d MIN edge, %4d G range, %4d F exp, %4d unpredictable, %4d differ, '
                  '%d QEMU-only traps; %d with other INE/IOV' % ((name, sum(st[k] for k in keys)) +
                                                                 tuple(st[k] for k in keys) + (st['flags'],)))
            for k in st:
                tot[k] += st[k]
    print('qemu_check: %d vectors: %d same, %d VAX ties, %d underflows, %d MIN edge, %d G range, %d F exponent, %d unpredictable, %d differ, '
          '%d QEMU-only traps; %d with other INE/IOV flags' % ((sum(tot[k] for k in keys),) +
                                                                tuple(tot[k] for k in keys) + (tot['flags'],)))
    return 1 if tot['bad'] or tot['qtrap'] else 0


if __name__ == '__main__':
    sys.exit(main())
