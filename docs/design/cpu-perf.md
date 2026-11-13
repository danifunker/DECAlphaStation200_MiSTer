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

## 7. The board cache (`7002bad`, board build `_20261112f`, 2026-11-12)

`rtl/apecs/bcache.v` on the 21071 model's DRAM port, in front of the SDRAM: 256 KB, direct mapped,
32-byte lines, write-through (the memory always holds the truth, so DMA and the bank aliasing
need no attention). A line read that hits is answered from block RAM, the first quadword two
cycles after the request and then one a cycle (5 cycles a line; the SDRAM takes 25). OSD
Advanced > Board cache On / Off (status 19, latched at reset) wires the port through. `make -C
verilator tb_bcache` (random traffic against a reference memory and a model of the cache's
contents); `tb_sys --no-bcache`, `--board-dram` (the SDRAM's timing in the system simulation) and
`--bcstat N` (hit counts for 64 KB .. 1 MB caches on the same run).

**The size.** `--bcstat` on a run from reset through the DROM and SRM into NetBSD's boot off the
CD, line reads answered by a cache of each size (cumulative):

| cycles | line reads | 64 KB | 128 KB | 256 KB | 1 MB |
|---|---|---|---|---|---|
| 1.0 G | 4.60 M | 66 % | 80 % | **90 %** | |
| 2.5 G | 18.66 M | | | **55 %** | 57 % |
| 3.25 G | 28.99 M | 59 % | 67 % | **70 %** | 72 % |

256 KB is where the curve flattens: 1 MB, which the block RAM could not hold anyway, gains two
points.

**System simulation**, from reset with the board's SDRAM timing, 1.0 G cycles, cache off / on:
the DROM's POST to LED 2E 347,448,917 / 347,473,913 cycles (the instruction counts are equal),
SRM's start from LED 2E to 0B **232.6 M / 196.6 M cycles (-15.5 %)**, instructions in the 1.0 G
cycles 378,201,169 / 397,316,832 (+5 %), the same 44 LED codes in the same order.

**Fit**: 37,247 ALMs (89 %), 46,051 registers, 505 of 553 M10K (91 %), block memory 3,769,582
bits (67 %), **-2.127 ns** at 100 MHz (TNS -1210), the HDMI clock met. The cache's memories are
2.18 Mbit of that.

**Board** (.143, NT 4.0 Workstation, `ubench-alpha -i 3`, the same build with the OSD's Board
cache On and Off; `ub_12f_on.txt`, `ub_12f_off.txt` on the desktop):

| | cache Off | cache On | |
|---|---|---|---|
| Dhrystone 2 (lps) | 131499.1 (index 11.3) | **152985.0 (13.1)** | +16 % |
| Whetstone (MWIPS) | 49.5 (9.0) | **52.4 (9.5)** | +6 % |
| Arithoh | 5955604.1 | 6033213.4 | +1 % |
| Arith short / int / long | 9939.0 / 10906.0 / 10899.4 | 10067.1 / 11047.6 / 11042.0 | +1 % |
| Arith float / double | 21050.1 / 13903.2 | 21309.8 / 14082.2 | +1 % |
| Tower of Hanoi | 1559.8 | 1574.9 | +1 % |
| Partial index | 10.1 | 11.2 | |

Off repeats `_20261111c` (132422.0, 49.8) within 1 %. The cache stays, default On.

### Dual issue: evaluated, not built

The 21064 issues two instructions a cycle only for an aligned pair of one integer operate or
branch with one load, store or FP operate, and not when the second reads the first's result.
An estimate, not a measurement: on code that stays in the 8 KB caches that is 18 to 35 % fewer
cycles at best, and nothing where the time goes to cache misses. The price: a second decoder,
four more register-file read ports, a second set of forwarding comparators and muxes in front
of the ALU, a second retire port and paired precise exceptions; several thousand ALMs with 4.7k
free (89 % used), on a design that misses 100 MHz by 2.1 ns. It does not pay on this board as it
stands; it is worth another look if the serial console display goes behind a feature flag and
the timing closes.

## 8. Change 4: a branch right behind its operand's producer (`cb294b3`, board build `_20261112h`)

Found through XFree86's tga driver on FreeBSD 5.2.1 (`docs/gaps.md`): its copy loops divide by the
bytes per pixel, and libc's division millicode (`__divl`, `__divqu`) looks for the top bit of the
divisor and of the dividend one bit an iteration (`and t2 = b & mask; bne t2, ...; addq; srl;
cmplt; bne`). A conditional branch on the register the instruction before it wrote took the
X->X loop only from a compare, whose result is 0 or 1 (flags from bit 0); after anything else it
waited a cycle, because a zero test after the adder would sit on the loop path.

Now the flags come from a zero test that needs no carry chain, computed in X beside the ALU from
the same operands (`fz`, `fsg`; the producer's kind `x_zk` decoded in D):

- add (ADDL ADDQ, /V, LDA LDAH on Rb and the displacement): A + B is zero exactly when every bit
  of A ^ B equals the bit below it of A | B (bit -1 = 0);
- subtract (SUBL SUBQ, /V): A - B is zero when A == B;
- AND BIC BIS ORNOT XOR EQV: the result itself (an AND / OR / XOR of the operands), and its sign;
- a longword result is zero when bits 31:0 are.

BEQ / BNE need the zero, BLT / BGE the sign (the logical kinds give it, the adds still wait), BLE /
BGT both, BLBC / BLBS only bit 0, which every fast result has. Scaled adds, shifts, byte ops and
CMOV still wait.

Perf bench (BOARD=1), with a new kernel `divq` (`__divqu` as FreeBSD 5.2.1's libc has it, 3 / 1):

| | before | after |
|---|---|---|
| `divq` | 1.358 (1011 cycles a division) | **1.187 (884)** |
| `branchy` | 1.728 | **1.455** |
| `memcpy_in` | 1.675 | **1.510** |
| `calls` | 1.335 | **1.287** |
| `fpmix` | 2.573 | 2.537 |
| the others | | the same |

Tests: `tests/cpu/brz_stress.py` (in `make -C verilator bpstress`): each producer kind, register
and literal forms, right in front of each of the eight integer branches, forward and backward, on
operands that make the 64-bit or the 32-bit result zero, all ones or the sign bit; the retire
trace against alphaemu, checksums under interrupts. Three mutations are caught (the carry term,
the longword case, the sign bit). bp_stress, wb_stress, fp_stress pass. (The T0 suites need the
Alpha cross compiler, not on the Windows machine.)

Board (`_20261112h`, .92, FreeBSD 5.2.1, rpcc from the guest): int 3 / 1 642 -> **546** cycles,
long 1185 -> **998**; the tga driver's copy pair on shifted 100x100 rows 3182 -> **2652**, backwards
2312 -> 2080, the aligned scroll 633 -> 621. Fit: 37,449 ALMs (89 %), 45,989 registers, -2.484 ns
(TNS -844). What is left in those loops is the taken loop branch's bubble (section 9).

## 9. Change 5: the branch target buffer (`0ab78dd`, board build `_20261112i`)

A predicted-taken branch redirected the fetch from F2, so the instruction F1 had fetched behind it
was thrown away: one cycle every loop iteration, the last cost in the division loops of section 8.

The BTB is 256 entries in an M10K (96 bits: valid, PC[42:10] as the tag, the displacement, target
[42:2]) read at npc[9:2] in the same cycle as the I-cache, so F1 has the entry for the instruction
it holds. On a hit F1 fetches the stored target next instead of PC + 4 (`f1_bhit`, `f1_btgt`). F2
then checks the hint against the instruction it decodes: a hit on the same PC (tag plus index = PC
[42:2]) with the same displacement has the same target, so a predicted-taken PC-relative branch
whose displacement matches is confirmed (`bconf`) and nothing more happens. Otherwise F2 steers as
before: a taken prediction the hint did not follow redirects to `p_target`; a hint on an instruction
F2 does not predict taken (a stale entry, a branch now predicted not taken, a jump) redirects back to
PC + 4 (`p_redir`, `p_rtgt`). A wrong hint costs the bubble that every taken branch paid before.
Each F2 taken prediction that was not a confirmed hint writes its entry. X, the return stack and the
prediction bit D carries are unchanged.

Perf bench (BOARD=1, after section 8 -> now):

| | before | after |
|---|---|---|
| `divq` | 1.187 (884 cycles a division) | **1.017 (757)** |
| `branchy` | 1.455 | **1.319** |
| `memcpy_in` | 1.510 | **1.346** |
| `calls` | 1.287 | **1.144** |
| `fpmix` | 2.537 | **2.466** |
| `stackmix` | | the same |

Tests: bp_stress / brz_stress (bpstress, 18 runs), wb_stress, fp_stress pass. To exercise F2's
recovery the same suites ran with the tag compare removed, so every fetch takes whatever entry its
index holds: with confirmation on the displacement alone they fail, as they must (another branch at
the same index with the same displacement goes elsewhere); with confirmation on the full target
they pass, so every wrong hint is undone.

Board (`_20261112i`, .92, FreeBSD 5.2.1, rpcc from the guest; `_20261112h` -> `i`): int 3 / 1
546 -> **477** cycles, long 998 -> **860**, uns 3 / 1 -> 465; the tga driver's copy pair on shifted
100x100 rows 2652 -> **2385**, backwards 2080 -> **1850**, the aligned scroll 621 -> **602**.
FreeBSD boots, logs in and shuts down. Fit: 37,577 ALMs (90 %), 45,953 registers, **-1.535 ns** (TNS
-239; the fetch path did not get worse).

## 10. Change 6: a load's result from M2 (`be72190`)

A load's result reached its consumer only from W: the consumer left D four cycles after the load
entered X, where the 21064 needs three. In M2 everything the load returns is already in registers
(the D-cache word `m2_dq`, the merged stores `mg*`, the hit `m2_hitq` compared in M1), so `m2_lres`
is a short path from flops: a load that hit now forwards it from M2 (`m2_lfwd`, `m2_lfv`). A miss
or an uncached load stalls M2 (and D with it) until its data is in, as before; STx_C still waits
for W (its success flag).

| | before | after |
|---|---|---|
| `loaduse` | 1.511 | **1.264** |
| `memcpy_in` | 1.346 | **1.181** |
| `fpmix` | 2.466 | **2.358** |
| the others | | the same |

Tests: bp_stress / brz_stress, wb_stress, fp_stress pass. Forwarding on a miss too passes them,
and rightly so (M2 moves on only with the bus data in `m2_lres`); forwarding the D-cache word
without the store merges fails wb_stress and fp_stress.

## 11. Change 7: a branch history table, the sign from M1 (`653e10d`, `16fa11c`, `abee413`; board build `_20261113b`)

**The BHT.** 2048 two-bit counters in an M10K, read at npc[12:2] with the I-cache (the 21064 has
2048 history bits in its I-cache), carried with the branch to X. A counter says how often its
conditional branch went against the static rule (backward taken, forward not): 2 or 3 turns F2's
prediction round. Zeros (power-up) are the static rule, so the table needs no clearing. X moves
the counter of each conditional branch it resolves; a wrong prediction is still corrected in X,
so a stale or aliased counter costs time only. New kernel `bias`: the LFSR loop of `branchy` with a
forward branch taken 7 times in 8, another one into a backward branch that is never taken.

**The BTB follows the BHT** (`abee413`): F2 clears a BTB entry whose hint it overrides. Without it a
branch the BHT turned to "not taken" kept its entry, and the fetch went to the old target and back
on every execution: on the board the division got slower (int 3 / 1 477 -> 504 cycles on
`_20261113a`) until this went in.

**The sign from M1** (`16fa11c`): BLT BGE BLE BGT right behind an add, subtract or other loop
producer whose sign the carry-free test of section 8 does not give (`subq a0, 1, a0; bgt a0, loop`)
went to X a cycle late. Now it goes at once and X takes the sign from M1, where the producer's
result is registered by then (`x_asl`, `x_asi = m1_rf[63]`); the two move together, since nothing
holds X but not M1 for a branch. The zero still comes from the carry-free test, or the branch waits
(BEQ / BNE after shifts, scaled adds, byte ops). brz_stress covers it: taking the sign from X
instead fails bp_stress.

| | before | BHT | + BTB clearing |
|---|---|---|---|
| `bias` | 1.687 (312,549 X redirects) | 1.281 (78,173) | **1.213** |
| `branchy` (random) | 1.319 | 1.364 | **1.341** |
| the others | | the same | the same |

**Board** (.92, FreeBSD 5.2.1; `_20261112j` -> `_20261113b`, which also has section 10): `cc -O2 -c`
of a 10 KB C file 14.75 -> **14.0 s** user (-5 %), `gzip -9` of the 6 MB kernel 172 -> **156 s**
user (-9 %); rpcc: int 3 / 1 477 -> **471** cycles, long 860 -> **850**, the tga driver's shifted
copy pair 2385 -> **2273**, backwards 1850 -> **1736**, 500x500 backwards 1538 -> **1428**, the
aligned scroll 604 -> **487**. FreeBSD and xdm as before. Fit: 37,920 ALMs (90 %), -1.713 ns, the HDMI
clock +0.484 ns.

## 12. Next, by the numbers

0. ~~The taken branch's bubble~~: section 9.
1. ~~A branch history table~~: section 11. What is left in `branchy` is the misprediction itself
   (about 3.5 cycles: a branch resolves in X, the fetch restarts at F0).
2. ~~The 1-cycle wait of a branch on the result of the instruction before it~~: sections 8 and
   11 (the zero of shifts, scaled adds and byte ops still waits).
3. ~~Load to use~~: section 10.
4. ~~D-fill: a line read is 25 SDRAM cycles~~: the board cache, section 7.
5. `stackmix` (1.720): stores waiting for the write buffer (12.5 %) and bubbles (27 %, not yet
   split by cause: the bench counts at W, so a bubble made in D or F shows as "other").
6. `fpmix` (2.358): X holds an FP operation's consumer (operand hazard 14.5 %) and the FPU (26 %).
