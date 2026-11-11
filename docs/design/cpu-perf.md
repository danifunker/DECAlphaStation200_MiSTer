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
against a reference), `tb_apecs`, `t3-fpld`, `t3-rwc`, `t3-prefetch`, and the system simulation
into SRM.

## 4. Next, by the numbers

1. Branch prediction: targets computed in D for `br`/`bsr` and predicted-taken backward branches
   (1 bubble instead of 3), a small return stack for `ret`.
2. The 1-cycle wait of a branch on the result of the instruction before it.
3. Load to use: forwarding a load's result one stage earlier.
4. D-fill: a line read is 25 SDRAM cycles; the board cache of `pipeline.md` section 5 is the
   answer to that and costs BRAM.
