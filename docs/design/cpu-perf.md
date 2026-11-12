# CPU performance: measurements and changes

The user finds the core slow (`docs/gaps.md`, "CPU speed"). The rule for this work: measure first,
change what the numbers point at, and count a change only when it passes the CPU tests, boots an
OS on the board and shows in `ubench` on NT (board baseline on `_20261109g`: Dhrystone 2 = 103011
lps, Whetstone 30.6 MWIPS).

## 1. The bench (`make -C verilator perf`)

- `verilator/cputest/tb_cpu.cpp` built with `CPU_PERF` and every signal public (`obj_perf`): each
  cycle without a retired instruction is charged to one cause, read from the core's own stall
  signals (cache sweeps, D-fill, D-fill waiting for the write buffer, a store waiting for the write
  buffer, the settle cycles after a D-fill, multiplier, FPU, an operand hazard holding D, a
  serialized instruction, I-fill, and the rest: bubbles behind redirects).
- `BOARD=1` gives the memory the board's latencies: apecs's registered request and acknowledge hops
  and `rtl/mister/sdram_ctl.v` (a request is taken when the SDRAM is free; a line read gives its
  first quadword 11 cycles later and the others 4 apart, busy 25; a write is acknowledged when
  taken and keeps the SDRAM busy 4 cycles a quadword + 7).
