# The FP arithmetic unit (`rtl/cpu/ev4_fpu.v`)

The 21064's Fbox arithmetic: opcode 0x16 (IEEE S/T) and opcode 0x15 (VAX F/G, D as a conversion
format), as a standalone unit for `ev4_core` (pipeline.md 6). The architecture is `cpu.md` 8;
this document is the unit, its interface, its exception rules as implemented, how the core
integrates it, and its tests. The FP register file, loads/stores and opcode 0x17 (CPYSx, FCMOV,
MT/MF_FPCR, CVTLQ/CVTQL) stay in the core.

## 1. Interface

```
ev4_fpu #(TAG_W = 6) (
  clk, rst,
  kill,                   // drop everything in flight (no done follows), the divider too
  start,                  // one cycle: begin the operation in ir on fa, fb
  ir[31:0],               // the instruction; [31:26] opcode 15/16 and [15:5] function are used
  fa[63:0], fb[63:0],     // Fa, Fb in register format (cpu.md 8.3); Fb holds the quadword for CVTQx
  fpcr_dyn[1:0],          // FPCR[59:58], used for /D
  tag[TAG_W-1:0],         // returned with done (e.g. the destination register)
  busy,                   // a divide is running: start must be low
  done,                   // one cycle, with:
  done_tag, result[63:0], // the value to write to Fc (register format)
  fpcr_set[5:0],          // FPCR[57:52] bits to OR in: [0] INV [1] DZE [2] OVF [3] UNF [4] INE [5] IOV
  exc_sum[6:0],           // EXC_SUM[8:2]: [0] SWC [1] INV [2] DZE [3] FOV [4] UNF [5] INE [6] IOV
  trap)                   // take ARITH (= |exc_sum[6:1])
```

`ev4_fpu_dec (ir -> fen, legal, div, rd_fa, rd_fb)` is the combinational decode for the core's D
stage: `fen` = opcode 16 with source field 01 (FEN whatever FPE says), `legal` = one of the 292
function codes of cpu.md 8.1 (the same set binutils' opcode table has for opcodes 15/16;
anything else is OPCDEC), `div` = the long-latency DIVx, `rd_fa` = reads Fa (the two-operand
operations; conversions read only Fb). An illegal code given to `ev4_fpu` gives an undefined
result.

`start`, `ir`, `fa`, `fb`, `fpcr_dyn` and `tag` must come straight from flops: the first stage
is one 64-bit carry chain deep (the `|a| >= |b|` compare and the integer negate).

## 2. Latencies

| Operations | start -> done | Issue |
|---|---|---|
| ADD/SUB/MUL S T F G, CMPTxx, CMPGxx, every CVT | **5 cycles** (start in t, done in t+5) | every cycle |
| DIVS, DIVF | **29** | busy from t+1 to t+27 |
| DIVT, DIVG | **58** | busy from t+1 to t+56 |

The 21064: 6 cycles for everything but divide, 34 (S/F) and 63 (T/G) for divides (cpu.md 8.6).
Results come out in issue order. A non-divide may be started in any cycle with `busy` low,
including the cycle after another start; a divide makes `busy` high from the next cycle until
the cycle before its done (the non-divide operations started before it have long finished by
then).

## 3. Structure

Five stages, each "flops -> one block of logic -> flops" (cpu-timing.md), with an internal
format of sign, a 13-bit signed exponent E (value 1.f x 2^E) and a 64-bit significand with the
leading one at bit 63 plus a sticky bit:

| Stage | Far path (add, or subtract with exponent difference >= 2) | Close path (subtract with difference 0/1; every float->float and int->float conversion) | Multiply | CVTxQ | Compare |
|---|---|---|---|---|---|
| A | unpack both operands (T/S/G/F with the bias of the format, D for CVTDG), classify (zero, non-finite, reserved, dirty zero), `fa[62:0] >= fb[62:0]` picks the larger magnitude, exponent difference, input exceptions | same; conversions take Fb as "big" and 0 as "small"; CVTQx takes \|Fb\| with E = 63 | E = Ea + Eb | L = E + 12 | the result bit |
| B | align: shift right by the difference, sticky from the shifted-out mask | exact subtract of the 0/1-bit-shifted small operand | four 27x27 products (DSP) | the 53-bit significand shifted left by L into a 64.64 fixed point; guard and sticky | |
| C | 66-bit add/subtract ({carry, 64 bits, sticky}) | leading-zero count (per nibble, then the first non-zero nibble) | 79-bit 3-input sum of the products (bits [105:27]; [26:0] only as sticky) | round (mode, sign, lsb, guard, sticky) and negate in one adder: `(s ? ~int : int) + (s ? !inc : inc)` | |
| D | normalise by 1 bit right/left | shift left by the count | normalise by 1 bit | | |
| E | round to p = 24 (S, F), 53 (T, G), 56 (D); exponent range; pack; flags | | | flags | |

