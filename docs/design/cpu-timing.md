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
