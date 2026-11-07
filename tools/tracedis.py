#!/usr/bin/env python3
"""Annotate a system-simulator retire trace (tb_sys.cpp --trace: "PC INSN [rN=VAL] [mADDR=VAL/SIZE]")
with the disassembly of each instruction.

usage: tracedis.py TRACE [--from LINE] [-n COUNT] [--pc LO HI] [--grep REGEX]
  --from LINE   start at this 1-based line
  -n COUNT      at most COUNT lines (default all)
  --pc LO HI    only PCs in [LO, HI) (hex)
  --grep RE     only lines whose annotated text matches RE (Python regex)
"""
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from alphadis import dis


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__); return
    start = int(a[a.index('--from') + 1]) if '--from' in a else 1
    count = int(a[a.index('-n') + 1]) if '-n' in a else -1
    lo = int(a[a.index('--pc') + 1], 16) if '--pc' in a else 0
    hi = int(a[a.index('--pc') + 2], 16) if '--pc' in a else 1 << 64
    rx = re.compile(a[a.index('--grep') + 1]) if '--grep' in a else None
    n = 0
    with open(a[0], errors='replace') as f:
        for ln, l in enumerate(f, 1):
            if ln < start:
                continue
            p = l.split()
            if len(p) < 2:
                continue
            pc = int(p[0], 16); w = int(p[1], 16)
            if not (lo <= pc < hi):
                continue
            s = '%d: %016x %08x  %-36s %s' % (ln, pc, w, dis(pc, w), ' '.join(p[2:]))
            if rx and not rx.search(s):
                continue
            print(s)
            n += 1
            if count >= 0 and n >= count:
                break


if __name__ == '__main__':
    main()
