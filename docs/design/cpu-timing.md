# CPU timing log (target: 100 MHz on the DE10-Nano's 5CSEBA6U23I7)

The user's target (2026-11-01): the 4/100's own 100 MHz, with a pipelined CPU and FPU with
caches. For calibration: the user's PA-7100LC core (HP9K715) closes ~65-70 MHz and the PowerPC
603 (MacPPC7300) 65 MHz on the same device, both 32-bit. 100 MHz with a 64-bit datapath means
every stage has to be designed for about 8 ns of logic plus routing.

Probes live in `scratch/cpu_fmax/` (not in git): a module between input and output registers,
virtual pins, `quartus_sh --flow compile`; the number is the slow 100C model.

## Measurements

| Date | Probe | Fmax / slack at 10 ns | ALMs | Notes |
|---|---|---|---|---|
| 2026-11-01 | `ev4_ialu` (add/sub/scaled, compares, CMPBGE, logic, CMOV, shifts, byte ops, /V), registered in and out | **slack +0.909 ns (~110 MHz)** | 887 | The whole opcode 10/11/12 unit fits one cycle, with nothing in front of it |
| 2026-11-01 | the same with its result forwarded into its own operand flops (3:1 mux: new operand, own result, older result) | **slack -0.770 ns (~93 MHz)** | 1058 | Full single-cycle forwarding for every integer op does not make 100 MHz |
| 2026-11-01 | the forwarding loop with only opcodes 10 and 11 (adds, compares, CMPBGE, logic, CMOV) | **slack +1.338 ns (~115 MHz)** | 517 | **Decision: the 21064's own latencies.** Adds/logic/compares/CMOV 1 cycle with back-to-back forwarding; shifts and byte ops (opcode 12) 2 cycles; loads 3 |

### The pipelined core alone (`rtl/cpu/ev4_core.v`, probe `core_top`: all ports virtual)

| Fit | Slack at 10 ns | ALMs | Critical path, and the fix that followed |
|---|---|---|---|
| 1 | does not fit (4702 LABs) | -- | The byte-enabled D-cache RAM was built from 65k registers: Quartus infers no byte-enabled M10K from a Verilog-2001 loop over lanes. Fix: one 8-bit RAM per lane (`ev4_ram.v`) |
| 2 | -4.764 (~68 MHz) | 4759 | Multiplier: 32x32 product and 128-bit accumulate in one cycle. Fix: pipelined multiplier (operand flops -> DSP -> product flop -> accumulate), 9 cycles |
| 3 | -1.956 (~84 MHz) | 5075 | `x_a` -> branch condition -> next PC -> 256:1 I-cache valid lookup. Fix: the X redirect selects the next PC last |
| 4 | -1.622 (~86 MHz) | 5106 | Still the valid lookup (and the stall paths into it). Fix: valid bits in the tag RAMs, flushes as 256-cycle sweeps |
| 5 | -0.507 (~95 MHz) | 4428 | X result mux after the shifter; the IPR read. Fix: separate fast/slow result flops, IPR read in D, PC+4 and selects pre-decoded in D |
| 6 | -0.469 (~95.5 MHz) | 4300 | D-cache tag compare in M2 -> stall -> every enable; D forwarding select. Fix: the hit compared in M1 and registered |
| 7 | **+0.128 (~101 MHz)** | 4300 | **Meets 100 MHz** (2026-11-01). Thin margin: the whole-system fit will need more |

### The whole machine (MiSTer top, 100 MHz system clock)

Grouped with a `report_timing -npaths 400` script on the system clock (source -> destination register).

