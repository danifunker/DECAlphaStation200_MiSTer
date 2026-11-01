# CPU tests (docs/CPU_TEST_PLAN.md)

## T0: per-instruction self-checking tests

`gen_int.py` writes one assembly body per suite into `build/`, with the
expected values from its own model of the Alpha Architecture Reference
Manual's pseudocode:

| suite | covers |
|---|---|
| `inta` | opcode 10: ADD/SUB (L/Q, scaled, /V without overflow), CMPxx, CMPBGE |
| `intl` | opcode 11: logic and every CMOV |
| `ints` | opcode 12: shifts, EXT/INS/MSK (all 8 byte positions), ZAP/ZAPNOT |
| `intm` | opcode 13: MULL, MULQ, UMULH, /V without overflow |
| `lda`  | LDA, LDAH |
| `mem`  | LDQ, LDL (sign extension), LDQ_U, STQ, STL, STQ_U |
| `branch` | every conditional branch taken/not taken, BR/BSR links, a loop, JMP/JSR/RET/JSR_COROUTINE (target low bits ignored, link) |

Every operate instruction gets edge and random register pairs, the 8-bit
literal form, Ra = R31 and Rc = R31. A test keeps its operands inline after
a `br` (so the code is position independent), leaves its number in `$0`,
and on a mismatch branches to `fail` with the result in `$4` and the
expected value in `$3`.

`make` builds them as Linux user programs (`rt/t0.h` with `T0_USER`, no
libc: Ubuntu's static glibc uses BWX, which `-cpu ev4` traps) and runs them
under `qemu-alpha -cpu ev4`, so QEMU confirms the model. `check_ev4.py`
rejects non-EV4 instructions (BWX/FIX/CIX/MVI), which `as -m21064` accepts.

Not covered yet (later suites): overflow traps (/V), unaligned-access traps,
LDx_L/STx_C, RPCC, FP (T2), PALmode and IPRs (T3).

The bare-metal PALmode build (`rt/t0_pal.h`) for the RTL harness and
alphaemu comes with the CPU specification (`docs/design/cpu.md`).
