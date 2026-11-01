# 21064 (EV4) CPU: what's inside, and how to test it without hardware

## 1. Functional blocks of the 21064
From the 21064/21064A Hardware Reference Manual (`scratch/refs/ec-q9zua-te.pdf`, ch. 2, 4, 5) and the
architecture manual (`scratch/refs/alpha_arm_2ed_1995.pdf`).

| Block | Contents | What to test |
|---|---|---|
| **Ibox** (fetch/issue) | 8 KB direct-mapped I-cache (32-byte lines, ASN-tagged), dual issue, branch prediction (history table + 4-entry JSR return stack), **12-entry ITB** (8 entries for 8 KB pages + 4 for 4 MB pages, plus superpage), interrupt logic (HIRR/HIER/SIRR/ASTRR), 2 performance counters, PALmode, exception dispatch to PAL entry points, SROM load + serial line (SL_XMIT/SL_RCV) | Branch/jump semantics, I-cache coherence (`IMB` / `FLUSH_IC`), ITB miss/ACV vectors, interrupt priority and masking, `HW_REI`, PAL entry offsets. Prediction is performance only |
| **Ebox** (integer) | 64-bit ALU, shifter, byte manipulation (EXT/INS/MSK/ZAP/CMPBGE), multiplier (multi-cycle), CMOVs, `RPCC` cycle counter | Every opcode/function code, literal vs register operand, R31 as source and sink, `/V` overflow traps (`ADDQ/V`, `MULQ/V`…), `UMULH` |
| **Abox** (load/store) | **32-entry DTB**, 8 KB write-through D-cache, **4-entry × 32-byte write buffer**, load silo, LDx_L/STx_C lock logic, `MB`, BIU to Bcache and system bus (BIU_CTL, BIU_STAT, FILL_SYNDROME, BC_TAG) | LDQ_U/STQ_U, sign/zero extension, alignment traps (UNALIGN entry), lock success/failure rules, DTB miss (native vs PAL) and fault vectors, write-buffer ordering around `MB` and I/O space, machine-check reporting |
| **Fbox** (floating point) | IEEE S/T, VAX F/G (D partial), conversions, 4 rounding modes + dynamic (FPCR), **imprecise traps** (`TRAPB`), FPCR | See the EV4 FP rules below. There is **no SQRT** (no FIX extension) and **no BWX, CIX or MVI**; those opcodes must take OPCDEC |
| **PAL / IPRs** | HW_MFPR/HW_MTPR/HW_LD/HW_ST/HW_REI (opcodes 19/1D/1B/1F/1E), Ibox and Abox IPRs, 32 PAL_TEMPs, PAL_BASE | Each IPR's read/write side effects (HRM Table 4-7), PALmode restrictions (HRM 4.6) |

### EV4 floating-point rules a golden model will NOT show (HRM §2.7)
- **Any non-finite IEEE operand (NaN, Inf, denormal) signals INV and traps.** The hardware doesn't compute the
  result: the OS completes it in software. INV, DZE and OVF traps are always enabled.
- Underflow can be disabled; the result is then forced to **+0 (all 64 bits zero)**, even when IEEE says −0.
- Traps are imprecise. Software uses `TRAPB` and `/S` qualifiers.

So FP results must be compared against EV4 rules, not raw IEEE: "trap expected" is a valid expected outcome.

## 2. References available without the real machine