| Build | Slack | ALMs | Worst paths, and the fix |
|---|---|---|---|
| 4 (CPU + 21071 + SDRAM) | -0.589 | 12.6k | CPU `x_a -> x_c` (CMOV's old-Rc select in the forwarding loop), `x_ir -> m1_rs`. Fix: CMOV 2 cycles, operand C never loop-forwarded |
| 5 (+ 53C810, SIO) | -1.100 | 19.7k | 8259 priority -> CPU HIRR read; 53C810 SCRIPTS decode and PCI register decode. Fix: irq_h registered in the CPU; SIO outputs registered and the 8259 pipelined; the 53C810 restructured (agents) |
| 6 (+ ITB/DTB) | -2.396 | 22.4k | the ITB lookup in F2. Fix: the lookup in F1, registered into F2 |
| 7 | -1.503 | 21.9k | the TOY's BCD conversion into the SIO read data; DTB select -> D-cache tag/protection. Fix: displayed time registered; per-entry tag compare and protection, ORed |
| 8 (`0c8dfa6`) | -1.244 | ~22k | not yet grouped |

### Closure attempt on the full machine (2026-11-11, branch `cpu-perf`)

The device is 89 % full (37.2k of 41.9k ALMs). Tools: `quartus_sta -t scratch/cpuperf/paths.tcl`
(the 6000 worst paths) and `scratch/cpuperf/grp.py` (grouped by endpoint).

| Build | Worst slack | TNS | What was changed |
|---|---|---|---|
| `_20261111c` (`6650af2`) | -2.472 | -1511 | the start: `m1_va` / `dtb_tag` -> `mg1_v` / `mg2_v`, the TGA's `dm_addr` -> the 21071's `d_wdata` |
| round 1 (`60eea26`) | -1.737 | -659 | the store-forward compare on the D-cache index only; the return-address check in X; the 21071's write data apart from the DMA decode |
| round 2 = `_20261111d` (`10aee62`) | -2.108 | -616 | the machine reset registered; `fq_ne` (the FP queue's "not empty" as a register) ahead of the stall chain; the DTB's page-size select per entry; a register stage on the DMA masters' request (one more cycle per DMA access). 37,189 ALMs, 47,845 registers, HDMI clock +0.144 |

Each round removed the groups it aimed at (`stall_d`, the DTB reset paths, apecs `d_addr` left the
list after round 2) and others took their place. After round 2: `m2_hitq` -2.11 (139 paths from
`m1_va` / `dtb_tag`: 9 logic levels, 4.7 ns of cells and 6.9 ns of routing), `x_b` -1.52, the
I-cache RAM address -1.5..-1.26 (about 1800 paths from `d_ir`, `x_a`, `x_b`), `m1_rs` -1.45, the
SIO's `pt_rdata` -1.35 (533), `SDRAM_A` -1.24, the TOY's `v_year` -1.09, `m2_pa` -1.09, `wb_ld`
-1.02, `ps2_ascii` -0.98, apecs `c_rdata` -0.86 (767), the TGA's `s[][]` -0.84.

**Finding: this is a wall at -1.0..-1.5 ns across unrelated modules, and the paths are routing-
dominated.** Modules nobody touched (the SDRAM controller, `ps2_ascii`) enter and leave the list
from fit to fit, and the worst slack moves about +-0.4 ns between fits of near-identical logic:
the total (TNS) fell by 59 %, the worst path did not. More path-by-path work is inside that
noise. What is left to try, in the order of expected effect:

1. Area. The largest users after the CPU (9.3k ALMs, the FPU 1.6k): the SIO 6.0k (`isa_dma` 1.7k
   with eight channels of registers and `rb[0:63]`; `isa_rtc` 0.9k with the CMOS in registers;
   the Super I/O 0.8k; the 8242 0.7k), the TGA 3.5k, the SCSI targets 2.6k, the 53C810 2.4k, the
   scaler 2.0k, the 21040 1.7k. Moving the DMA registers and the CMOS into RAM frees a few
   percent and gives the fitter room.
2. The DTB / D-cache hit path (`m1_va` -> 32 tag compares -> the PFN OR -> the D-cache tag compare
   -> `m2_hitq`) as two stages, or the hit compared against a registered PFN.
3. Other fitter seeds (the QSF has SEED 1): costs fits, changes nothing in the RTL.

Board check of `_20261111d` (.143): SRM `show device` (dka0, dka400, dva0, ewa0, pka0), NT 4.0
boots and logs on, `ubench-alpha -i 3` as on `_20261111c` (Dhrystone 132311 lps, Whetstone 49.7
MWIPS, Arithoh 5993954, float / double 21203.6 / 13993.9, Hanoi 1565.2). Regression of `10aee62`:
every unit and CPU target passes (`tb_sio`'s two stale TOY checks aside), the system simulation
passes the DROM's POST at the cycle count of the build before.

## Consequences for the pipeline (cpu.md 11)

- **No bypass mux in front of the ALU in the execute stage.** Operands must arrive registered:
  forwarding is resolved one stage earlier (select in the register-read stage, from the
  results of the stages ahead), so E is "operand flops -> ALU -> result flop". A result is
  then usable by the next instruction with one cycle in between only if the forwarding path
  from the ALU output into the operand flops closes; if not, back-to-back dependent integer
  ops pay one bubble.
- Split what does not fit: branch condition + target in E with the redirect registered (one
  extra bubble on a taken branch, recovered by a predictor), address generation in its own
  adder, the D-cache over two stages (index + RAM read, then tag compare + way select +
  load align), the I-cache likewise.
- The FPU is pipelined over several stages (add/sub 4-5, multiply 4-5 on DSP blocks,
  iterative divide).
- Every new unit gets a probe here before it goes into the core.
