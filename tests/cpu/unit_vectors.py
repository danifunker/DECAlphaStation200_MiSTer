#!/usr/bin/env python3
"""Vectors for the CPU unit benches (verilator/tb_*.cpp) from gen_int.py's
model: one line per case, hex fields.

    unit_vectors.py ialu OUT     op func a b res wr ovf   (opcodes 10, 11, 12)
    unit_vectors.py imul OUT     13 func a b res 1 ovf    (opcode 13)
"""
import random
import sys

sys.path.insert(0, __import__('os').path.dirname(__file__))
import gen_int as g

FUNC = {
    'addl': (0x10, 0x00), 's4addl': (0x10, 0x02), 'subl': (0x10, 0x09), 's4subl': (0x10, 0x0B),
    'cmpbge': (0x10, 0x0F), 's8addl': (0x10, 0x12), 's8subl': (0x10, 0x1B), 'cmpult': (0x10, 0x1D),
    'addq': (0x10, 0x20), 's4addq': (0x10, 0x22), 'subq': (0x10, 0x29), 's4subq': (0x10, 0x2B),
    'cmpeq': (0x10, 0x2D), 's8addq': (0x10, 0x32), 's8subq': (0x10, 0x3B), 'cmpule': (0x10, 0x3D),
    'addl/v': (0x10, 0x40), 'subl/v': (0x10, 0x49), 'cmplt': (0x10, 0x4D), 'addq/v': (0x10, 0x60),
    'subq/v': (0x10, 0x69), 'cmple': (0x10, 0x6D),
    'and': (0x11, 0x00), 'bic': (0x11, 0x08), 'cmovlbs': (0x11, 0x14), 'cmovlbc': (0x11, 0x16),
    'bis': (0x11, 0x20), 'cmoveq': (0x11, 0x24), 'cmovne': (0x11, 0x26), 'ornot': (0x11, 0x28),
    'xor': (0x11, 0x40), 'cmovlt': (0x11, 0x44), 'cmovge': (0x11, 0x46), 'eqv': (0x11, 0x48),
    'cmovle': (0x11, 0x64), 'cmovgt': (0x11, 0x66),
    'amask': (0x11, 0x61), 'implver': (0x11, 0x6C),
    'mskbl': (0x12, 0x02), 'extbl': (0x12, 0x06), 'insbl': (0x12, 0x0B), 'mskwl': (0x12, 0x12),
    'extwl': (0x12, 0x16), 'inswl': (0x12, 0x1B), 'mskll': (0x12, 0x22), 'extll': (0x12, 0x26),
    'insll': (0x12, 0x2B), 'zap': (0x12, 0x30), 'zapnot': (0x12, 0x31), 'mskql': (0x12, 0x32),
    'srl': (0x12, 0x34), 'extql': (0x12, 0x36), 'sll': (0x12, 0x39), 'insql': (0x12, 0x3B),
    'sra': (0x12, 0x3C), 'mskwh': (0x12, 0x52), 'inswh': (0x12, 0x57), 'extwh': (0x12, 0x5A),
    'msklh': (0x12, 0x62), 'inslh': (0x12, 0x67), 'extlh': (0x12, 0x6A), 'mskqh': (0x12, 0x72),
    'insqh': (0x12, 0x77), 'extqh': (0x12, 0x7A),
}
# not in gen_int's model (added to the architecture after the 21064): what EV4 software
# sees, as Linux and SP6's COMCTL32 rely on (docs/design/cpu.md, Q7): AMASK copies Rb (no
# extensions), IMPLVER is 0 (EV4)
LOCAL = {'amask': lambda a, b, c: b, 'implver': lambda a, b, c: 0}
MFUNC = {'mull': 0x00, 'mulq': 0x20, 'umulh': 0x30, 'mull/v': 0x40, 'mulq/v': 0x60}


def ialu(out):
    rnd = random.Random(0x1A1)
    gen = g.Gen(0x1A2)
    n = 0
    with open(out, 'w') as f:
        for op, (opc, fn) in FUNC.items():
            model = LOCAL[op] if op in LOCAL else g.OPS[op]
            for k in range(600):
                if k < len(g.EDGE) ** 2 // 8:
                    a = g.EDGE[k % len(g.EDGE)]
                    b = g.EDGE[(k * 7) % len(g.EDGE)]
                else:
                    a, b = gen.rnd64(), gen.rnd64()
                if k % 5 == 0:
                    b = rnd.getrandbits(8)                 # literal-sized
                c = ~b & g.M64                             # old Rc, distinct from b
                ovf = 0
                if op.endswith('/v'):
                    r = model(a, b, c)
                    ovf = int(r is None)
                    r = g.OPS[op[:-2]](a, b, c)            # the result is written anyway
                else:
                    r = model(a, b, c)
                wr = 0 if (op.startswith('cmov') and r == c) else 1
                if not wr:
                    r = b                                  # the unit drives b; Rc is not written
                f.write(f'{opc:02x} {fn:02x} {a:016x} {b:016x} {r:016x} {wr} {ovf}\n')
                n += 1
    print(f'{out}: {n} vectors')


def imul(out):
    gen = g.Gen(0x1A3)
    n = 0
    with open(out, 'w') as f:
        for op, fn in MFUNC.items():
            for k in range(2000):
                if k < len(g.EDGE) ** 2:
                    a = g.EDGE[k % len(g.EDGE)]
                    b = g.EDGE[k // len(g.EDGE)]
                else:
                    a, b = gen.rnd64(), gen.rnd64()
                ovf = 0
                if op.endswith('/v'):
                    ovf = int(g.OPS[op](a, b, 0) is None)
                    r = g.OPS[op[:-2]](a, b, 0)
                else:
                    r = g.OPS[op](a, b, 0)
                f.write(f'13 {fn:02x} {a:016x} {b:016x} {r:016x} 1 {ovf}\n')
                n += 1
    print(f'{out}: {n} vectors')


if __name__ == '__main__':
    {'ialu': ialu, 'imul': imul}[sys.argv[1]](sys.argv[2])