| Reference | What it gives | Limits |
|---|---|---|
| Architecture Reference Manual, 2nd ed. (`scratch/refs/alpha_arm_2ed_1995.pdf`, 860 pp.) | **Pseudocode for every instruction**, FP exception rules, memory model, PALcode architecture | Architectural only, not EV4 timing or IPRs |
| 21064 HRM (`scratch/refs/ec-q9zua-te.pdf` + update `ec-qd2ra-te.pdf`) | EV4 IPRs, PAL entry points, pipeline, SROM format, BIU protocol | — |
| **QEMU `target/alpha`** (user mode: `qemu-alpha -cpu ev4`) | Mature golden model for unprivileged integer + FP, including `-cpu ev4` feature gating | User mode needs a Linux host (Docker on macOS). Full IEEE results, no EV4 FP traps. System mode is 21264/Tsunami |
| **MAME `src/devices/cpu/alpha/`** (`DEC_21064`, BSD-3) | EV4-specific structure: IPR numbering, I-cache fetch with ASN, PAL entry handling, plus the Jensen (DECpc AXP 150) 21064 system | Its own TODO says interrupts, exceptions, translation, FP and caches are incomplete |
| **`tools/alphaemu`** (ours) | Tiny C interpreter that already ran DEC's firmware stubs correctly; easy to instrument for trace comparison | Integer + PAL basics only. Extend it as the in-house reference |
| AXPbox (ES40 emulator) | Whole-system behaviour of real SRM/PAL firmware | 21264 + Tsunami, not EV4/APECS |
| Berkeley SoftFloat 3 / TestFloat | IEEE S/T test vectors and correct roundings | Apply the EV4 trap rules on top |
| GNU toolchain for `alpha-linux-gnu` (Debian packages `binutils-alpha-linux-gnu`, `gcc-alpha-linux-gnu`) | Assembler/compiler for tests (`-mcpu=ev4` avoids BWX/FIX) | Needs Linux/Docker; Homebrew binutils has an Alpha objdump but no assembler |
| Real firmware (`scratch/roms/`) | Integration tests: DROM V1.2, SROM-equivalent init, SRM 6.4-1 (VMS + OSF PALcode), ARC 4.49 | Pass/fail only, little diagnosis |

## 3. Test-suite plan (in build order)

1. **T0: per-instruction self-checking tests** (riscv-tests style). Small assembly programs that run in PALmode from
   reset, compute, compare against expected values derived from ARM pseudocode, and report pass/fail. Report through
   the 8 diagnostic LEDs (flashbus offset 0x14.0000), the SROM serial line (SL_XMIT), or a simulation-only "tohost" address.
   Cover every Ebox opcode/function code, byte ops at all 8 alignments, loads/stores, branches, JSR/RET/COROUTINE.
2. **T1: random instruction streams + lockstep trace comparison.** A generator emits random legal EV4 integer code.
   Run it in Verilator (RTL) and in `alphaemu`/QEMU, logging *(PC, dest register, value, memory writes)* per instruction,
   and diff the logs. This finds most datapath bugs quickly.
3. **T2: floating point.** TestFloat-generated S/T vectors through ADD/SUB/MUL/DIV/CMP/CVT in all rounding modes.
   The expected result is SoftFloat's, unless the EV4 rules say trap or underflow-to-zero. Add VAX F/G conversions and arithmetic.
4. **T3: privileged architecture.** Directed tests for each PAL entry (ARITH, INTERRUPT, ITB/DTB miss, UNALIGN, OPCDEC, FEN,
   CALL_PAL slots), every IPR side effect, HW_LD/HW_ST physical and alternate modes, LDx_L/STx_C rules, ITB/DTB fill and invalidate.
5. **T4: C programs.** Compile the GCC torture tests (`gcc.c-torture/execute`) with `-mcpu=ev4 -static`. Get expected
   output from `qemu-alpha -cpu ev4`, then run them on the core under a minimal bare-metal runtime (and later under NetBSD).
6. **T5: real firmware bring-up.** SROM-replacement → DROM V1.2 (it already exercises PAL, machine checks, the IRQ4 timer and
   the I/O chips) → SRM `>>>` prompt over COM1 → NetBSD/Linux boot → Digital UNIX / NT.

Simulation first, FPGA second: build T0–T3 into a Verilator testbench so failures are reproducible and
trace-diffable before anything goes on the DE10-Nano.
