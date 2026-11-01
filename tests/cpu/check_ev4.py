#!/usr/bin/env python3
"""Fail if an Alpha binary contains instructions the 21064 does not have:
BWX (ldbu, ldwu, stb, stw, sextb, sextw), FIX (sqrt*, itof*, ftoi*), CIX
(ctpop, ctlz, cttz) and MVI (opcode 1C functions perr, minub8 ...). The
assembler accepts them even with -m21064, so every test is scanned.

    check_ev4.py FILE...     .s/.S files: the mnemonics as written;
                             anything else: an objdump disassembly (compiled
                             code; inline data shows up as false hits there)
"""
import re
import subprocess
import sys

BAD = re.compile(r'^(ldbu|ldwu|stb|stw|sextb|sextw|sqrt[fgst]\S*|itof[fst]|ftoi[st]|'
                 r'ctpop|ctlz|cttz|perr|minu[bw]8|mins[bw]8|maxu[bw]8|maxs[bw]8|'
                 r'pklb|pkwb|unpkbl|unpkbw)$')

bad = 0
for f in sys.argv[1:]:
    if f.endswith(('.s', '.S')):
        for n, line in enumerate(open(f), 1):
            m = re.match(r'^(?:\w+:)?\s+([a-z_0-9/]+)\s', line.split('//')[0].split('#')[0] + ' ')
            if m and BAD.match(m.group(1)):
                print(f'{f}:{n}: non-EV4 instruction: {line.strip()}')
                bad += 1
        continue
    out = subprocess.run(['alpha-linux-gnu-objdump', '-d', f], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split('\t')
        if len(parts) >= 3 and BAD.match(parts[2].strip()):
            print(f'{f}: non-EV4 instruction: {line.strip()}')
            bad += 1
sys.exit(1 if bad else 0)
