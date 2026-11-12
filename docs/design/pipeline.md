# The 100 MHz pipelined 21064 core

The user's goal (2026-11-01): the AlphaStation 200 **4/100**'s own 100 MHz, with a fast pipelined
CPU and FPU with caches. This document is the microarchitecture; `cpu.md` is the architecture it
implements; `cpu-timing.md` holds every timing measurement behind the choices here.
`rtl/cpu/ev4_seq.v` (the sequential reference core) stays the golden RTL model: the pipelined core
is co-simulated against it instruction by instruction.

## 1. Principles

- **Every stage is "flops -> one block of logic -> flops"** with about 8 ns of logic. Nothing
  selects an operand in front of the ALU except the one forwarding mux that was measured.
- **The 21064's own latencies** (measured, `cpu-timing.md`): integer adds/logic/compares/CMOV 1
  cycle (back-to-back dependent instructions run without a bubble), shifts and byte
  manipulation 2 cycles, loads 3, multiply multi-cycle. Software scheduled for the 21064 is
  therefore also scheduled for this core.
- **Single issue, in order** first. Dual issue (the 21064 pairs an integer/branch op with a
  load/store or FP op) is a later step if the area and timing allow.
- **Precise exceptions** at writeback (cpu.md 5.2 "Impl").

## 2. Stages

| Stage | Work | Out of the stage (flops) |
|---|---|---|
| **F0** next PC | select: W exception/HW_REI redirect > X mispredict/jump redirect > D predicted-taken redirect > PC+4 | PC |
| **F1** fetch | I-cache data RAM (1024 x 64, index PC[12:3]) and tag RAM (256 entries, index PC[12:5]) read; I-stream translation (PALmode physical, superpage, ITB CAM) | RAM outputs, PA tag, ITB result |
| **F2** hit | tag compare, ASN/ASM check, select the instruction's longword; miss -> fetch stall + fill | instruction, PC, fetch fault |
| **D** decode | decode, register file read (M10K; the read address is the instruction straight out of F2's RAM read, so the data is ready in D), hazard check, forwarding select from the X/M1/M2/W result flops, branch target adder (PC+4+disp), static prediction (backward taken, forward not taken), return stack for JSR/RET | operand A/B flops, control word |
| **X** execute | fast ALU (opcodes 10/11, with the X->X forwarding loop), address adder (base + disp), branch condition, shift/byte unit stage 1, multiplier start, IPR read | result, effective address, redirect |
| **M1** memory 1 | D-cache data RAM (1024 x 64) and tag RAM read at the effective address, DTB CAM / superpage on the registered VA, shift/byte stage 2 | RAM outputs, PA, DTB result |
| **M2** memory 2 | tag compare, load align and sign extension, alignment/ACV/miss detection; stores write the D-cache (write-through) and the write buffer | load result, exception |
| **W** writeback | register file write, exception commit and PAL entry, retire trace | |

## 3. Forwarding and interlocks

Results become forwardable from these flops (selected in D, so X gets registered operands):

| Producer | Result in flop after | Consumer in X can be | Bubbles |
|---|---|---|---|
| fast ALU (opcodes 10, 11), LDA/LDAH, BSR/JSR link, RPCC | X | the next instruction (late X->X forward) | 0 |
| shifts, byte ops, CMPBGE stays fast | M1 | 2 later | 1 |
| loads | M2 | 3 later | 2 |
| multiply | its done cycle | interlocked | per unit |
| IPR read (HW_MFPR) | X | next | 0 |

The register file is two M10K copies (one per read port) written in W; a read in D of a register
being written in W the same cycle gets the old value from the RAM, so W is a forwarding source too.

## 4. Branches

- **As built (2026-11-11, `cpu-perf.md` section 6): F2 predicts**, on the instruction the
  I-cache hands out: BR/BSR always taken; conditional branches backward taken, forward not taken
  (the 21064's static rule); RET/JSR_COROUTINE to the top of a 4-entry return stack (the 21064's
  size) that BSR/JSR push. A predicted-taken redirect costs 1 bubble (the instruction in F1).
  (The plan was D, 2 bubbles.)
- X resolves; a misprediction costs 3 bubbles and puts the return stack's pointer back to what
  the instructions that ran left.
- Later: a branch target buffer looked up in F1 for 0-bubble taken branches, and a branch
  history table, measured against real code (SRM boot, NetBSD) before adding them.

## 5. Caches and memory

- **I-cache**: 8 KB direct-mapped, 32-byte lines (the 21064's), ASN/ASM tags, flushed by
  FLUSH_IC/FLUSH_IC_ASM and loaded from the SROM at reset (cpu.md 1.4).
- **D-cache**: 8 KB direct-mapped, 32-byte lines, write-through, read-allocate (the 21064's),
  invalidated by DMA (the 21071's dInvReq), D-cache enable in ABOX_CTL.
- **Write buffer**: 4 entries of 32 bytes with byte masks and merging (the 21064's number); an
  entry leaves as one line write (`mem_wmask`, `mem_wline`), I/O writes as single quadwords in
  program order (`cpu-perf.md` section 3).
- **Board cache** (the 21064's external "Bcache"; the AS200 has 512 KB): a BRAM-backed L2 between
  the BIU and the 21071 model, size set by the BRAM budget (128-256 KB), because SDRAM latency at
  100 MHz is ~10 cycles a miss. Invisible to software except through BIU_CTL diagnostics.
- **BIU**: one transaction at a time in the 21064's priority order (D-fill, I-fill, write buffer),
  the interface of cpu.md 11.3.

## 6. FPU

Pipelined, issued from X; the instruction moves on to M2 and takes its result there from a
3-entry queue (`cpu-perf.md` section 5), forwarded from M2:

| Unit | Latency (cycles) | Notes |
|---|---|---|
| add/sub/compare/convert | 4-5, pipelined | one adder for S/T/F/G/D formats |
| multiply | 4-5, pipelined | 53x53 on four 27x27 DSP blocks |
| divide | ~30 T/G, ~15 S/F, iterative | radix-4 SRT |

Traps: the EV4 rules (cpu.md 8.4): non-finite operands trap, underflow to +0 when disabled.

## 7. Verification

1. Unit benches against the model's vectors (`make -C verilator tb_*`).
2. The T0 suites (later T2/T3) on the pipelined core, and the **lockstep co-simulation**: the
   pipelined core and `ev4_seq` run the same image on a shared memory model, and every retired
   instruction (PC, instruction, register write, store) is compared.
3. Random instruction streams (T1) for hazards and forwarding.
4. A Quartus timing probe for each new block before it joins the core (`cpu-timing.md`).

## 8. Build order

1. Integer pipeline F0..W with the I-cache, the D-cache, the write buffer and a simple BIU;
   static prediction; T0 + lockstep against `ev4_seq`; a whole-core timing fit.
2. PAL/IPR completeness, ITB/DTB, interrupts (T3).
3. The FPU (T2).
4. The board cache and the BIU on the 21071 model; then the system.
5. Prediction improvements, dual issue, measured on real code.