- `tests/cpu/perf_bench.py` (`tools/alphaasm.py`, no cross compiler needed) builds six loops in the
  shape of compiled code: `calls` (a non-leaf function with three saves), `memcpy_in` (2 KB, stays
  in the D-cache), `memcpy_out` (256 KB), `branchy` (data-dependent branches), `loaduse` (a linked
  list), `stackmix` (globals read, changed and written back, compares, a small call: about
  Dhrystone's mix).

These are microbenchmarks: they say where cycles go in one kind of code, not how fast NT runs.

## 2. Baseline (`2e1f138`, 2026-11-11)

Cycles per instruction and the share of all cycles by cause:

| | CPI | store waits for write buffer | D-fill (+ its wait for the buffer) | operand hazard | bubbles |
|---|---|---|---|---|---|
| calls | 3.05 | 37.5 % | | 3.1 % | 26.6 % |
| memcpy_in | 2.33 | 14.1 % | | 21.3 % | 21.4 % |
| memcpy_out | 3.71 | 6.7 % | 29.2 % + 6.7 % | 13.5 % | 13.5 % |
| branchy | 2.00 | | | 15.9 % | 34.1 % |
| loaduse | 2.25 | | | 22.0 % | 33.2 % |
| stackmix | 3.59 | 43.1 % | | 7.8 % | 21.2 % |

What they show:

1. **Stores.** The write buffer was one quadword, and a quadword write took 13 cycles from request
   to the next request (the SDRAM's own 11 plus the hops). Code that stores every few instructions
   (function prologues, globals) ran at the speed of the SDRAM: in `stackmix` the writes times 13
   cycles are nearly the whole run time. A deeper buffer alone would not help, the write rate had
   to rise.
2. **Taken branches.** No prediction: every taken branch, call and return redirects from X and
   costs 3 bubbles (3.0-3.4 measured a redirect).
3. **Operand hazards.** A load's result is forwarded only from W (2 bubbles for load then use), and
   a branch on a register written by the instruction before it waits 1 cycle unless that was a
   compare (`subq` / `bne`, the end of every counted loop).

## 3. Change 1: line writes and a 4-entry merging write buffer

- `sdram_ctl`: a write is a 32-byte line with 32 byte enables. It is acknowledged in the cycle it
  is taken (the data is latched; requests are served in order, so a read behind it sees it) and
  costs one row activation for up to four quadwords.
- `apecs`: the CPU port takes a line and its mask (`c_wmask`, `c_wline`) for memory writes; I/O and
  CSR writes stay quadwords; DMA writes and plain quadword writes are placed in their slot of the
  line.
- `ev4_core`: the write buffer is four entries (the 21064's number), each a line with byte enables.
  A memory store joins the entry of its line unless that entry is on the bus, otherwise takes a new
  entry; a store stalls only when all four are taken. I/O writes never merge and leave in program
  order. A D-fill and an uncached load still wait for the buffer to be empty; an I-fill goes ahead
  of the buffer unless the buffer holds the line it wants (code copied, then run).

The same bench after it (the memory model follows the new `sdram_ctl`):

| | CPI before | CPI after | |
|---|---|---|---|
| calls | 3.05 | 1.81 | 1.68x |
| memcpy_in | 2.33 | 2.00 | 1.16x |
| memcpy_out | 3.71 | 3.38 | 1.10x |
| branchy | 2.00 | 2.00 | |
| loaduse | 2.25 | 2.24 | |
| stackmix | 3.59 | 1.80 | 2.00x |

No store waits for the buffer any more in any of the six. What is left is bubbles (33-39 % in
`calls`, `branchy`, `loaduse`, `stackmix`), operand hazards (11-25 %) and, in `memcpy_out`, the
D-fills (37 %: 30 cycles a line).

Tests: `make -C verilator wbstress` (`tests/cpu/wb_stress.py`: 3500 random STQ/STL/LDQ over 64 KB
with the generator's own copy of the memory as the reference; six seeds, each with instant memory,
the board's latencies and two random-delay runs), `tb_sdram` (random line writes with random masks
against a reference), `tb_apecs`, `t3-fpld`, `t3-rwc`, `t3-prefetch`. Not run: the T0 suites (`cputest-pipe`, they
need the alpha cross compiler, which the Windows machine's WSL does not have).

## 4. Change 1 on the board (`_20261111b`, 2026-11-11)

Fit: 37,528 ALMs (90 %), 47,555 registers, -2.091 ns at 100 MHz (as `_20261111a`: 37.5k, -2.062 ns).
SRM and NT 4.0 boot. `ubench` on NT (UnixBench 6.0.1; its index 10 is a SPARCstation 20-61:
Dhrystone 116700 lps, Whetstone 55.0 MWIPS):

| | `_20261109g` (10 passes) | `_20261111b` (3 passes) |
|---|---|---|
| Dhrystone 2 (lps) | 103011.1 (index 8.8) | 109132.9 (9.4) |
| Whetstone (MWIPS) | 30.6 (5.6) | **21.4 (3.9)** |
| Arithoh | 5326311.1 | 5390163.2 |
| Arith short / int / long | 9124.5 / 9809.7 / 10042.6 | 9093.1 / 10119.9 / 10118.2 |
| Arith float / double | 13138.0 / 10232.3 | 13703.3 / 10231.9 |
| Tower of Hanoi | 859.8 | 1569.8 |

- **The 21.4 MWIPS did not repeat.** Whetstone alone on the same build and NT session (`ubench-alpha -i 3
  whetstone-double`, twice): **32.0 and 31.8 MWIPS** (index 5.8), so change 1 gives +4 % and the full
  run's figure belonged to that run (cause not looked for; it was the first run after boot). The
  benches added while looking, `missmix` (a frame and a table on one D-cache index) and `fpmix` (four
  doubles of a line read, added, stored back, a call), are faster with change 1 too (8.35 -> 7.30
  and 4.68 -> 3.54 CPI).
- For scale: SPECint92 / SPECfp92 of the real 4/100 are about 74 (DEC's launch figure) / 95.2
  (published), of the SPARCstation 20-61 88.9 / 102.8: the real machine is about 0.83 / 0.93 of the
  baseline, an index near 8 (integer) and 9 (FP). We are at 9.4 and 5.8.
- ubench on NT: `ubench-alpha.exe` on the Administrator's desktop (`-i passes`, `-v`, test names;
  `-?` lists them); the copy in `dump/ubench/UnixBench/portable` on D: does not start ("Program too
  big to fit in memory").
- Dhrystone gained 6 % where `stackmix` gained 2x: store waits were not what bounds it on the
  board.
- **`fpmix`: 39 % of all cycles are X waiting for the FPU, 5.6 cycles per FP operation.** The FPU
  is a 5-stage pipeline that takes an operation every cycle, but the core holds X until each
  result is back, so independent FP operations run one at a time.

## 5. Change 2: FP operations flow through the FPU (`3fd3a55`, branch `cpu-perf`)

The unit takes an operation a cycle; the core held X until each result was back. Now an FP
operation is issued in its first X cycle and moves on: M1, then M2, where it waits (`m2_fwait`)
for its result. Results come back in issue order into a 3-entry queue (`fq0..fq2`; a result that
arrives while its instruction is already waiting in M2 bypasses it), and the trap, the FPCR flags
and the value join the instruction at M2 -> W, so exceptions stay precise and nothing else in
the core changes its view of an FP instruction. A consumer in D forwards from M2 once the result
is there. Divides still hold X (`fp_hold`): one is in the unit at a time.

`fpmix` (BOARD=1): CPI 3.54 -> **2.79**. Tests: `make -C verilator fpstress`
(`tests/cpu/fp_stress.py`: random ADDT/SUBT/MULT/DIVT, dependent and independent, STT/LDT over
64 KB, CPYS, CMPTLT, FBxx, against the generator's own registers and memory, with random memory
delays and interrupts that kill operations in flight), `tb_fpu`, `t3-fpld`, `wbstress`.

## 6. Change 3: branch prediction in F2 (`6650af2`)

Every taken branch was a redirect from X: 3 bubbles. F2 has the instruction (the I-cache's
longword select), so the prediction is made there and steers the next PC in the cycle the
instruction leaves F2: **1 bubble** (the instruction in F1).

- BR / BSR: taken. Conditional branches (integer and FP): taken when the displacement is
  negative, the 21064's static rule. The target is PC + 4 + disp, an adder on `pc_f2`.
- RET and JSR_COROUTINE (hint bit 15) go to the top of a **4-entry return stack** that BSR, JSR
  and JSR_COROUTINE (hint bit 14) push; predicted only when the stack holds something.
- The instruction carries `d_pred` (and the predicted return address) to X. X redirects only
  when the prediction was wrong: a predicted-taken conditional branch whose condition fails goes
  to PC + 4, a jump whose register is not the predicted address goes to the register, an
  unpredicted taken branch goes to its target as before. Any prediction is therefore safe.
- The return stack is speculative. X keeps the pointer and count as the instructions that really
  ran leave them (`cs_sp`, `cs_n`), and every X or W redirect copies them back; the entries are
  not restored (a wrong-path push can overwrite one: a wrong prediction later, nothing more).

CPI (BOARD=1), FP change -> prediction:

| | before | after | X redirects left |
|---|---|---|---|
| `calls` | 1.795 | **1.335** | |
| `memcpy_in` | 2.00 | **1.675** | |
| `memcpy_out` | 3.38 | 3.25 | |
| `branchy` | 2.00 | **1.73** | the data-dependent ones (100,002) |
| `loaduse` | 2.24 | **1.76** | |
| `stackmix` | 1.80 | 1.72 | |
| `missmix` | 7.30 | 7.06 | |
| `fpmix` | 2.79 | **2.57** | |

Tests: `make -C verilator bpstress` (`tests/cpu/bp_stress.py` + `bp_stress.sh`): random control
flow (nested loops, data-dependent branches of every kind right after an ALU result, a compare or
a load, BSR / JSR / JSR_COROUTINE calls, returns by RET, JMP, JSR_COROUTINE and through another
register, functions that return past two instructions of the caller, recursion deeper than the
stack, jump tables, BSR as a plain jump), about 12 KB of code. The image runs on
`tools/alphaemu` (built with the host's cc: no cross compiler needed) and the core's retire trace
must equal alphaemu's line for line, with instant memory, the board's latencies and random
delays; with random interrupts the checksums must. A mutation (the return address compared
without its low two bits) is caught.

### Changes 2 and 3 on the board (`_20261111c`, `6650af2`, 2026-11-11)

Fit: 37,502 ALMs (89 %), 47,980 registers, **-2.472 ns** at 100 MHz (TNS -1511; `_20261111b` was
-2.091), -0.262 ns on the HDMI clock. The worst 300 paths are `m1_va` / `dtb_tag` -> `mg1_v` /
`mg2_v` (234) and the TGA's `dm_addr` -> the 21071's `d_wdata` (54); one is the prediction's
(`w_v` -> `x_pk`, at -1.74). SRM and NT 4.0 boot; `ubench-alpha -i 3` on NT (`ub_11c.txt` on the
desktop):

| | `_20261111b` | `_20261111c` | |
|---|---|---|---|
| Dhrystone 2 (lps) | 109132.9 (index 9.4) | **132422.0 (11.3)** | +21 % |
| Whetstone (MWIPS) | 32.0 (5.8) | **49.8 (9.1)** | +56 % |
| Arithoh | 5390163.2 | 5993298.6 | +11 % |
| Arith short / int / long | 9093.1 / 10119.9 / 10118.2 | 9996.5 / 10973.5 / 10969.1 | +8..10 % |
| Arith float / double | 13703.3 / 10231.9 | 21180.9 / 13994.6 | +55 % / +37 % |
| Tower of Hanoi | 1569.8 | 1564.2 | 0 |

Against the real 4/100 (an index near 8 integer, 9 FP): integer is past it, FP is level with it.
Tower of Hanoi does not move: its recursion is deeper than the four-entry return stack, and its
branches are forward. (To get NT up after a core load with the 8 KB `WinNT4.nvr`: SRM `set os_type
nt`, OSD Apply and reset, then the second boot selection; the first is the Terminal Server's.)

## 7. Next, by the numbers

1. A branch history table for forward branches and loop exits (`branchy` still redirects on
   every data-dependent branch; 2-bit counters in an M10K read with the I-cache).
2. The 1-cycle wait of a branch on the result of the instruction before it.
3. Load to use: forwarding a load's result one stage earlier.
4. D-fill: a line read is 25 SDRAM cycles; the board cache of `pipeline.md` section 5 is the
   answer to that and costs BRAM.