The divider is a separate radix-2 restoring unit (one 56-bit subtract per cycle), loaded at
start from the inputs and its context from the A flops: 26 quotient bits for S/F, 55 for T/G
(one more than p + guard, so a quotient below 1 still has its guard bit), the remainder as sticky.
It feeds the D stage directly (1-bit normalisation), then E.

### 3.1 Rounding and the exponent range (stage E)

Rounding modes: /C chopped, /M minus infinity, normal (nearest even), /D = FPCR.DYN (including
plus infinity, cpu.md 8.1 Impl); VAX normal rounding is to nearest with ties away from zero
("biased", ARM 4.7.5), VAX /C chopped. The increment `W + 2^L` (L = 64 - p) is computed in
parallel with the round-up decision.

Overflow: the rounded result with an unbounded exponent exceeds MAX (E > Emax after the
rounding carry).

**Underflow follows the ARM's definition** (4.7.5): "maps true results < MIN - 1/2 LSB in
magnitude to an underflow" (round to nearest), "< MIN" chopped, and so on per mode. That is
rounding to the destination's grid *including* the denormal steps, and underflow when that is
below MIN. In hardware: a normalised exponent of Emin-1 is rounded once more at p-1 bits (the
denormal grid there); if that carries out the result is MIN (inexact, no underflow), otherwise
it underflows; anything below Emin-1 underflows. A tie exactly at MIN - 1/2 LSB rounds to even
= MIN (IEEE) or away = MIN (VAX). This differs from "tininess before rounding" (QEMU's choice,
section 6) only for results that round up to MIN.

Exponent ranges (E of 1.f x 2^E): T -1022..1023, S -126..127 (register exponent bias 1023),
G -1024..1022, F -128..126 (bias 1025), D -128..126 (8-bit exponent, bias 129).

### 3.2 Exceptions (cpu.md 8.4, HRM 2.6-2.7)

| Condition | Result | fpcr_set | exc_sum (trap) |
|---|---|---|---|
| IEEE operand NaN, Inf or denormal; VAX reserved operand or dirty zero (every op; conversions check only Fb; CVTQx never; **CMPTxx takes +-Inf without a trap**, Alpha ARM 4.7.6.2: ARC 4.58's hardware display compares against +Inf) | 0 | INV | INV, always |
| IEEE 0/0 | 0 | INV | INV |
| x/0, x valid non-zero (IEEE); x/0 with x valid, including 0/0 (VAX) | 0 | DZE | DZE, always |
| overflow | 0 | OVF, INE (not divides) | FOV always; INE too with /SUI |
| underflow | **true zero, all 64 bits** | UNF, INE (not divides) | UNF with /U; INE too with /SUI |
| inexact | the rounded result | INE (not divides) | INE with /SUI |
| DIVS/SUI, DIVT/SUI with no input exception | the rounded result (or the above) | never INE (the 21064 divider does not compute it) | **INE always** |
| CVTTQ/CVTGQ out of -2^63..2^63-1 | the low 64 bits of the rounded integer | IOV, INE | IOV with /V; INE too with /SVI |
| CVTTQ inexact | the rounded integer | INE | INE with /SVI |

- Input exceptions take priority: with INV or DZE nothing else is reported.
- Where the architecture says the destination is UNPREDICTABLE (INV, DZE, OVF) the unit writes 0.
- `exc_sum[0]` (SWC) is the instruction's /S bit when it traps. The SWC rule ("set when every FP
  trap since the last EXC_SUM write had /S", cpu.md 4.2) needs state across traps: the core
  keeps it.
- **FPCR flags are set whatever the trap qualifiers** (ARM 4.7.7: "these exception bits are set
  independent of the trapping mode"; HRM 2.6.1: the FPCR records all detected exceptions). The
  qualifiers only decide EXC_SUM and the trap. This is how cpu.md 8.4's "INE only with /SUI" is
  read: it is the INE *trap* that needs /SUI. VAX operations set the same FPCR bits (the ARM
  leaves it UNPREDICTABLE whether VAX operations set them).
- An exact zero result keeps its IEEE sign (x + -x is +0, or -0 rounding to minus infinity;
  -0 + -0 = -0; products and quotients of zeros have the sign XOR); VAX zeros are always true
  zero. Only underflow forces +0.
- S (and F) operands are taken as they sit in the register; non-canonical ones (low fraction
  bits set, or a T-range exponent) are UNPREDICTABLE in the architecture (ARM 4.7.1) and are
  computed here as T (G) values rounded to S (F). CVTST is the identity plus the INV check.
- CMPTUN is always false (a NaN operand traps INV first). Compares write 0x4000000000000000 for
  true (2.0 IEEE, 0.5 VAX).

## 4. Integration into `ev4_core`

What the core has to do (the unit is written for it; nothing in the core is changed yet):

1. **D stage**: for opcodes 15 and 16 instantiate `ev4_fpu_dec` on `d_ir`. Priority: `fen` ->
   E_FEN; `!legal` -> E_OPCDEC (E_FEN if ICCSR[FPE] = 0); `!iccsr_fpe` -> E_FEN. Otherwise a new
   class (C_FPU): `dc_ua = rd_fa` (register 32+Fa), `dc_ub = 1` (32+Fb), destination 32+Fc,
   `dc_dst_v = 1` (Fc = F31 discards the write but the operation still runs and can trap).
2. **X stage, first version, like the integer multiplier**: hold the instruction in X until
   done. A registered `fpu_go` (as `mul_go`) is `start`; `fa = x_a`, `fb = x_b`, `ir = x_ir`,
   `fpcr_dyn` = the FPCR's DYN (stable: MT_FPCR is serialised). Stall X while
   `x_cls == C_FPU && !fpu_fin`; the result goes on the slow result path into M1, like
   `mul_res`. Latency seen by software: 6 cycles (5 + the registered start), 30 / 59 for divides,
   which is the 21064's 6 / 34 / 63 or better. `kill` on `w_redir` (as `mul_live`), so a
   squashed divide cannot deliver a late `done`. TAG_W can be 1, tie `tag` to 0.
3. **W stage**: write `result` to F(c) (the core already writes on E_ARITH). OR `fpcr_set` into
   `fpcr_f` (same bit order as the core's `fpcr_f`) whether or not it traps. If `trap`: take
   E_ARITH with EXC_ADDR = PC + 4, bit 1 = 1 (as for /V today), OR `exc_sum[6:1]` into
   EXC_SUM[8:3], update SWC from `exc_sum[0]`, set write-mask bit 32 + Fc.
4. Hazards: an FP operate result is forwardable from the M1 result flop like any slow result.
   In the first version nothing else needs checking, because X waits for done.
5. **Pipelined issue as built (2026-11-11, `3fd3a55`, `cpu-perf.md` section 5):** X issues the
   operation in its first cycle and the instruction moves to M1 and M2; results return in order
   into a 3-entry queue and join the instruction at M2 -> W (trap, flags, value), so traps stay
   precise and no scoreboard is needed. Divides hold X. The plan this replaced:
   **pipelined issue** (the unit already allows one start per cycle): let X continue
   after `start`, scoreboard Fc until `done` (with `done_tag` = the destination), add an FP write
   port or merge `done` into W, and make TRAPB/EXCB, MT/MF_FPCR and CALL_PAL wait until nothing
   is in flight. Traps then become imprecise (legal: the trap shadow, cpu.md 8.4), and EXC_SUM's
   write mask must accumulate across the shadow.
6. The sequential reference core `ev4_seq` can use the same unit (start, wait for done).

## 5. Timing (probe `scratch/cpu_fmax/fpu_top`: the unit between input and output flops)

| Date | Fmax / slack at 10 ns | ALMs | DSPs | Notes |
|---|---|---|---|---|
| 2026-11-01 | **slack +1.284 ns (~115 MHz)**, slow 100C model; hold +0.201 | 1711 | 4 (the 27x27 products) | First fit, 2035 registers. Meets 100 MHz with margin: nothing needed splitting |

## 6. Tests

| | |
|---|---|
| `tests/fpu/fpmodel.py` | The golden model, written from the architecture and independent of the RTL's structure: each operation forms the exact value (a dyadic m x 2^x; a quotient to 64+ bits with a sticky bit) and rounds it with the ARM's definitions (section 3.1), then the EV4 rules (section 3.2) |
| `tests/fpu/gen_fpu.py` | Vectors: for each of the 34 base operations and **every legal function code** (292), the directed edge set (zeros, MIN, MAX, 1, all-ones fractions, 2^52/2^63 boundaries, denormals, infinities, NaNs, VAX reserved operands and dirty zeros, the destination format's edges for CVTTS/CVTGF/CVTGD, integer boundaries for CVTQx) crossed with each other, plus `--n` random operand sets biased toward the hard cases (few-bit fractions for exact results and ties, nearby operands for cancellation, multiply/divide exponents aimed at Emin-1..Emax+1, tiny sums, values around the S/F range, around integers and 2^63), random FPCR.DYN; then `--mix` vectors of random operations back to back |
| `tests/fpu/hostcheck.c` | Checks the model's IEEE vectors against the host's IEEE hardware (x86-64 SSE with `fesetround`): results, OVF, INE (not divides), and underflow (the host's denormal result below MIN is exactly the ARM rule) |
| `tests/fpu/qemu_check.py` | A second reading against `qemu-alpha -cpu ev4` (libc-free user programs, the vectors the model says do not trap). Known differences are classified, not counted: QEMU underflows the results that round up to MIN (tininess before rounding), writes signed zeros on underflow, records FPCR[INE] differently, and treats CVTST of non-S values (UNPREDICTABLE) differently. **QEMU's VAX arithmetic is not usable as a reference** (ADDG 1.0 + 1.5 = 2.0, MULG 1.5 x 1.5 = 2.0; F results written with the 8-bit F exponent unmapped; both ends of the G range lost; traps on VAX conversions the model completes), so by default it runs the IEEE operations and CMPGxx only |
| `verilator/tb/tb_fpu.cpp` | `make -C verilator tb_fpu`: the vectors piped into the RTL; result, FPCR bits, EXC_SUM bits, trap and tag compared; non-divides issued back to back with random gaps (`--gap`), `--kill` drops work at random; per-operation counts and the latency seen |
| `verilator/tb/tb_fpu_dec.cpp` | `make -C verilator tb_fpu_dec`: all 4096 function codes of opcodes 15/16 against the model's legality |


## 7. Results

2026-11-01, `make -C verilator tb_fpu` (FPU_N=20000, FPU_MIX=400000): **6,659,500 vectors, 0
mismatches** (result, FPCR bits, EXC_SUM bits, trap, tag), every one of the 292 function codes
with at least ~41k vectors (CVTST) and most with 170k-370k; 27 s of wall time (generation in
3 processes included). Latencies seen: 5 for every non-divide, 29 DIVS/DIVF, 58 DIVT/DIVG.
Also run: `--gap 0` (one start every cycle), `--gap 70`, `--kill 3` (random kills, 34k
operations dropped), other seeds: 0 mismatches. `tb_fpu_dec`: 4096 codes, 0 mismatches.

Model checks: `hostcheck` on 1.02M vectors, the 576k IEEE ones with finite operands compared
with the host: **0 disagreements** (results in all four rounding modes, OVF, INE, UNF including
the round-up-to-MIN edge, which the model hits ~1 in 15 of the vectors aimed at Emin-1).
Boundary hits in 2000 random operand sets per op: MULT ~140 results that round up to MIN and
~1170 underflows at Emin-1, DIVT ~90 / ~1360, CVTTS/CVTGF/CVTGD the destination edges from the
directed set. `qemu_check.py --n 150` (every IEEE base operation and CMPGxx, all their function codes, 57k
non-trapping vectors): **0 unexplained differences**; the classified ones are ~870 underflows
(QEMU's signed zero), ~100 round-up-to-MIN results (QEMU underflows), 348 CVTST of non-S values,
the G-range ends for CMPGxx. VAX F/G arithmetic and conversions rest on the model alone (written
from ARM 4.7.5's biased rounding and the register formats of cpu.md 8.3; AXPbox's
`AlphaCPU_vaxfloat.cpp` was read as a second opinion: round bit added then chopped, the same
biases).
