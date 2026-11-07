# DECchip 21064 (EV4) CPU: design specification

Specification of the 21064 as the core implements it in plain Verilog (`rtl/cpu/`), and the
reference for the bare-metal CPU test suite (`docs/CPU_TEST_PLAN.md`). It states what the
real chip does, with a citation for each fact, and then what our RTL does where the two
differ or where the sources are silent.

## 0. Sources and conventions

| Tag | Document | Local copy |
|---|---|---|
| **HRM** | DECchip 21064/21064A Hardware Reference Manual, EC-Q9ZUA-TE | `scratch/refs/ec-q9zua-te.pdf` (text: `ec-q9zua-te.txt`) |
| **HRMU** | HRM update, EC-QD2RA-TE (replaces Table 4-7) | `scratch/refs/ec-qd2ra-te.pdf` |
| **ARM** | Alpha Architecture Reference Manual, 2nd ed. (1995) | `scratch/refs/alpha_arm_2ed_1995.pdf` |
| **PALG** | PALcode for Alpha Microprocessors System Design Guide, EC-QFGLB-TE | `scratch/refs/ec-qfglb-te.pdf` |
| **EB64+** | 21064/21071 PCI evaluation board user's guide, EC-N0640-72 (App. B: SROM interface) | `scratch/refs/ec-n0640-72.pdf` |
| **TI** | AlphaStation 200/400 Technical Information, EK-PCDSA-TI (ch. 8: SROM/DROM) | `scratch/refs/ek-pcdsa-ti.txt` |
| **21071** | 21071/21072 core logic data sheet, EC-QAEMA-TE | `scratch/refs/ec-qaema-te.pdf` |
| **FW** | Firmware listings (DROM V1.2, SRM 6.4-1/7.0-9, ARC 4.49/4.58, flash stubs) | `scratch/disasm/*.dis.txt` |
| **MAME** | `mame/src/devices/cpu/alpha/alpha.cpp` (DEC_21064), used as a cross-check only | `../mame` |

- Bit ranges are `[hi:lo]`, inclusive. Hex is `0x...`; HRM opcodes are given as `oo.fff` hex.
- **(unverified)** marks anything not stated by the sources, or where the sources disagree. Each
  one has an entry in section 12 and a stated choice for our RTL.
- "Our RTL" / **Impl:** is a decision for this core, not a property of the chip.
- K/E/S/U = kernel/executive/supervisor/user = mode 0/1/2/3 (PS.CM encoding, ARM).
- This is the 21064 (CHIP_ID 7), not the 21064A: 8 KB caches, 1-bit branch history, no cache parity, and
  DIV/I behaves as described in section 8.4. 21064A-only bits are listed but are RAZ/ignored in our core.

---

## 1. Architectural state and reset

### 1.1 State

| State | Size | Notes |
|---|---|---|
| R0-R31 | 32 x 64 | R31 reads 0, writes discarded (ARM 3.1.1) |
| F0-F31 | 32 x 64 | F31 reads +0.0, writes discarded |
| PC | 64 | Native mode: virtual PC [63:2] (43-bit VA, section 6). PALmode: physical PC [33:2] (HRM 4.3) |
| PALmode | 1 | Set by reset, any exception or CALL_PAL; written by HW_REI from EXC_ADDR[0] (HRM 4.8.3) |
| FPCR | 64 | Fields in section 8.2 |
| intr_flag | 1 | RS sets it, RC clears it (ARM 4.11); VMS PALcode clears it with `rc` on REI and at reset (FW) |
| Lock flag / lock address | -- | **Not in the CPU.** HRM 5.5: "required by the architecture but not implemented on the 21064". On the AS200 they are in the 21071-CA (21071 3.1.5). See section 9.1 |
| IPRs, PAL_TEMP[0..31] | -- | Section 4 |
| ITB 8+4, DTB 32, I-cache 8 KB, D-cache 8 KB, write buffer 4 x 32 B | -- | Sections 6 and 9 |

### 1.2 What the chip does at reset

From HRM 4.4, 4.5, 5.6 (Table 5-20), 6.4.1 and 6.5.7:

1. While `reset_l` is low, `irq_h[5:0]` carry configuration (HRM Table 6-5): `irq_h[5]` = 128-bit
   bus, `irq_h[4:3]` = sysClkOut1->sysClkOut2 delay, `irq_h[2:0]` = system clock divisor. **Impl:** none
   of this exists; the `irq` inputs are only interrupts.
2. Internal reset lasts at least 20 CPU cycles after `reset_l` rises. Then, if `icMode_h[1:0]` = 00
   (HRM Table 6-19), the chip shifts the **serial ROM into the I-cache**: 256 blocks x 293 bits
   (bht 8, lw7, lw5, lw3, lw1, v, asm, asn 6, tag 21, lw6, lw4, lw2, lw0: HRM Fig. 6-17 / Table 6-21;
   TI 8 lists the reverse order, LSB first). One bit every 126 CPU cycles. The valid and ASM bits of every
   block must be set and the tag must be 0 (HRM 6.5.7), so after the load the I-cache holds PA
   `0x0000-0x1FFF`. With `icMode_h` = 01 the load is skipped, the valid bits stay clear and the first
   fetch misses to PA 0 (HRM 6.4.1).
3. The chip starts in **PALmode** at **PC = PAL_BASE + 0x0000 = 0** (PAL_BASE is cleared at reset,
   HRM 4.5 and 5.2.13; RESET offset 0000, Table 4-1). EB64+ B.1.1: "After loading the Icache the CPU
   begins execution at location zero ... in the CPU PAL mode environment."
4. After the last SROM bit, `sRomOE_l` deasserts and `sRomClk_h` follows SL_XMIT[TMT], which reset does
   not initialise (HRM 6.4.1). From then on `sRomD_h`/`sRomClk_h` are the SL_RCV/SL_XMIT bit-banged
   serial line (HRM 6.5.7.1).

IPR state right after reset (HRM Table 5-20; anything not listed is UNDEFINED):

| IPR | Reset value |
|---|---|
| ICCSR | cleared except ASN, PC0, PC1: FPE=0 (FP disabled), DI=0 (single issue), PIPE=0, JSE=BPE=BHE=0, HWE=0, MAP=0, PCMUX0=0 (issues/2), PCMUX1=0 (D-cache misses), performance counters zeroed |
| PAL_BASE | 0 |
| ABOX_CTL | 0 (write buffer on, MCHK off, CRD off, stream buffer off, both superpages off, big-endian off, D-cache off, force-hit off, STC_NORESULT off, NCACHE_NDISTURB off) |
| BIU_CTL | 0 (Bcache off, parity mode, BC_PA_DIS=0...). BC_RD_SPD, BC_WR_SPD, DELAY_WDATA, BC_WE_CTL, BC_SIZE "undetermined" |
| MM_CSR, VA | UNDEFINED, **unlocked** |
| BIU_STAT, BIU_ADDR, FILL_ADDR, FILL_SYNDROME, BC_TAG, DC_STAT | UNDEFINED, "potentially locked"; BIU_STAT is not cleared by reset (HRM 5.3.18) |
| CC | UNDEFINED, counter disabled |
| PS, EXC_ADDR, EXC_SUM, SIRR, ASTRR, HIER, SIER, ASTER, SL_XMIT, TB_CTL, ALT_MODE, PAL_TEMPs, ITB, DTB | UNDEFINED; PALcode must ITBZAP and DTBZAP before filling, clear EXC_SUM with 64 reads, set PS, HIER etc. |

**Impl:** every UNDEFINED IPR resets to 0 (TBs invalid, NLU pointers 0, locks clear, BIU_STAT 0,
PS = kernel, EXC_SUM mask 0). Software must not depend on that; the test suite initialises everything
as real PALcode does.

### 1.3 What the AS200 SROM leaves for the DROM

The AS200 SROM is not dumped (`docs/CORE_SPEC.md`). From TI ch. 8, EB64+ App. B and the DROM listing:

- The SROM sets BIU_CTL and ABOX_CTL (LED FF), sizes/configures memory and the 21071-CA, tests the low
  8 MB, initialises the core logic (F6), copies the DROM to memory, checks it (F1) and enters it with
  PAL_BASE and EXC_ADDR set (F0) (TI Table 8-1).
- Because ABOX_CTL, BIU_CTL are write-only (and ICCSR is awkward to read back), the firmware keeps
  shadows in PAL_TEMPs. The DROM reads **PAL_TEMP14 = ABOX_CTL**, **PAL_TEMP18 = BIU_CTL** and
  **PAL_TEMP2 = ICCSR**, and prints them as `abox_ctl`, `biu_ctl`, `iccsr` (FW `drom_v1.2` 0x0dc,
  0x20c, 0x1a6c-0x1ab4). It updates them with dual-select writes (`hw_mtpr/pa t1,0xe`).
- The DROM's first instructions: `br` at image offset 0x40, MCHK handler at 0x60 (reads EXC_ADDR,
  DC_STAT, BIU_ADDR, FILL_SYNDROME, FILL_ADDR, prints "MCHK"). So the DROM runs with **PAL_BASE = address
  of image offset 0x40** (the 0x40-byte ROM header precedes it). The load address the SROM uses is
  not known (open question Q1); the DROM is position-independent.
- Low-memory parameter block, read with `hw_ldq/p` and handed to the console as registers
  (FW `drom_v1.2` 0x34c4-0x3538, matching EB64+ Table B-1):

  | PA | Register at console entry | Meaning (EB64+ B.1.2) |
  |---|---|---|
  | 0x00 | a0 (r16) | -- |
  | 0x08 | a1 (r17) | memory size in bytes, contiguous from PA 0 |
  | 0x10 | a2 (r18) | picoseconds per RPCC count (the DROM writes 6000/5000/4291/3759) |
  | 0x18 | a3 (r19) | signature [31:16] (0xDECA = V1, 0xDECB = V2) and system revision [15:0] |
  | 0x20 | a4 (r20) | active processor mask (1) |
  | 0x28 | a5 (r21) | system context; sp = a5 << 10 |
  | 0x30-0x48 | t8-t11 | -- ; **0x38 = memory size in MB**: the DROM's zeroing loop and memory test use it as top of memory (`docs/design/srom.md`) |
  | 0x50 | -- | the DROM writes "V1.2" |
  | 0x58, 0x60 | t12, at | -- |
  | 0x68 | -- | CPU MHz (166/200/233/266; used for SROM-port bit timing) |
  | 0x70 | -- | **speed code**, not a flag: DROM V1.2 calibrates only when it is 2, V1.7 when it is 2 or 8; V1.7 stores its own code there (9 = 100 MHz). Our SROM writes 9, so neither DROM recalibrates (`docs/design/srom.md`, corrected 2026-11-01) |
  | 0x110 | -- | measured RPCC count |

  Also at console entry: v0 = 0, t0 = PAL_TEMP14 (ABOX_CTL), t1 = PAL_TEMP18 (BIU_CTL).

### 1.4 How our core starts (no SROM image)

The core runs **replacement init code** (`docs/CORE_SPEC.md`, open item 1), written by us in Alpha
assembly. Options:

| Option | How | For | Against |
|---|---|---|---|
| **A. I-cache preload (recommended)** | The CPU has an `icmode` input. With `icmode=0`, after reset the I-fill machine copies 8 KB from a `srom_*` read port (a BRAM ROM in the system, 64 bits per beat) into the I-cache, tag 0, V=1, ASM=1, then starts at PC 0 in PALmode. With `icmode=1` it starts with an empty I-cache and the first fetch reads PA 0 from the system | Same behaviour as the chip: code at PA 0-0x1FFF runs from the I-cache while the D-stream sees DRAM at PA 0 (the parameter block lives there), and stays until the first FLUSH_IC (the DROM flushes at its entry). No address-map overlay. Load time ~1k cycles | 8 KB of BRAM for the ROM (7-8 M10K); I-cache needs a preload path (it reuses the fill path) |
| B. I-stream overlay | System returns boot-ROM data for I-stream reads of PA 0-0x1FFF until a latch clears (e.g. on the first FLUSH_IC, or a CSR write) | No CPU change | System must tell I-stream from D-stream reads (it can: the request carries the stream type); behaviour diverges from the chip if code refills those lines |
| C. HLE | Skip the init code; the system preloads DRAM and enters the DROM with fixed registers | Fastest bring-up | Needs a way to set PAL_TEMPs/IPRs from outside the CPU; hides bugs the real flow exercises |

**Recommendation: option A**, with the replacement code assembled into a ROM image in the core (it is
ours, so it can live in git). It must do what the SROM does (section 1.3): set BIU_CTL (Bcache off),
ABOX_CTL, ICCSR and their PAL_TEMP shadows, configure the 21071-CA banks, zero/test low memory, write the
parameter block (including PA 0x70 = 2, 0x10 = our real cycle time, 0x68 = MHz, so the DROM skips the
speed table that only knows 166-266 MHz, see Q11), copy the DROM from the flashbus to memory and enter it
with HW_REI. `icmode=1` plus a test image at PA 0 is the mode for T0 CPU tests in Verilator.

---

## 2. Instruction set

### 2.1 Formats (ARM 3.3)

| Format | [31:26] | [25:21] | [20:16] | [15:0] |
|---|---|---|---|---|
| PALcode | opcode 0x00 | function [25:0] | | |
| Branch | opcode | Ra | disp [20:0], target = PC+4 + 4*SEXT(disp) | |
| Memory | opcode | Ra | Rb | disp [15:0] (LDAH: disp*65536) |
| Memory/function (op 0x18) | 0x18 | Ra | Rb | function [15:0] |
| Memory/jump (op 0x1A) | 0x1A | Ra | Rb | [15:14] type, [13:0] hint; target = Rb & ~3, Ra = PC+4 |
| Operate | opcode | Ra | Rb or [20:13] literal | [12] = 1 literal, [11:5] function, [4:0] Rc; [15:13] SBZ when [12]=0 |
| FP operate | opcode | Fa | Fb | [15:5] function, [4:0] Fc |
| HW_MxPR, HW_LD/ST, HW_REI | section 3 | | | |

### 2.2 Opcode map (HRM Table 2-4, Table 3-6, Table 3-7)

| Op | Group | EV4 | | Op | Group | EV4 |
|---|---|---|---|---|---|---|
| 00 | CALL_PAL | yes (section 5.4) | | 20-23 | LDF LDG LDS LDT | yes (FEN if FPE=0) |
| 01-07 | reserved | OPCDEC | | 24-27 | STF STG STS STT | yes (FEN if FPE=0) |
| 08 | LDA | yes | | 28, 29 | LDL, LDQ | yes |
| 09 | LDAH | yes | | 2A, 2B | LDL_L, LDQ_L | yes |
| 0A | (BWX LDBU) | **OPCDEC** | | 2C, 2D | STL, STQ | yes |
| 0B | LDQ_U | yes | | 2E, 2F | STL_C, STQ_C | yes |
| 0C, 0D, 0E | (BWX LDWU, STW, STB) | **OPCDEC** | | 30 | BR | yes |
| 0F | STQ_U | yes | | 31-33, 35-37 | FBEQ FBLT FBLE, FBNE FBGE FBGT | yes (FEN if FPE=0) |
| 10 | INTA | yes | | 34 | BSR | yes |
| 11 | INTL | yes | | 38-3F | BLBC BEQ BLT BLE BLBS BNE BGE BGT | yes |
| 12 | INTS | yes | | 19 | HW_MFPR | PALmode / HWE |
| 13 | INTM | yes | | 1B | HW_LD | PALmode / HWE |
| 14 | (FIX ITOF/SQRT) | **OPCDEC** | | 1D | HW_MTPR | PALmode / HWE |
| 15 | FLTV (VAX) | yes | | 1E | HW_REI | PALmode / HWE |
| 16 | FLTI (IEEE) | yes | | 1F | HW_ST | PALmode / HWE |
| 17 | FLTL | yes | | 1C | (CIX/MVI/FTOI) | **OPCDEC** |
| 18 | MISC | yes | | 1A | JMP/JSR/RET/JSR_COROUTINE | yes |

The ARM (3.3.3, 3.3.4) says unused function codes of opcodes 01-07, 0A, 0C-0E, 14, 19, 1B-1F trap as
illegal instructions; unused function codes of the other opcodes give UNPREDICTABLE results.
**Impl:** every function code not listed below takes OPCDEC (deterministic, a superset of the chip).

### 2.3 Integer operate (HRM Table 3-2)

| Opcode 10 (INTA) | | Opcode 11 (INTL) | | Opcode 12 (INTS) | | Opcode 13 (INTM) | |
|---|---|---|---|---|---|---|---|
| ADDL | 00 | AND | 00 | MSKBL | 02 | MULL | 00 |
| S4ADDL | 02 | BIC | 08 | EXTBL | 06 | MULQ | 20 |
| SUBL | 09 | CMOVLBS | 14 | INSBL | 0B | UMULH | 30 |
| S4SUBL | 0B | CMOVLBC | 16 | MSKWL | 12 | MULL/V | 40 |
| CMPBGE | 0F | BIS | 20 | EXTWL | 16 | MULQ/V | 60 |
| S8ADDL | 12 | CMOVEQ | 24 | INSWL | 1B | | |
| S8SUBL | 1B | CMOVNE | 26 | MSKLL | 22 | | |
| CMPULT | 1D | ORNOT | 28 | EXTLL | 26 | | |
| ADDQ | 20 | XOR | 40 | INSLL | 2B | | |
| S4ADDQ | 22 | CMOVLT | 44 | ZAP | 30 | | |
| SUBQ | 29 | CMOVGE | 46 | ZAPNOT | 31 | | |
| S4SUBQ | 2B | EQV | 48 | MSKQL | 32 | | |
| CMPEQ | 2D | (AMASK) | 61 | SRL | 34 | | |
| S8ADDQ | 32 | CMOVLE | 64 | EXTQL | 36 | | |
| S8SUBQ | 3B | CMOVGT | 66 | SLL | 39 | | |
| CMPULE | 3D | (IMPLVER) | 6C | INSQL | 3B | | |
| ADDL/V | 40 | | | SRA | 3C | | |
| SUBL/V | 49 | | | MSKWH | 52 | | |
| CMPLT | 4D | | | INSWH | 57 | | |
| ADDQ/V | 60 | | | EXTWH | 5A | | |
| SUBQ/V | 69 | | | MSKLH | 62 | | |
| CMPLE | 6D | | | INSLH | 67 | | |
| | | | | EXTLH | 6A | | |
| | | | | MSKQH | 72 | | |
| | | | | INSQH | 77 | | |
| | | | | EXTQH | 7A | | |

Semantics are the ARM's (ch. 4.2-4.6). Points for the RTL:
- Longword results (ADDL, SUBL, S4/S8, MULL) are sign-extended from bit 31.
- `/V` variants: on overflow the result is still written (low 64 or 32 bits, HRM 2.7 "Integer overflow")
  and an arithmetic trap is taken with EXC_SUM[IOV] and the write-mask bit for Rc (section 5.3).
- UMULH = high 64 bits of the unsigned 128-bit product. MULQ/V overflows when the signed 128-bit
  product does not fit 64 bits; MULL/V when the signed product of the low longwords does not fit 32.
- The multiplier on the chip retires 4 bits per cycle (HRM 2.4); MULL/V trap shadow 22 cycles, MULQ/V 24
  (HRM 4.6 rule 11). Timing is not architectural.

**AMASK/IMPLVER.** Neither our ARM (2nd ed., 1995) nor the HRM defines them: they were added to the
architecture later. Linux uses both on every CPU (`arch/alpha/include/asm/elf.h`: `ELF_HWCAP (~amask(-1))`,
`ELF_PLATFORM` calls `implver()`), and GNU as assembles them for `-m21064`, so they must not trap on a
real 21064 (unverified how the 21064's decoder produces the result). **Impl:** AMASK: Rc <- Rb (literal
or register) AND NOT 0 (no extensions: BWX, FIX, CIX, MVI all absent); IMPLVER: Rc <- 0 (EV4).

### 2.4 Memory, branch, jump and miscellaneous

- Loads/stores: LDL/STL need 4-byte, LDQ/STQ 8-byte alignment; misaligned -> UNALIGN (section 5.2).
  LDQ_U/STQ_U clear VA[2:0]. LDA/LDAH never access memory. There are no byte or word accesses on the bus:
  write masks are per longword (HRM Table 6-4, `cWMask_h[7:0]`).
- A load to R31/F31 still accesses memory and can fault (ARM 2nd ed. has no "prefetch" form). **Impl:**
  do the access, discard the data.
- Jumps (op 1A, `disp[15:14]`, HRM Table 2-1): 0 JMP, 1 JSR, 2 RET, 3 JSR_COROUTINE. All: target =
  Rb AND NOT 3, Ra <- PC+4 (computed before Rb is read, so `jsr r1,(r1)` works). The hint and the 4-entry
  return stack are performance only.
- BSR/BR: Ra <- PC+4. Conditional branches compare Ra (integer) or Fa (FP, section 8.6).

Opcode 18 (memory function code in [15:0], HRM Table 3-2):

| Mnemonic | Function | Our RTL |
|---|---|---|
| TRAPB | 0x0000 | Wait until all earlier instructions can no longer trap (a no-op if arithmetic traps are precise, section 8.4) |
| EXCB | 0x0400 | As TRAPB |
| MB | 0x4000 | Drain the write buffer, then a BARRIER bus transaction (HRM 6.4.11) |
| WMB | 0x4400 | Listed in HRM Table 3-2 as "18.44" (sic). **Impl:** same as MB |
| FETCH | 0x8000 | Hint. **Impl:** no-op, no exceptions (the ARM allows this; HRM 4.7.1.2 shows PALcode must otherwise skip FETCH faults) |
| FETCH_M | 0xA000 | As FETCH |
| RPCC | 0xC000 | Ra <- CC (64 bits: OFFSET[63:32], COUNTER[31:0], section 4.3) |
| RC | 0xE000 | Ra <- intr_flag; intr_flag <- 0 |
| RS | 0xF000 | Ra <- intr_flag; intr_flag <- 1 |

Other function codes: OPCDEC (Impl).

Required CALL_PAL functions (HRM Table 3-5): HALT 0x0000 (priv), DRAINA 0x0002 (priv), IMB 0x0086
(unpriv). They are ordinary CALL_PAL dispatches; the hardware gives them no special meaning.

### 2.5 Extensions that take OPCDEC on our core

| Extension | Instructions | Opcodes |
|---|---|---|
| BWX | LDBU, LDWU, STB, STW | 0A, 0C, 0D, 0E |
| BWX | SEXTB, SEXTW | 1C.00, 1C.01 |
| FIX | ITOFS/ITOFF/ITOFT, SQRTF/G/S/T | 14.xxx |
| FIX | FTOIS, FTOIT | 1C.78, 1C.70 |
| CIX | CTPOP, CTLZ, CTTZ | 1C.30, 1C.32, 1C.33 |
| MVI | PERR, UNPKBW, UNPKBL, PKWB, PKLB, MINxxx, MAXxxx | 1C.xx |

All live on opcodes the HRM marks reserved (14, 1C, 0A, 0C-0E), so they take OPCDEC.

**Assembler notes** (checked with binutils 2.46): `alpha-linux-gnu-as -m21064` rejects FIX/CIX/MVI
mnemonics, but `ldbu`, `stb`, `sextb`... are accepted and expanded into EV4 macros (LDQ_U/EXTBL,
LDQ_U/INSBL/MSKBL/STQ_U, SLL/SRA). The `stb` macro silently uses `$at` **and $23, $24** (t9, t10); with
`.set noat` the macros are refused. Test code must avoid these mnemonics or allow for the clobbers.
`-mev4` behaves the same (CLAUDE.md's BWX warning applies to compiler-generated code, so test images are
still scanned with objdump for opcodes 0A/0C/0D/0E/14/1C).

---

## 3. PAL instructions (HRM 4.8, Tables 4-5 to 4-9)

All five are legal in PALmode, and in kernel mode when ICCSR[HWE] = 1 (HRM 4.8, Table 5-1). Otherwise
they take OPCDEC. Even with HWE, the ITB registers (TB_TAG, ITB_PTE, ITB_PTE_TEMP, ITBZAP, ITBASM, ITBIS)
are only accessed in PALmode; outside it the access is ignored (HRM 4.6 rule 10, 5.2.1, 5.2.2, 5.2.8-10).

### 3.1 HW_MFPR (0x19) and HW_MTPR (0x1D)

| Bits | Field |
|---|---|
| [31:26] | 0x19 HW_MFPR / 0x1D HW_MTPR |
| [25:21] | Ra: destination (MFPR) or source (MTPR) |
| [20:16] | Rb: **must equal Ra** (HRM Table 4-6) |
| [15:8] | ignored |
| [7] | PAL: select PAL_TEMP[index] |
| [6] | ABX: select the Abox IPR at index |
| [5] | IBX: select the Ibox IPR at index |
| [4:0] | index |

- PAL = ABX = IBX = 0 is a NOP (HRM 4.8.1). PALcode uses `hw_mtpr $31,0` / `hw_mfpr $31,0` as padding.
- **An MTPR with several select bits writes all selected registers with the same index in parallel**
  (HRM 4.8.1). The firmware depends on this (section 10): ICCSR+PAL_TEMP2 (`/pi`,2), PS+PAL_TEMP9
  (`/pi`,9), ABOX_CTL+PAL_TEMP14 (`/pa`,0xe), ALT_MODE+PAL_TEMP15 (`/pa`,0xf), BIU_CTL+PAL_TEMP18
  (`/pa`,0x12), ITBZAP+DTBZAP (`/ai`,6), ITBASM+DTBASM (`/ai`,7).
- An MFPR with several select bits: not specified, and no firmware code does it (the `hw_mfpr/ai` hits in
  the listings are ASCII text). **Impl:** priority PAL_TEMP > Abox > Ibox (what MAME does).
- Reading an unimplemented index returns 0; writing one does nothing. The SRM and ARC machine-check
  paths read **Abox index 11** (`hw_mfpr/a rX,0xb`) next to BIU_ADDR/FILL_ADDR/BC_TAG (FW srm 0x8fec,
  0xc42c; arc 0x80704060). It is not in Table 4-7 (Q6). **Impl:** reads 0, no side effect.
- The destination of `HW_MFPR Rx,ITB_PTE` / `DTB_PTE` is UNPREDICTABLE (HRM 4.6 rule 16). **Impl:** 0.
- MTPR to DTBIS takes its operand from Rb (= Ra) (HRM 5.3.8).

GNU as (`-m21064`) accepts two forms. The bare form takes the raw low byte (0-255) of the instruction,
so the number selects the box: `hw_mtpr $1,0x20` = `hw_mtpr/i $1,0` (TB_TAG), `0x40` = Abox index 0
(TB_CTL), `0x80` = PAL_TEMP0, `0xa0` = PAL_TEMP0+TB_TAG. The qualified form takes the index (0-31) and
ORs in the qualifiers `/p` `/a` `/i` in any combination: `hw_mtpr/pa $1,0xe` = 0x742100ce. Ra and Rb are
both filled from the one register operand. objdump decodes these only with `-m alpha:ev4` on a raw
binary (as `tools/disasm_all.py` does); on an ELF it prints `pal1d`.

### 3.2 HW_LD (0x1B) and HW_ST (0x1F)

| Bits | Field |
|---|---|
| [31:26] | 0x1B HW_LD / 0x1F HW_ST |
| [25:21] | Ra (data) |
| [20:16] | Rb (base) |
| [15] | PHY: 1 = the effective address is physical (no translation, no access checks) |
| [14] | ALT: virtual: use ALT_MODE[4:3] instead of PS.CM for access checks. PHY+ALT: load-locked (HW_LD) / store-conditional (HW_ST), physical |
| [13] | RWC: virtual HW_LD only: check read **and** write access |
| [12] | QW: 1 = quadword, 0 = longword |
| [11:0] | DISP: signed byte displacement |

Effective address = (SEXT(DISP) + Rb) AND NOT (QW ? 7 : 3) (HRM 4.8.2): **the low bits are cleared, so
HW_LD/HW_ST never take UNALIGN**. HW_ST/C (PHY+ALT) writes 1/0 to Ra like
STx_C. **Impl:** HW_LDL sign-extends like LDL (HRM: Ra/Rb "interpreted the same as non-PALmode loads"). Virtual HW_LD/HW_ST go through the DTB and superpages like LDx/STx (section 6.4), and a miss in
PALmode goes to DTB_MISS PAL (0x09E0).

GNU as: `hw_ldl`, `hw_ldq`, `hw_stl`, `hw_stq` (also `hw_ld/q`), qualifiers `/p` `/a` `/r` in that order
(`hw_ldq/pa`, `hw_ldq/pr`, `hw_ldq/ar`; `/apr` is refused). `hw_ldq/p $1,8($2)` = 0x6c229008,
`hw_stq/p $1,0($2)` = 0x7c229000, `hw_stl/pa` = 0x7c22c000. DISP range -0x800..0x7ff.

### 3.3 HW_REI (0x1E)

Encoding `0x7BFF8000` (Ra = Rb = 31, bits [15:14] = 10: "pop", HRM Fig. 4-3 and 4.8.3).

    PC      <- EXC_ADDR AND NOT 3
    PALmode <- EXC_ADDR[0]

With EXC_ADDR[0] = 0 the new PC is virtual and goes through the ITB (HRM 4.6 rule 1). HW_REI does not
change PS, interrupt enables, intr_flag or the lock flag (unverified for intr_flag; VMS/ARC PALcode clear it
with RC themselves). MAME's HW_REI clears its lock watch; the chip has no lock flag (section 9.1).

### 3.4 PALmode timing restrictions (HRM 4.6)

The chip needs software delays between dependent IPR operations (e.g. 3 cycles after most MTPRs, Table 4-3
cycles before HW_REI, 8-9 after ICCSR.ASN/FLUSH_IC, Table 4-4). **Impl:** all IPR reads and writes
are fully interlocked and take effect in program order, which satisfies every restriction. Two chip
behaviours that interlocking removes, checked against the firmware:
- "Swap": an MFPR of a PAL_TEMP in the cycle right after an MTPR of the same PAL_TEMP returns the old value
  (HRM 4.6 rule 1). The only MTPR/MFPR pairs on the same PAL_TEMP in the SRM/ARC/DROM PALcode are
  padding reads after `wrfen` whose value is discarded (srm 0xa324, 0x16ae4). Not reproduced.
- An ITB MxPR in the cycle after HW_REI is ignored (rule 9). Not reproduced.

---

## 4. Internal processor registers

### 4.1 Access table (HRM Table 4-7 as replaced by HRMU)

| Name | Box | Index | Raw byte for `hw_mxpr $r,N` | Access | Notes |
|---|---|---|---|---|---|
| TB_TAG | I | 0 | 0x20 | W | PALmode only. Shared by ITB and DTB fills |
| ITB_PTE | I | 1 | 0x21 | R/W | PALmode only |
| ICCSR | I | 2 | 0x22 | R/W | |
| ITB_PTE_TEMP | I | 3 | 0x23 | R | PALmode only |
| EXC_ADDR | I | 4 | 0x24 | R/W | |
| SL_RCV | I | 5 | 0x25 | R | |
| ITBZAP | I | 6 | 0x26 | W | PALmode only |
| ITBASM | I | 7 | 0x27 | W | PALmode only |
| ITBIS | I | 8 | 0x28 | W | PALmode only |
| PS | I | 9 | 0x29 | R/W | |
| EXC_SUM | I | 10 | 0x2a | R/W | |
| PAL_BASE | I | 11 | 0x2b | R/W | |
| HIRR | I | 12 | 0x2c | R | |
| SIRR | I | 13 | 0x2d | R/W | |
| ASTRR | I | 14 | 0x2e | R/W | |
| HIER | I | 16 | 0x30 | R/W | |
| SIER | I | 17 | 0x31 | R/W | |
| ASTER | I | 18 | 0x32 | R/W | |
| SL_CLR | I | 19 | 0x33 | W | |
| SL_XMIT | I | 22 | 0x36 | W | |
| TB_CTL | A | 0 | 0x40 | W | The task brief calls it DTB_CTL; the HRM name is TB_CTL. Also selects the ITB array |
| DTB_PTE | A | 2 | 0x42 | R/W | |
| DTB_PTE_TEMP | A | 3 | 0x43 | R | |
| MM_CSR | A | 4 | 0x44 | R | |
| VA | A | 5 | 0x45 | R | Read unlocks VA and MM_CSR |
| DTBZAP | A | 6 | 0x46 | W | |
| DTBASM | A | 7 | 0x47 | W | |
| DTBIS | A | 8 | 0x48 | W | |
| BIU_ADDR | A | 9 | 0x49 | R | Read unlocks BIU_ADDR and BIU_STAT[7:0] |
| BIU_STAT | A | 10 | 0x4a | R | |
| DC_STAT | A | 12 | 0x4c | R | (C_STAT on the 21064A) |
| FILL_ADDR | A | 13 | 0x4d | R | Read unlocks FILL_ADDR, BIU_STAT[14:8], FILL_SYNDROME |
| ABOX_CTL | A | 14 | 0x4e | W | |
| ALT_MODE | A | 15 | 0x4f | W | |
| CC | A | 16 | 0x50 | W | Read via RPCC |
| CC_CTL | A | 17 | 0x51 | W | HRMU drops the "21064 only"/DC_CTL split |
| BIU_CTL | A | 18 | 0x52 | W | |
| FILL_SYNDROME | A | 19 | 0x53 | R | |
| BC_TAG | A | 20 | 0x54 | R (W unlocks) | |
| FLUSH_IC | A | 21 | 0x55 | W | |
| FLUSH_IC_ASM | A | 23 | 0x57 | W | |
| PAL_TEMP[n] | P | n = 0-31 | 0x80+n | R/W | |

Write-only registers read as 0 (**Impl**; the HRM leaves it undefined). Writes to read-only registers
(e.g. `hw_mtpr $31,HIRR` in the ARC stub) are ignored.

### 4.2 Ibox registers (HRM 5.2)

**TB_TAG** (5.2.1, Fig. 5-1). Write only. Holds VA[42:13] (small page/DTB) or VA[42:22] (ITB large page,
GH=3) for the next ITB_PTE or DTB_PTE write. Bits [63:43] and [12:0] ignored.

**ITB_PTE** (5.2.2, Fig. 5-2). 12 entries: 8 small (8 KB) + 4 large (4 MB), selected by TB_CTL[GH]
(GH=3 large, else small). A write fills the entry at the array's not-last-used (NLU) pointer with
{TB_TAG, PTE} and advances the pointer. A read copies the entry at the pointer into ITB_PTE_TEMP and
advances the pointer.

| Write bit | Field | | Read bit (ITB_PTE_TEMP, Fig. 5-4) | Field |
|---|---|---|---|---|
| [52:32] | PFN[33:13] | | [34] | ASM |
| [11] | URE | | [33:13] | PFN[33:13] |
| [10] | SRE | | [12] | URE |
| [9] | ERE | | [11] | SRE |
| [8] | KRE | | [10] | ERE |
| [4] | ASM | | [9] | KRE |
| rest | ignored | | rest | RAZ |

**ICCSR** (5.2.3, Fig. 5-3, Table 5-1). Different bit positions for write and read:

| Field | Write bit | Read bit | Reset | Meaning |
|---|---|---|---|---|
| ASN[5:0] | [52:47] | [33:28] | kept | I-cache ASN (section 6.5) |
| RES | 46, 43 | 34, [27:24] | 0 | reserved |
| PCE[1:0] | [45:44] | [45:44] | 0 | either set = both performance counters count |
| FPE | 42 | 23 | 0 | FP enable; clear = FP instructions take FEN |
| MAP | 41 | 22 | 0 | I-stream superpage (section 6.2) |
| HWE | 40 | 21 | 0 | PAL instructions allowed in kernel mode |
| DI | 39 | 20 | 0 | dual issue (performance only) |
| BHE | 38 | 19 | 0 | branch history (performance only, Table 5-2) |
| JSE | 37 | 18 | 0 | JSR stack (performance only) |
| BPE | 36 | 17 | 0 | branch prediction (performance only) |
| PIPE | 35 | 16 | 0 | clear = drain after interlocked instructions (performance only) |
| PCMUX1[2:0] | [34:32] | [15:13] | 0 | counter 1 input (Table 5-4) |
| PCMUX0[3:0] | [11:8] | [12:9] | 0 | counter 0 input (Table 5-3) |
| PC0 | 3 | 1 | kept | counter 0 interrupt every 2^16 (0) or 2^12 (1) events |
| PC1 | 0 | 2 | kept | counter 1 interrupt every 2^12 (0) or 2^8 (1) events |
| MBZ | [63:53], [31:12], [7:5], [2:1] | -- | | |

Read bits not listed are RAZ (including read bit 3, which VMS PALcode tests, section 10). MAME has the same
layout. Writes of ASN need 8 cycles before native-mode fetch (Table 4-4): interlocked in our core.
**Impl:** DI, BHE, JSE, BPE and PIPE are stored and read back but have no functional effect. Write bit 1
(VMS PALcode writes `0xF8_0000_0002`) is MBZ: ignored.

**EXC_ADDR** (5.2.5, Fig. 5-5). R/W. [63:2] PC, [1] see below, [0] PALmode of the excepting/return
context. Written by hardware on every exception (section 5.3). Writing it in native mode (via HWE) with
bit 0 = 1 is UNDEFINED (Table 5-1 note).

**SL_CLR** (5.2.6, Fig. 5-6). Write-zero-to-clear: [32] SLC (serial line), [15] PC1, [8] PC0, [2] CRD.
`hw_mtpr $31,SL_CLR` clears all four.

**SL_RCV** (5.2.7). [3] RCV = current level of the `sRomD_h` pin; other bits RAZ. Any transition sets
HIRR[SLR].

**ITBZAP** (5.2.8) and **ITBIS** (5.2.10): invalidate all 12 entries and reset both NLU pointers.
**ITBASM** (5.2.9): invalidate entries with ASM=0. Invalidation clears valid bits only: the VMS reset code
writes an entry, ZAPs, reads the entry back and expects the same PTE (section 10), so **ZAP must not clear
the stored data** and must reset the pointer to entry 0.

**PS** (5.2.11, Fig. 5-8). Write: CM1 = bit 4, CM0 = bit 3 (= ARM PS[4:3]). Read: CM1 = bit 34, CM0 =
bit 1, rest RAZ. (MAME reads CM0 at bit 0; the HRM figure says bit 1.) PALmode does not change PS.

**EXC_SUM** (5.2.12, Fig. 5-9, Table 5-6). [8] IOV, [7] INE, [6] UNF, [5] FOV, [4] DZE, [3] INV, [2] SWC,
[33] MSK, rest RAZ. Bits [8:2] are set by arithmetic traps and cleared by **any write** (which also clears
SWC; the mask is not affected). SWC: set when an FP instruction with /S traps and every FP trap since the
last write also had /S; cleared when one without /S traps. MSK is a one-bit window on the 64-bit register
write mask (architectural layout ARM 6.3.2.2: bit n = Rn, bit 32+n = Fn): a shift register, each read
returns the top bit and shifts it out, in the order F31, F30, ... F0, I31, ... I0 (HRM: "order F31-F0
then I31-I0"). A write does not touch it. NT 4.0's PALcode (A321064.PAL, ARITH) depends on both: it reads
EXC_SUM once (that read's MSK is F31), writes it, then reads 31 bits as F30..F0 (and 32 more as integer
registers only after IOV). Reads must be 3 cycles apart on the chip.

**PAL_BASE** (5.2.13, Fig. 5-10). [33:14] PAL_BASE, other bits IGN on write, RAZ on read. Cleared at reset.
Writing must not race an exception (rule 11). The DROM writes 0x40210 (effective 0x40000) on one path.

**HIRR** (5.2.14, Fig. 5-11, Table 5-7). Read only; also returned by reads of SIRR and ASTRR:

| Bits | Field |
|---|---|
| [32:29] | ASTRR[3:0]: U=32, S=31, E=30, K=29 |
| [28:14] | SIRR[15:1] (SIRR n at bit 13+n) |
| 13 | SLR serial line request |
| [12:10] | HIRR[2:0] = irq_h[2:0] |
| 9 | PC0 counter 0 request |
| 8 | PC1 counter 1 request |
| [7:5] | HIRR[5:3] = irq_h[5:3] |
| 4 | CRR correctable read request |
| 3 | ATR: an enabled, mode-qualified AST is pending (and SIER[2]=1) |
| 2 | SWR: an enabled software interrupt is pending |
| 1 | HWR: an enabled hardware interrupt (irq, PC0, PC1, SLR, CRR) is pending |
| 0, [63:33] | RAZ |

HIRR[5:0] are "delayed copies" of the pins: level-sensitive, not latched (passive release: a dropped
request reads 0, HRM 2.3.3).

**SIRR** (5.2.15, Fig. 5-12). Write: SIRR[15:1] at [47:33]. **ASTRR** (5.2.16, Fig. 5-13). Write: UAR 51,
SAR 50, EAR 49, KAR 48. Both read as HIRR.

**HIER** (5.2.17, Fig. 5-14, Table 5-8). Write: SLE 32, PC1 15, HIER[5:0] [14:9], PC0 8, CRE 2. Read (also
returned by SIER and ASTER reads):

| Bits | Field |
|---|---|
| [32:29] | ASTER: UAE 32, SAE 31, EAE 30, KAE 29 |
| [28:14] | SIER[15:1] |
| 13 | SLE |
| [12:10] | HIER[2:0] |
| 9 | PC0 enable |
| 8 | PC1 enable |
| [7:5] | HIER[5:3] |
| 4 | CRE |
| [3:0], [63:33] | RAZ |

**SIER** (5.2.18). Write: SIER[15:1] at [47:33]. **ASTER** (5.2.19). Write: UAE 51, SAE 50, EAE 49, KAE 48.
The write formats of HIER and SIER do not overlap, and VMS PALcode writes one IPL-table value to both
(`hw_mtpr rX,HIER` then `hw_mtpr rX,SIER`, FW srm 0xc490, 0xc5e8): each register must take only its own
bits.

**SL_XMIT** (5.2.20, Fig. 5-17). [4] TMT drives `sRomClk_h`. Write only.

### 4.3 Abox registers (HRM 5.3)

**TB_CTL** (5.3.1, Fig. 5-18). [6:5] GH: granularity of the next DTB fill (0: 8 KB, 1: 64 KB, 2: 512 KB,
3: 4 MB); for the ITB 3 = large array, else small. Applies to TB reads too. PALcode writes the whole PTE to
it (PTE[6:5] is the architectural GH field).

**DTB_PTE** (5.3.2, Fig. 5-19). 32 entries, NLU replacement, or round-robin with ABOX_CTL[DTB_RR]. Write
format = the ARM memory PTE: [52:32] PFN[33:13], [15] UWE, [14] SWE, [13] EWE, [12] KWE, [11] URE,
[10] SRE, [9] ERE, [8] KRE, [4] ASM, [2] FOW, [1] FOR; [0] (V) and the rest ignored ("the valid bit is
not represented in hardware"). Write = {TB_TAG, TB_CTL.GH, PTE} into the entry at the pointer, pointer++.
Read = entry at pointer -> DTB_PTE_TEMP, pointer++. Two DTB_PTE reads may not be back to back (rule 17).

**DTB_PTE_TEMP** (5.3.3, Fig. 5-20). [34] ASM, [33:13] PFN, [12] URE, [11] SRE, [10] ERE, [9] KRE, [8] UWE,
[7] SWE, [6] EWE, [5] KWE, [4] FOW, [3] FOR, rest RAZ.

**MM_CSR** (5.3.4, Fig. 5-21, Table 5-9). [0] WR, [1] ACV, [2] FOR, [3] FOW, [8:4] RA, [14:9] OPCODE, rest
RAZ. Updated on a D-stream fault or DTB miss only while unlocked; locked with VA until VA is read. Unlocked
at reset.

**VA** (5.3.5). The faulting effective VA (64 bits as computed, **Impl**). Reading unlocks VA and MM_CSR.
PALcode at entries of higher priority than DTB miss must read VA to unlock (HRM 4.5 note).

**DTBZAP** (5.3.6): invalidate all 32, reset pointer. **DTBASM** (5.3.7): invalidate ASM=0 entries.
**DTBIS** (5.3.8): invalidate the entry that maps VA = Rb. **FLUSH_IC** (5.3.9): invalidate the whole
I-cache. **FLUSH_IC_ASM** (5.3.10): invalidate I-cache blocks with ASM=0.

**ABOX_CTL** (5.3.11, Fig. 5-22, Table 5-10). Write only, cleared at reset:

| Bit | Field | Effect | Our RTL |
|---|---|---|---|
| 0 | WB_DIS | write buffer does not unload (diagnostic) | implement (stall) |
| 1 | MCHK_EN | uncorrectable errors cause MCHK; when clear, error registers still latch | implement |
| 2 | CRD_EN | SOFT_ERROR acks raise CRR | implement (never happens) |
| 3 | IC_SBUF_EN | I-cache stream buffer | ignore |
| 4 | **SPE_1** | D-stream superpage VA[42:30] = 0x1FFE -> PA[33:30] = 0, PA[29:0] = VA[29:0], kernel only | implement |
| 5 | **SPE_2** | D-stream superpage VA[42:41] = 2 -> PA[33:13] = VA[33:13] (VA[40:34] ignored), kernel only | implement |
| 6 | EMD_EN | invert PA[2] for D-stream references (big-endian) | optional (unused by our firmware) |
| 7 | STC_NORESULT | STx_C result UNPREDICTABLE; LDx_L/STx_C invalidate the D-cache line | ignore (always produce a result) |
| 8 | NCACHE_NDISTURB | non-cached reads leave the D-cache line alone | ignore |
| 9 | DTB_RR | DTB round-robin replacement | ignore (round-robin always) |
| 10 | **DC_ENA** | D-cache enable; clear = disabled and flushed | implement |
| 11 | DC_FHIT | force D-cache hit (diagnostic) | ignore |
| 12-15 | DC_16K, F_TAG_ERR, NOCHK_PAR, DOUBLE_INVAL | 21064A only | ignore |

**ALT_MODE** (5.3.12, Fig. 5-23). [4:3] AM (00 K, 01 E, 10 S, 11 U) for HW_LD/HW_ST with ALT.

**CC** (5.3.13, Fig. 5-24) and **CC_CTL** (5.3.14, Fig. 5-25). The 64-bit CC is read by RPCC: [63:32]
OFFSET, [31:0] COUNTER. `HW_MTPR CC` writes [63:32] only. `HW_MTPR CC_CTL` writes COUNTER = Rn[31:0] and
ENABLE = Rn[32]. COUNTER[3:0] must be written as 0 (rule 6). When enabled, COUNTER increments once per CPU
cycle and wraps at 32 bits (OFFSET is not carried into). Disabled at reset. Table 4-7 calls CC write-only,
5.3.13 shows an MFPR read format. **Impl:** `HW_MFPR CC` returns the same as RPCC.

**BIU_CTL** (5.3.15, Fig. 5-26, Tables 5-12 to 5-14). Write only:

| Bits | Field | Bits | Field |
|---|---|---|---|
| 0 | BC_ENA | [30:28] | BC_SIZE (000 = 128 KB ... 111 = 16 MB; 010 = 512 KB) |
| 1 | ECC (0 = parity) | 31 | BAD_TCP |
| 2 | OE | [35:32] | BC_PA_DIS (bit 32+n: no Bcache for PA[33:32] = n) |
| 3 | BC_FHIT | 36 | BAD_DP |
| [7:4] | BC_RD_SPD | 37 | BYTE_PARITY (21064A) |
| [11:8] | BC_WR_SPD | 38 | SYS_WRAP |
| 12 | DELAY_WDATA | 39 | IMAP_EN (21064A) |
| [27:13] | BC_WE_CTL[15:1] | [42:40] | BC_BURST_SPD |
| | | 43 | BC_BURST_ALL |
| | | 44 | FAST_LOCK (21064A) |

**Impl:** the Bcache is not modelled inside the CPU (CORE_SPEC: "may be smaller or omitted"). BIU_CTL is a
plain register exported to the system (`biu_ctl` output) so the 21071 model can see BC_ENA/BC_SIZE if it
wants to; it has no effect on the CPU.

**DC_STAT** (5.3.16, Fig. 5-27, Table 5-15). [2:0] CHIP_ID = **111 (production 21064)**, [3] DC_HIT (last
load/store hit the D-cache). VMS PALcode reads CHIP_ID to choose a table (srm 0xc334).

**BIU_STAT** (5.3.18, Fig. 5-29, Table 5-17). [0] BIU_HERR (cycle ended with HARD_ERROR), [1] BIU_SERR
(SOFT_ERROR), [2] BC_TPERR, [3] BC_TCPERR, [6:4] BIU_CMD (cReq code of the failing cycle), [7] FATAL1
(second error while one of [3:0] set), [8] FILL_ECC, [9] FILL_CRD, [10] FILL_DPERR, [11] FILL_IRD
(1 = I-stream fill), [13:12] FILL_QW, [14] FATAL2. [6:0] lock when any of [3:0] is set, unlocked by
reading BIU_ADDR; [13:8] lock on FILL_ECC/FILL_DPERR, unlocked by reading FILL_ADDR. Not cleared by reset
on the chip (**Impl:** cleared).

**BIU_ADDR** (5.3.19, Fig. 5-30). [33:5] address of the failing cycle; [4:2] UNPREDICTABLE for
READ_BLOCK/LDx_L, else 0. **FILL_ADDR** (5.3.20, Fig. 5-31). [33:5] block of the failing fill; [4:2] =
PA[4:2] of the load for D-stream fills. **FILL_SYNDROME** (5.3.21, Fig. 5-32). [13:7] HI, [6:0] LO.
**Impl:** our bus has no parity/ECC, so FILL_* never latch; they read 0.

**BC_TAG** (5.3.22, Fig. 5-33). [0] HIT, [1] TAGCTL_P, [2] TAGCTL_D, [3] TAGCTL_S, [4] TAGCTL_V,
[21:5] TAG[33:17], [22] TAGADR_P. Each MFPR returns bit 0 and shifts right; an MTPR unlocks.
**Impl:** reads 0.

### 4.4 PAL_TEMP (HRM 5.4)

32 x 64-bit R/W scratch registers, UNDEFINED at reset. Firmware conventions are in section 10.

---

## 5. Exceptions and PAL entry points

### 5.1 Entry points (HRM 4.5, Table 4-1, Table 4-2; PALG Fig. 2-1)

New PC = {PAL_BASE[33:14], offset[13:0]}, PALmode = 1. Listed from highest to lowest priority:

| Entry | Offset | Cause |
|---|---|---|
| RESET | 0x0000 | reset |
| MCHK | 0x0020 | uncorrected hardware error (bus HARD_ERROR, fill parity/ECC) with ABOX_CTL[MCHK_EN] = 1 |
| ARITH | 0x0060 | arithmetic trap (section 8.4, /V integer overflow) |
| INTERRUPT | 0x00E0 | enabled interrupt while not in PALmode (section 7); includes CRD |
| D_FAULT | 0x01E0 | D-stream ACV / FOR / FOW / bad VA (Table 4-2) |
| ITB_MISS | 0x03E0 | I-stream VA misses the ITB (native mode only) |
| ITB_ACV | 0x07E0 | I-stream access violation |
| DTB_MISS native | 0x08E0 | DTB miss, not in PALmode |
| DTB_MISS PAL | 0x09E0 | DTB miss in PALmode |
| UNALIGN | 0x11E0 | D-stream alignment error |
| OPCDEC | 0x13E0 | reserved opcode; PAL instruction outside PALmode (without HWE+kernel); privileged CALL_PAL in non-kernel mode; CALL_PAL function out of range |
| FEN | 0x17E0 | FP instruction with ICCSR[FPE] = 0; IEEE rounding +/- infinity; IEEE datatype field not S, T or Q (section 8.1) |
| CALL_PAL | 0x2000-0x3FC0 | section 5.4 |

The four D-stream entries share one priority slot (pipe stage 6; Table 4-1); among themselves
(Table 4-2):

| BAD_VA | DTB miss | UNALIGN | PALmode | other fault | Entry |
|---|---|---|---|---|---|
| 1 | x | 1 | x | x | UNALIGN 0x11E0 |
| 1 | x | 0 | x | x | D_FAULT 0x01E0 |
| 0 | 1 | x | 1 | x | DTB_MISS PAL 0x09E0 |
| 0 | 1 | x | 0 | x | DTB_MISS native 0x08E0 |
| 0 | 0 | 1 | x | x | UNALIGN 0x11E0 |
| 0 | 0 | 0 | x | 1 | D_FAULT 0x01E0 |

So an unaligned reference that also misses the DTB takes the DTB miss first. BAD_VA = VA[63:43] is not the
sign extension of VA[42].

Table 4-1's column "Time" (pipe stage) also fixes the order between instructions: an older instruction's
fault in a later stage wins. **Impl:** the pipeline commits in order, so the oldest instruction's exception
wins, and within one instruction the order above applies. Interrupts are taken between instructions.

### 5.2 What the hardware saves

| Event | EXC_ADDR | Other state |
|---|---|---|
| Interrupt | PC of the next instruction not yet executed; bit 0 = 0 (interrupts never occur in PALmode) | none; PALcode reads HIRR |
| ITB_MISS, ITB_ACV | VPC of the fetch (HRM 4.7.1.1); bit 0 = 0 | none (PALcode reads EXC_ADDR) |
| D-stream (D_FAULT, DTB_MISS, UNALIGN) | PC of the faulting instruction; bit 0 = PALmode at the fault | VA, MM_CSR (if unlocked; then locked) |
| OPCDEC, FEN | PC of the instruction; bit 0 = PALmode | none |
| CALL_PAL | **PC + 4** (HRM 4.4.1, 5.2.5); bit 0: see Q3 | none |
| ARITH | PC after the trap shadow (chip, imprecise); bit 1 meaning below; bit 0 = PALmode | EXC_SUM bits and write mask |
| MCHK | restart PC; bit 1 meaning below | BIU_STAT/BIU_ADDR or FILL_* |
| RESET | UNDEFINED | section 1.2 |

EXC_ADDR bit 1 (HRM 5.2.5): only for ARITH and MCHK. 0 = "the PC in [63:2] is 4 too large" (the trap
pre-empted a CALL_PAL, which had already stored PC+4); 1 = correct. PALcode runs
`hw_mfpr EXC_ADDR; subq 2; bic 2; hw_mtpr EXC_ADDR` (seen in OSF PAL ARITH 0x14074, ARC 0x80700084).
All other entries see bit 1 = 0.

**Impl (precise model):** arithmetic traps and machine checks are taken when the instruction reaches
writeback, after its result is written, with nothing younger committed. EXC_ADDR = PC of the trapping
instruction + 4 with **bit 1 = 1**, so the PALcode sequence above leaves it unchanged. The result
written is the one section 8.4 defines. MCHK on a load: EXC_ADDR = PC of the load + 4, bit 1 = 1, and the
load's destination is not written (unverified what the chip leaves; HRM 4.6 rule 25 describes the chip
reporting one instruction early).

### 5.3 VA/MM_CSR filling (section 4.3)

On every D-stream exception with MM_CSR unlocked: VA <- effective VA; MM_CSR.WR <- the reference is a write
(store, STx_C, HW_ST); ACV/FOR/FOW <- the fault reason (all 0 for DTB miss and UNALIGN; ACV = 1 for bad VA,
**Impl**); RA <- instruction[25:21]; OPCODE <- instruction[31:26]. Then lock. Unlock on VA read.

### 5.4 CALL_PAL dispatch (HRM 4.4.1, 4.5)

    func = instruction[25:0]
    if func[25:8] != 0 or func[6] != 0           -> OPCDEC
    else if func[7] == 0 (privileged, 0x00-0x3F):
         if PS.CM != kernel                      -> OPCDEC
         else offset = 0x2000 + func[5:0]*64
    else (unprivileged, 0x80-0xBF):  offset = 0x3000 + func[5:0]*64
    EXC_ADDR <- PC + 4 (bit 0 per Q3); PALmode <- 1; PC <- {PAL_BASE[33:14], offset}

So HALT -> 0x2000, DRAINA -> 0x2080, IMB (0x86) -> 0x3180, OSF `callsys` (0x83) -> 0x30C0. Each slot is 64
bytes (16 instructions). "Privileged" is about who may call it, not where it runs (HRM 4.4.1).

### 5.5 Exceptions while in PALmode

Possible: MCHK, ARITH (OSF PALcode treats it as fatal: `blbs EXC_ADDR` at 0x14070), D-stream faults
(DTB_MISS PAL is the normal case), OPCDEC, FEN. Not possible: interrupts, ITB miss/ACV. EXC_ADDR[0] = 1, so
HW_REI returns to PALmode. The new entry overwrites EXC_ADDR: PALcode must save it first.

---

## 6. Memory management

### 6.1 Addresses

43-bit virtual addresses (VA[63:43] must equal VA[42]) and 34-bit physical addresses (HRM 4.7). PA[33] = 1
is I/O space on the AS200 (HARDWARE.md section 4). Page size 8 KB.

### 6.2 I-stream (HRM 2.3.2, 5.2.3)

- **PALmode: no translation.** The PC is a physical address, PA = PC[33:0] (HRM 4.3: "I-stream memory
  mapping is disabled"). No ITB lookup, no access check. **Impl:** PC[63:34] are carried but ignored for
  the fetch.
- Native mode, in this order:
  1. **Superpage**: ICCSR[MAP] = 1, PS.CM = kernel and VA[42:41] = 2 -> PA[33:13] = VA[33:13], I-cache
     ASM forced to 1. In other modes the superpage does not apply (**Impl:** fall through to the ITB).
  2. **ITB** (8 small + 4 large entries, fully associative, NLU): small match on VA[42:13], large on
     VA[42:22]; PA = {PFN[33:13], VA[12:0]} or {PFN[33:22], VA[21:0]}. No match -> **ITB_MISS**.
  3. Hit but the xRE bit for PS.CM is clear -> **ITB_ACV**. (The ITB holds no FOE: PALcode checks FOE and
     V before filling, HRM 4.7.1.1.)
  - Non-canonical VPC: not described (Q8). **Impl:** ITB_ACV.
- PALcode must keep any VA mapped by only one entry (superpage, small or large) (HRM 2.3.2).

### 6.3 D-stream (HRM 2.5.1, 5.3)

For loads, stores and virtual HW_LD/HW_ST. "Mode" below is PS.CM, or ALT_MODE for HW_LD/HW_ST with ALT
(HRM Table 4-8; the superpage "kernel only" check also uses this mode, **Impl**, Q9):

1. BAD_VA and alignment checks (Table 4-2 priorities).
2. **Superpage 1**: ABOX_CTL[SPE_1], mode = K and VA[42:30] = 0x1FFE -> PA = {4'b0, VA[29:0]} (the NT
   KSEG0 window 0xFFFFFFFF80000000-0xFFFFFFFFBFFFFFFF -> PA 0-1 GB).
3. **Superpage 2**: ABOX_CTL[SPE_2], mode = K and VA[42:41] = 2 -> PA[33:0] = VA[33:0] (OSF/Linux KSEG
   0xFFFFFC0000000000).
4. **DTB** (32 entries, fully associative, all four GH sizes): entry matches when VA[42:13+3*GH] =
   tag[42:13+3*GH]; PA = {PFN[33:13+3*GH], VA[12+3*GH:0]}. No match -> **DTB_MISS** (PAL or native).
5. Protection: read needs xRE, write needs xWE for the mode, else ACV -> **D_FAULT**. Then FOR (read with
   PTE.FOR) or FOW (write with PTE.FOW) -> **D_FAULT**. RWC HW_LD checks both read and write (and FOW,
   **Impl**; in the RTL since `4d4c728`: OpenVMS's PROBEW is a `hw_ld/ar`, and without the check it said
   the supervisor stack was user-writable, `t3_rwc.py`). Superpage hits have no protection beyond the kernel check.
- No TNV in hardware: TBs never hold invalid PTEs; PALcode reports TNV (HRM 4.7.1).
- HW_LD/HW_ST with PHY: PA = effective address [33:0], no checks.

### 6.4 PALmode and translation: the exact rule

- **I-stream: never translated in PALmode.**
- **D-stream: translated in PALmode** exactly as in native mode (HRM 4.3: "D-stream mapping is still
  enabled"; HRM 4.7.1.2: "Unlike ITB misses, DTB misses can occur while the CPU is executing in PALmode";
  dedicated entry 0x09E0). Plain LDx/STx and virtual HW_LD/HW_ST in PALmode use the DTB and the
  superpages, with the access checks done against **PS.CM, which PALmode does not change** (so PALcode
  entered from user mode must use HW_LD/ST with ALT and ALT_MODE = kernel, or PHY, to reach kernel data).
  Only HW_LD/HW_ST with PHY bypass translation.
- Firmware confirms both: the SRM flash stub runs in PALmode and fills 4 MB 1:1 DTB entries from its
  DTB_MISS PAL handler (FW `srm_v6.4-1_flash_stub` 0x4009e0); the OSF ITB miss handler reads the virtual page
  table with `hw_ldq/a` (FW srm 0x14400).

### 6.5 ASN, ASM and the I-cache (HRM 2.3.2, 2.8.1.1, 5.2.3)

- The TBs hold no ASN: only ASM. ITBASM/DTBASM drop the ASM=0 entries on a context switch (HRM 2.3.2,
  2.5.1).
- The I-cache is physically tagged (tag = PA[33:13], 21 bits, index PA[12:5]) and each block also stores
  ASN (from ICCSR.ASN at fill) and ASM (from the ITB PTE, 1 for superpage). A fetch hits only if tag
  matches, V = 1, and (ASM = 1 or block ASN = ICCSR.ASN); an ASN mismatch "invalidates the fetch without
  affecting the Icache" (Table 5-1), i.e. it refills.
- **Impl** (unverified, Q10): PALmode fills set ASM = 1; PALmode fetches ignore ASN.

### 6.6 Fill sequences (HRM 4.7.1)

ITB: `hw_mtpr va,TB_TAG` (Ibox 0); `hw_mtpr pte,TB_CTL` (Abox 0, selects array); at least one cycle;
`hw_mtpr pte,ITB_PTE`. PALcode writing several ITB entries must write the one mapping EXC_ADDR last (rule
20). DTB: `hw_mtpr pte,TB_CTL`; `hw_mtpr va,TB_TAG`; `hw_mtpr pte,DTB_PTE`. At least two cycles between
an xTB_PTE write and the next TB_TAG write (rule 12), one between TB_CTL and ITB_PTE (rule 3). Interlocked
in our core.

---

## 7. Interrupts (HRM 2.3.3, 5.2.14-5.2.19, 6.5.8)

Sources:

| Source | Request | Enable |
|---|---|---|
| `irq_h[5:0]` pins | HIRR[5:0], level-sensitive, asynchronous | HIER[5:0] |
| Performance counter 0/1 overflow | PC0/PC1 request, set 6 cycles after the event; cleared by SL_CLR | HIER PC0/PC1 |
| Serial line | SLR, any transition of `sRomD_h`; cleared by SL_CLR[SLC] | HIER SLE |
| Corrected read (SOFT_ERROR ack with ABOX_CTL[CRD_EN]) | CRR; cleared by SL_CLR[CRD] | HIER CRE |
| Software | SIRR[15:1] | SIER[15:1] |
| AST | ASTRR[3:0] (K, E, S, U) | ASTER[3:0] and SIER[2] and mode |

An AST for mode m is deliverable when ASTRR[m] & ASTER[m] & SIER[2] and the current mode is m or less
privileged (PS.CM >= m numerically): "AST requests corresponding to a given mode are blocked whenever the
processor is in a higher mode" (HRM 2.3.3).

    take_interrupt = !PALmode & ( |(HIRR[5:0] & HIER[5:0]) | (PC0req & PC0en) | (PC1req & PC1en)
                                 | (SLR & SLE) | (CRR & CRE) | |(SIRR[15:1] & SIER[15:1]) | ast_ok )

There is no hardware priority or IPL: PALcode builds IPLs by choosing HIER/SIER values (HRM 2.3.3; VMS keeps
one HIER/SIER pair per IPL in memory). Before dispatching, the chip drains the pipeline and completes
outstanding D-cache fills; EXC_ADDR = restart PC (HRM 2.3.3). Interrupts are blocked in PALmode, so PALcode
re-enables them simply by returning with HW_REI to native mode.

**AS200 wiring** (`docs/HARDWARE.md` section 3):

| Pin | Source |
|---|---|
| IRQ0 | CPU bus and parity errors (21071 error interrupt) |
| IRQ1 | unused (tie low) |
| IRQ2 | all ISA and PCI device interrupts via the SIO 8259s; PALcode reads the vector with a PCI interrupt-acknowledge cycle |
| IRQ3 | NMI from the SIO (PCI SERR#, ISA IOCHK#) |
| IRQ4 | interval timer: BQ4285 periodic interrupt, straight to the CPU |
| IRQ5 | HALT button OR 8242 KBRST |

**Impl:** `irq[5:0]` go through a 2-flop synchroniser into HIRR. The performance counters are implemented
with the inputs that are cheap (total issues/2, cycles, PALmode cycles, loads, stores, branches, D-cache and
I-cache misses); the rest count 0. `perf_cnt_h` inputs are tied low.

---

## 8. Floating point

### 8.1 Instruction set (HRM 3.1.2-3.1.3, Tables 3-3, 3-4)

Function field [10:0] (= instruction [15:5]):

| Bits | IEEE (op 16) | VAX (op 15) |
|---|---|---|
| [10:8] trap | 000 none, 001 /U (/V for CVTTQ), 101 /SU (/SV), 111 /SUI (/SVI); 010/110 only in CVTST (0x2AC, 0x6AC) | 000 none, 001 /U (/V for CVTGQ), 100 /S, 101 /SU (/SV) |
| [7:6] rounding | 00 /C chopped, 01 /M minus inf, 10 normal, 11 /D dynamic (FPCR.DYN) | 00 /C, 10 normal |
| [5:4] source | 00 S, 10 T, 11 Q | 00 F, 01 D, 10 G, 11 Q |
| [3:0] op | 0 ADD, 1 SUB, 2 MUL, 3 DIV, 4 CMPTUN, 5 CMPxEQ, 6 CMPxLT, 7 CMPxLE, C CVT to S (CVTTS/CVTQS), E CVTQT, F CVTTQ | 0-3 as IEEE, 5-7 CMPGxx, C CVTGF/CVTQF, D CVTGD, E CVTDG/CVTQG, F CVTGQ |

IEEE (opcode 0x16): ADDS/ADDT, SUBS/SUBT, MULS/MULT, DIVS/DIVT with every qualifier column of Table 3-3
(none, /C, /M, /D, /U, /UC, /UM, /UD, /SU, /SUC, /SUM, /SUD, /SUI, /SUIC, /SUIM, /SUID); CMPTUN, CMPTEQ,
CMPTLT, CMPTLE (none, /SU); CVTQS, CVTQT (none, /C, /M, /D, /SUI, /SUIC, /SUIM, /SUID); CVTTS (all 16);
CVTST (0x2AC, /S 0x6AC); CVTTQ (none, /C, /V, /VC, /SV, /SVC, /SVI, /SVIC, /D, /VD, /SVD, /SVID, /M, /VM,
/SVM, /SVIM).

VAX (opcode 0x15): ADDF/G, SUBF/G, MULF/G, DIVF/G, CVTGF, CVTGD, CVTDG (none, /C, /U, /UC, /S, /SC, /SU,
/SUC); CMPGEQ, CMPGLT, CMPGLE (none, /S); CVTQF, CVTQG (none, /C); CVTGQ (none, /C, /V, /VC, /S, /SC,
/SV, /SVC). "Limited support for D_floating" (HRM 2.6): D exists only as a CVTDG source and a CVTGD
result; D arithmetic goes through G.

Opcode 0x17: CVTLQ 010, CPYS 020, CPYSN 021, CPYSE 022, MT_FPCR 024, MF_FPCR 025, FCMOVEQ 02A, FCMOVNE 02B,
FCMOVLT 02C, FCMOVGE 02D, FCMOVLE 02E, FCMOVGT 02F, CVTQL 030, CVTQL/V 130, CVTQL/SV 530.

FEN conditions (HRM Table 4-1): ICCSR[FPE] = 0 for any FP instruction (opcodes 15-17, 20-27, FP branches
31-33/35-37); "FP IEEE round to +/- infinity"; "FP IEEE with datatype field other than S, T, Q" (source
field 01 in opcode 16). The rounding item contradicts Table 3-3, which lists /M and /D codes for the 21064,
and HRM 2.6 ("all rounding modes except round to +/- infinity, which can be provided in software") (Q4).
**Impl:** /C, /M, normal and all four dynamic modes are done in hardware (a superset; no FEN for rounding);
source field 01 in opcode 16 takes FEN; other unlisted function codes take OPCDEC (FEN first if FPE = 0).

### 8.2 FPCR (HRM 2.6.1, Fig. 2-3, Table 2-2)

| Bit | Field |
|---|---|
| 63 | SUM: OR of [57:52] |
| [62:60] | RAZ/IGN (62 is INED on the 21064A only) |
| [59:58] | DYN: 00 chopped, 01 minus inf, 10 nearest, 11 plus inf |
| 57 | IOV |
| 56 | INE |
| 55 | UNF |
| 54 | OVF |
| 53 | DZE |
| 52 | INV |
| [51:0] | RAZ/IGN |

The flags record every exception detected whether or not its trap is enabled (except SWC), and only
MT_FPCR clears them. **Impl:** SUM is computed (OR of [57:52]) on read. MT_FPCR writes from Fa, MF_FPCR
writes Fa (assemblers put the register in all three fields).

### 8.3 Register formats and loads/stores (ARM 4.7, 4.8)

| Instr | Memory -> register |
|---|---|
| LDT/STT | 64 bits unchanged |
| LDS | R = {m[31], MAP_S(m[30:23]), m[22:0], 29'b0}. MAP_S: 0xFF -> 0x7FF; 1xxxxxxx -> 1000xxxxxxx; 0xxxxxxx (non-zero) -> 0111xxxxxxx; 0 -> 0 |
| STS | m = {R[63:62], R[58:29]} |
| LDF | R = {m[15], MAP_F(m[14:7]), m[6:0], m[31:16], 29'b0}; MAP_F as MAP_S but 0xFF has no special case |
| STF | m = {R[44:29], R[63:62], R[58:45]} |
| LDG/STG (G and D) | word swap: R = {m[15:0], m[31:16], m[47:32], m[63:48]} |

A longword integer in an FP register sits in [63:62] and [58:29] (CVTLQ/CVTQL). With ABOX_CTL[EMD_EN]
longword accesses invert PA[2] (ARM's big-endian rule).

### 8.4 EV4 exception rules (HRM 2.6.1, 2.7; ARM App. D waiver D.1.1)

- **INV, DZE, OVF traps are always enabled.** If they occur the destination is UNPREDICTABLE.
- **Any non-finite IEEE operand (NaN, Inf, denormal) signals INV** when the instruction can take an
  exception (not CPYSx, FCMOV, MT/MF_FPCR, loads/stores), compares included. VAX: reserved operand or
  dirty zero signals INV. IEEE 0/0 is INV, not DZE; x/0 with x non-zero finite is DZE.
- **UNF**: the destination is **always forced to true zero, all 64 bits 0**, even where IEEE would give
  -0. The trap is taken only with /U (and /SU, /SUI).
- **INE**: only with /SUI. The destination holds the correctly rounded result. With INE enabled, OVF and UNF
  also signal INE. CVTQL with IOV sets FPCR[INE] (never traps on INE).
- **IOV**: CVTTQ, CVTGQ, CVTQL: result = low bits of the true result; trap only with /V.
- **21064 divide**: DIVS/DIVT (and only those) never set FPCR[INE]; with /I (DIVS/SUI, DIVT/SUI) they
  **always** trap and set EXC_SUM[INE], unless an input exception (INV/DZE) occurred.
- Input exceptions take priority over output exceptions: only the input one is recorded and signalled.
- Traps are **imprecise** on the chip (trap shadows in HRM 4.6 rule 11); software uses TRAPB and /S.
  EXC_SUM records each trapping exception and the destination register in the write mask; SWC per section
  4.2.
- **Impl:** traps are reported precisely at the trapping instruction (section 5.2), which is a legal
  instance of the imprecise model; TRAPB/EXCB then cost nothing. If a later version overlaps FP divide with
  younger instructions, TRAPB must wait for it and the write mask must accumulate across the shadow.
- Round to nearest/chopped/minus/plus as per FPCR or the instruction. The golden model for expected results
  is SoftFloat with these rules applied on top (CPU_TEST_PLAN T2).

### 8.5 Compares, branches, moves

- CMPTxx/CMPGxx write 0x4000000000000000 (IEEE 2.0 / VAX 0.5) for true, 0 for false.
- FBEQ/FBNE test Fa[62:0] == 0; FBLT: Fa[63] & (Fa[62:0] != 0); FBGE: !FBLT; FBLE: Fa[63] | (Fa[62:0] == 0);
  FBGT: !FBLE. FCMOVxx use the same tests on Fa and copy Fb to Fc.
- CPYS: {Fa[63], Fb[62:0]}; CPYSN: {~Fa[63], Fb[62:0]}; CPYSE: {Fa[63:52], Fb[51:0]}.
- CVTLQ: Fc = SEXT({Fb[63:62], Fb[58:29]}); CVTQL: Fc = {Fb[31:30], 3'b000, Fb[29:0], 29'b0}.

### 8.6 Latencies on the chip (performance only)

Non-divide FP latency 6 cycles, one issue per cycle; DIVF/DIVS 34 (30 to issue), DIVG/DIVT 63 (59)
(HRM 2.6, HRMU, rule 11). Firmware calibrates delays with RPCC, so slower is fine.

---

## 9. Locks, ordering, caches, write buffer

### 9.1 LDx_L / STx_C (HRM 5.5, 6.4.10; 21071 3.1.5)

- The 21064 keeps **no lock flag**. LDx_L always goes off chip as an LDL_L/LDQ_L transaction (like
  READ_BLOCK, Bcache not probed); STx_C always goes off chip as STL_C/STQ_C (like WRITE_BLOCK with one
  longword/quadword enabled), and the system decides success: `cAck` = STx_C_FAIL means failure.
- On the AS200 the **21071-CA** holds the lock: lock address = sysAdr[32:5] (32-byte granule), set by every
  LDx_L, cleared by reset, a DMA write to the locked block, **any STx_C**, **any CPU write to an I/O
  address**, or `ioClrLock` from the 21071-DA.
- PALcode clears the lock flag with a physical store-conditional: VMS PAL reset does
  `hw_stq/pa t1,1272(zero)` (srm 0xc498).
- STx_C writes Ra = 1 (success) or 0 (failure), so it waits for the bus acknowledge. MB and STx_C force the
  write buffer to drain (HRM 2.5.4).
- **Impl:** LDx_L does not allocate in the D-cache and invalidates the D-cache block it reads; STx_C
  invalidates the block (the system has the data). LDx_L/STx_C to I/O space work the same way.
  The flag and address (16-byte granule) are kept in the core and cleared like the 21071-CA's: any
  STx_C, any store to PA >= 4 GB (I/O), and a DMA write whose dInvReq index matches the lock address
  (by index only, so sometimes more often than needed). Without the I/O clear, an STx_C succeeded
  across an interrupt and a context switch (t3_lock).
  Unaligned LDx_L/STx_C take UNALIGN. "HW_STC instructions cannot be followed, for two cycles, by any load
  that may miss" (rule 21): interlocked.

### 9.2 Barriers and the write buffer (HRM 2.5.4, 6.4.11; ARM App. D.1.2)

- Write buffer: 4 entries x 32 bytes, longword masks. Stores to the same aligned 32-byte block merge into
  a non-empty entry, which can reorder and collapse writes; MB/STx_C/FETCH entries never merge. It unloads
  when it holds >= 2 entries, or 1 entry idle for 256 cycles, or an MB/STx_C, or a load miss hits a buffered
  block (then the whole buffer drains).
- MB: all earlier memory operations complete before later ones; the BARRIER transaction lets the system
  push its own buffers and deliver pending invalidates. Software orders device writes with MB.
- **Impl:** a simpler, stricter buffer: stores retire in program order into a FIFO; consecutive stores to
  the same 32-byte block may merge only while that entry is the tail and the block is in memory space
  (PA[33] = 0) (dense I/O merging is optional, off at first). Any load that goes to the bus (miss, uncached,
  I/O, LDx_L) waits until the FIFO is empty. MB = drain + BARRIER. This keeps device accesses in program
  order (stricter than the chip, so correct software still works).

### 9.3 Caches (HRM 2.8)

- **I-cache**: 8 KB direct-mapped, 32-byte blocks, physical tag PA[33:13], V, ASM, ASN[5:0], 8-bit branch
  history per block (performance only). **Not coherent** with memory or DMA ("unaffected by the
  invalidate bus"). Software uses IMB (CALL_PAL 0x86, PALcode does FLUSH_IC) after writing code. Fills use
  data only after the whole block arrived; I-stream reads must never be signalled non-cached.
  The 1-entry stream buffer (ABOX_CTL[IC_SBUF_EN]) is performance only. **Impl:** no stream buffer, no BHT;
  I-stream reads to PA[33] = 1 are fetched but not cached (unverified, firmware does not execute from I/O
  space).
- **D-cache**: 8 KB direct-mapped, 32-byte blocks, physical tags, **write-through, allocate on read miss
  only**. Store hit updates the block; store miss does not allocate. The system decides cacheability per
  read (`dRAck` OK vs OK_NCACHE); disabled entirely when ABOX_CTL[DC_ENA] = 0 (clearing DC_ENA flushes it).
  Coherence with DMA comes from the system: `dInvReq_h` invalidates the block at index `iAdr_h[12:5]`
  (HRM 6.5.3). **Impl:** index-only invalidate input, as on the chip.
- Primary caches hold PA[33] = 1 data only if the system says so; on the AS200 I/O reads are non-cached.
  **Impl:** the CPU also never allocates for PA[33] = 1.

---

## 10. What the real firmware uses

From the disassembly (`scratch/disasm/`). Addresses are image addresses as in the listings.

**Multi-select IPR writes** (section 3.1): ICCSR+PAL_TEMP2, PS+PAL_TEMP9, ABOX_CTL+PAL_TEMP14,
ALT_MODE+PAL_TEMP15, BIU_CTL+PAL_TEMP18, ITBZAP+DTBZAP, ITBASM+DTBASM. Shadows: PAL_TEMP2 = ICCSR,
PAL_TEMP9 = PS (VMS PS with IPL), PAL_TEMP12 = ABOX_CTL (ARC), PAL_TEMP14 = ABOX_CTL (SROM/DROM),
PAL_TEMP15 = ALT_MODE (VMS), PAL_TEMP18 = BIU_CTL (SROM/DROM).

**DROM V1.2** (runs in PALmode, position-independent, PAL_BASE = image + 0x40):
- Entry: `mb; FLUSH_IC` twice; ABOX_CTL |= MCHK_EN via PAL_TEMP14 (0xdc-0xe4); `hw_ldq/p` PA 0x70.
- Speed calibration unless PA 0x70 = 2: CC_CTL = 1<<32 (enable, count 0), RPCC over 10 periods of an ISA
  timer, then a table: ~64.7-66.1 M -> 266 MHz, ~56.7-57.9 M -> 233, ~48.7-49.7 M -> 200, anything lower ->
  **166 MHz / 6000 ps** (a 50 MHz core lands here). Writes PA 0x10 (ps), 0x68 (MHz), 0x70, 0x110 and
  BIU_CTL[23:4] (166 MHz: 0x6340 = BC_RD_SPD 4, BC_WR_SPD 3, BC_WE_CTL[2:1]) with the PAL_TEMP18 shadow.
- Uses EXC_ADDR, DC_STAT, BIU_ADDR, FILL_SYNDROME, FILL_ADDR (MCHK), HIRR (interrupt test), CC_CTL/RPCC
  timing, SL_XMIT/SL_RCV/SL_CLR (bit-banged serial on the SROM port, ~52 us per bit = 19200 baud, timed
  with RPCC and the MHz value at PA 0x68: 0x2104-0x21c0), and a debug monitor that can deposit BIU_CTL,
  ABOX_CTL, ICCSR (with shadows) and PAL_BASE (0x1b00-0x1be8).
- Hand-off to the console: PAL_BASE = **0x100000**, EXC_ADDR = 0x100001, registers from the parameter block
  (section 1.3), PA 0x50 = "V1.2", t0/t1 = ABOX_CTL/BIU_CTL shadows, `hw_rei` (0x34c4-0x3538, again at
  0x3e88). Other path: PAL_BASE = 0x40210 (effective 0x40000), EXC_ADDR = 0x40211 (0x32f4).

**SRM flash stub** (PA 0x100000, then relocates itself; PALmode): FLUSH_IC; ITBZAP+DTBZAP; PAL_BASE = its
own base; a DTB_MISS PAL handler (0x4009e0) that fills **4 MB 1:1 DTB entries**: TB_TAG = VA,
PTE = (VA << 19) | 0xFF70 (ASM, GH = 3, all KRE..UWE), written to TB_CTL and DTB_PTE. So ordinary loads in
PALmode are translated and fault to 0x09E0.

**SRM VMS PALcode reset** (PAL_BASE 0x8000, path 0xc01c-0xc4d0):
- FLUSH_IC, saves a0..at in its data area, ABOX_CTL = **0x940A** (MCHK_EN, IC_SBUF_EN, DC_ENA, plus the
  21064A-only DC_16K and DOUBLE_INVAL), ICCSR+PT2 = **0x0000_00F8_0000_0002** (DI, BHE, JSE, BPE, PIPE; FPE
  off; bit 1 MBZ), reads ICCSR back and tests read bit 3.
- ITB probe: TB_CTL = 0x7FFF (GH = 3), ITB_PTE = 0x7FFF << 32, ITBZAP, `hw_mfpr ITB_PTE`, 3 NOPs,
  `hw_mfpr ITB_PTE_TEMP`, compares with 0x7FFF << 13 and records the result in PAL_TEMP2 bit 2. Needs the
  behaviour of section 4.2 (ZAP keeps data, resets the pointer).
- ALT_MODE = 0; PAL_BASE = t0; PS+PT9 = 0x1F00 (kernel); reads DC_STAT CHIP_ID; clears ASTRR, ASTER, SIRR;
  ITBZAP+DTBZAP; SL_CLR = 0; EXC_SUM write + 64 reads; CC = 0, CC_CTL = 1<<32; reads VA, Abox 11, BIU_ADDR,
  FILL_ADDR, DC_STAT and writes BC_TAG (unlocks); HIER = SIER = value from PA 0x4F8; `hw_stq/pa` (clear
  lock); `rc`.

**SRM OSF PALcode** (PAL_BASE 0x14000): ICCSR |= MAP (bit 41) and ABOX_CTL |= SPE_2 (0x20) (0x18710-0x18730);
FPE through `wrfen` (bit 42); PCE[45:44] through `wrperfmon`; ITB miss reads the page table with `hw_ldq/a`;
ARITH entry rejects EXC_ADDR[0] = 1 and applies the bit-1 correction; interrupt entry reads HIRR and HIER;
uses `hw_stq/a` to build frames on the kernel stack.

**ARC flash stub** (PA 0x100000, entered from the DROM in PALmode):
- ASTRR = ASTER = SIRR = SIER = HIER = 0, writes HIRR (ignored), SL_CLR = 0, `rc`, ITBZAP, DTBZAP,
  TB_CTL = 0.
- ABOX_CTL = **0x438** (IC_SBUF_EN, SPE_1, SPE_2, DC_ENA; no MCHK_EN); ICCSR = **0x0000_05F8_0000_0000**
  (PIPE, BPE, JSE, BHE, DI, **HWE**, FPE).
- PS = 0, CC_CTL = 0, CC = 0, CC_CTL = 1<<32.
- TB_CTL = 0x60 (large); four ITB large-page entries: TB_TAG = 0xFFFFFFFF80000000 + n*0x400000, ITB_PTE =
  0x110 + n<<41 (KRE, ASM, PFN n*512): VA 0xFFFFFFFF80000000-0x80FFFFFF -> PA 0-16 MB. All 4 large entries in
  use.
- `hw_rei` to **native kernel mode** at VA 0xFFFFFFFF801001D0 (I-stream through the ITB; D-stream through
  SPE_1). It then executes HW_MTPR in native mode thanks to HWE (FLUSH_IC, EXC_ADDR) and `hw_rei` into
  PALmode at the decompressed ARC.

**ARC PALcode** (PAL_BASE = 0x700000, from a `br` in PALmode): ABOX_CTL+PT12 = old | **0x43A**
(MCHK_EN, IC_SBUF_EN, SPE_1, SPE_2, DC_ENA); ICCSR = **0x0000_04F8_0000_0000** (PIPE, BPE, JSE, BHE, DI,
FPE; HWE off); clears the interrupt registers, CC as above, ALT_MODE = 0, PS = 0.

**Unusual things** to get right: dual-select MTPRs; native-mode HW instructions with HWE (ARC stub); TB_TAG
shared via the Ibox index; ITB readback after ZAP; reads of Abox index 11; MTPR to read-only HIRR;
EXC_ADDR bit 1 correction; PAL_BASE written with low bits set (0x40210); CALL_PAL `0x3b` executed in the SRM
stub prologue while in PALmode on some load paths (srm stub 0x400064, Q3).

---

## 11. RTL plan

Target: Cyclone V 5CSEBA6, **50 MHz** (`clk_sys`), plain Verilog, single-issue, in-order. Correctness
first; the chip's dual issue, branch prediction, BHT, stream buffer and Bcache are left out (all
performance-only per the HRM).

### 11.1 Pipeline

| Stage | Work |
|---|---|
| F | PC select (sequential, branch/jump target, exception vector, HW_REI); I-cache read (index PC[12:5]) and ITB/superpage lookup in parallel |
| D | tag/ASN compare -> hit or I-miss; decode; register file read (M10K, so the read address is presented in F); hazard check |
| E | integer ALU, shifter/byte unit, branch resolution (static predict not-taken, or BTFN by displacement sign: 1-2 bubble taken penalty), address generation, IPR read/write, start multi-cycle units |
| M | D-cache read (index VA[12:5] = PA[12:5], so the RAM read overlaps the DTB lookup), DTB/superpage, protection, alignment, tag compare, store to write buffer, D-miss/uncached -> BIU |
| W | writeback, exception commit (oldest first), EXC_ADDR/VA/MM_CSR capture, redirect to PAL entry |

Full bypassing E->E and M->E; a load-use costs one bubble. Multi-cycle units (multiplier, FP ops, FP
divide) stall the pipe in E until done, which keeps all traps precise.

### 11.2 Modules (`rtl/cpu/`)

| Module | Contents |
|---|---|
| `ev4_core.v` | top: pipeline registers, PALmode, hazard/stall/flush, exception priority and PAL dispatch, CALL_PAL decode, HW_REI |
| `ev4_decode.v` | instruction classes, OPCDEC/FEN detection, operand selects |
| `ev4_regfile.v` | 32x64 2R1W: two M10K copies (64 bits = 2 x 32-bit ports each); R31 forced 0. Same module for F registers |
| `ev4_alu.v` | add/sub/scaled, compares, CMPBGE, logic, CMOV condition, /V overflow |
| `ev4_shift.v` | 64-bit barrel shifter shared by SLL/SRL/SRA and the byte unit (EXT/INS/MSK/ZAP/ZAPNOT: byte shift + byte mask) |
| `ev4_mul.v` | iterative multiplier: a 64x16 partial product per cycle (four 18x18 DSP multipliers) with a 128-bit accumulator: MULL 2 cycles, MULQ/UMULH 4-5 cycles; signed-overflow detect for /V |
| `ev4_ibox_ipr.v` | ICCSR, EXC_ADDR, PS, EXC_SUM + 64-bit write mask, PAL_BASE, HIRR/SIRR/ASTRR/HIER/SIER/ASTER, SL_*, interrupt request logic, performance counters |
| `ev4_abox_ipr.v` | TB_CTL, MM_CSR/VA with lock, ABOX_CTL, ALT_MODE, CC/CC_CTL, BIU_CTL, BIU_STAT/BIU_ADDR, DC_STAT, FILL_* (0) |
| `ev4_paltemp.v` | 32x64 (MLAB or M10K) |
| `ev4_itb.v` | 8+4 entry CAM, NLU/round-robin pointers, superpage MAP, read path into ITB_PTE_TEMP |
| `ev4_dtb.v` | 32-entry CAM with per-entry GH masks, SPE_1/SPE_2, protection check, DTBIS/ASM/ZAP, readback into DTB_PTE_TEMP |
| `ev4_icache.v` | 256 x 32 B data (M10K, 2048 x 32), tags 256 x 29 (tag 21, V, ASM, ASN 6), FLUSH_IC/FLUSH_IC_ASM (valid bits in flops for single-cycle flush), SROM preload sequencer |
| `ev4_dcache.v` | 256 x 32 B data (1024 x 64 M10K), tags 256 x 22, write-through, read-allocate, invalidate port, DC_ENA flush |
| `ev4_wbuf.v` | store FIFO (4 x 32 B, LW masks), merge-at-tail, drain for MB/STx_C/loads |
| `ev4_biu.v` | arbiter (D-fill > I-fill > write buffer, HRM 2.5.2), system bus master, error latching, MCHK request |
| `ev4_fpu.v` | FP control: decode qualifiers, FEN/OPCDEC, FPCR, trap generation, EXC_SUM bits |
| `ev4_fp_add.v`, `ev4_fp_mul.v`, `ev4_fp_div.v`, `ev4_fp_cvt.v` | common unpacked format (sign, 13-bit exponent, 64-bit significand) shared by S/T/F/G/D; rounding unit shared; multiplier 53x53 from four 27x27 DSP blocks over 2 cycles; divider radix-4 SRT, ~30 cycles T/G, ~15 S/F; converts and compares through the adder's normaliser |

Keeping the 64-bit datapath affordable: one adder and one shifter shared by all integer ops; register files
in M10K (8 blocks total); no dual issue (halves forwarding and register ports); iterative multiplier and
divider on DSP blocks; TB CAMs in ALMs (DTB: 32 x 30-bit masked compares, about 1 k ALMs; ITB small);
caches in M10K (I: ~8+1, D: ~8+1 blocks); the FP unit can start as multi-cycle, unpipelined units (6-10
cycles per op) because the firmware only times with RPCC. Size estimate (unverified, to be measured on the
first fit): 12-20 k ALMs, ~40 M10K, ~12 DSP.

### 11.3 System interface

Transaction-level version of the pin bus (HRM Tables 6-4, 6-5), so the 21071-CA model maps onto it 1:1.
All signals synchronous to `clk`.

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| `bus_req` | out | 1 | request valid, held until `bus_gnt` |
| `bus_cmd` | out | 3 | 0 IDLE, 1 BARRIER, 2 FETCH, 3 FETCH_M, 4 READ_BLOCK, 5 WRITE_BLOCK, 6 LDx_L, 7 STx_C (cReq_h codes) |
| `bus_istream` | out | 1 | READ_BLOCK is an I-cache fill (or SROM-less fetch) |
| `bus_addr` | out | 34 | PA[33:3]: block [33:5] plus the requested quadword [4:3] (sparse-space decode needs it) |
| `bus_lwmask` | out | 8 | longword write mask (cWMask) for WRITE_BLOCK/STx_C; for reads, the longwords the load needs |
| `bus_wdata`, `bus_wvalid`, `bus_wready` | out/out/in | 64/1/1 | 4 write beats, lowest address first |
| `bus_rdata`, `bus_rvalid` | in | 64/1 | read beats, lowest address first (SYS_WRAP = 0 order); a non-cached read may return only the needed beat(s) |
| `bus_rcache` | in | 1 | dRAck OK (1) vs OK_NCACHE (0): may this fill be cached |
| `bus_ack`, `bus_ack_code` | in | 1/2 | end of transaction: 0 OK, 1 HARD_ERROR, 2 SOFT_ERROR, 3 STx_C_FAIL (cAck_h) |
| `dinv_req`, `dinv_idx` | in | 1/8 | invalidate D-cache block at index PA[12:5] (dInvReq_h/iAdr_h) |
| `irq` | in | 6 | irq_h[5:0], asynchronous, level |
| `icmode` | in | 1 | 0 = preload I-cache from the SROM port, 1 = none |
| `srom_addr`, `srom_data` | out/in | 10/64 | 8 KB preload port (1-cycle BRAM latency) |
| `sl_xmit` | out | 1 | SL_XMIT[TMT] (sRomClk_h) |
| `sl_rcv` | in | 1 | sRomD_h (SL_RCV[RCV], SLR on change) |
| `biu_ctl` | out | 45 | BIU_CTL contents for the system |
| `reset_n`, `clk` | in | | |
| `dbg_*` | out | | retire trace for lockstep (PC, instruction, register write, store), simulation only |

Rules: the CPU issues one transaction at a time (D-fill, then I-fill, then write buffer); HARD_ERROR on a
read sets BIU_HERR/BIU_ADDR/BIU_CMD and raises MCHK if ABOX_CTL[MCHK_EN]; SOFT_ERROR sets BIU_SERR and CRR if
CRD_EN. Reads of PA[33] = 1 are always non-cached. MB waits for the write buffer to drain and then issues
BARRIER and waits for its ack.

### 11.4 Verification hooks

`dbg_*` trace in the `alphaemu -T` format (`<pc> <insn> [r<n>=<v>] [m<addr>=<v>/<size>]`); a
simulation-only "tohost" store address for T0 pass/fail; SL_XMIT decoded by the testbench as a serial
line, so DROM output on the SROM port shows up in simulation.

---

## 12. Open questions

| # | Question | Source state | Our choice until resolved |
|---|---|---|---|
| Q1 | Where does the AS200 SROM load the DROM (PAL_BASE for the DROM)? | DROM is position-independent; PAL_BASE = load + 0x40 (MCHK at image 0x60); not stated anywhere | Our init code picks a 16 KB-aligned address above the parameter block and below 1 MB, e.g. PAL_BASE 0x000F0000-ish; to fix with the SROM-replacement design |
| Q2 | What else does the DROM expect from the SROM: PAL_TEMP values besides 2/14/18, 21071 CSR state, low-memory words other than section 1.3? | Partly visible in the DROM listing | Trace the DROM in alphaemu with a stub SROM and record every read of uninitialised state |
| Q3 | CALL_PAL executed in PALmode: is EXC_ADDR[0] set? Is it even legal? (SRM stub executes `call_pal 0x3b` on some paths) | HRM silent; MAME sets bit 0 | Dispatch normally, EXC_ADDR = PC+4 with bit 0 = PALmode |
| Q4 | IEEE rounding +/- infinity: hardware or FEN? Table 4-1/2.6 vs Table 3-3 | Contradiction in the HRM; no ARM waiver for it | Hardware (superset) |
| Q5 | EXC_SUM write-mask read order: first read = F31 or F0? | HRM "order F31-F0 then I31-I0" | **Settled (2026-11-03)**: first read F31, a shift register that a write does not reset. NT 4.0's ARITH PALcode reads once, writes, then 31 reads as F30..F0; a pointer reset by the write shifted every register by one (TSE 4.0's STOP 0x3B) |
| Q6 | Abox IPR index 11, read in every SRM/ARC error-unlock sequence | Not in Table 4-7 | Reads 0, no effect |
| Q7 | AMASK/IMPLVER on the real 21064 | Not in our ARM or HRM; Linux executes them | AMASK returns Rb, IMPLVER returns 0 |
| Q8 | Non-canonical I-stream VA | Not described | ITB_ACV |
| Q9 | Superpage "kernel only" for HW_LD/ST with ALT: PS.CM or ALT_MODE? Non-kernel superpage access: ACV or normal DTB lookup? | Not described | ALT_MODE when ALT; non-kernel falls through to the DTB |
| Q10 | I-cache ASN/ASM handling for PALmode fills/fetches | Not described | ASM = 1 on PALmode fills, ASN ignored in PALmode |
| Q11 | (Resolved 2026-11-01: the target is the 4/100; DROM V1.7 knows 100 MHz, and the SROM writes speed code 9 at PA 0x70.) Cycle-time reporting at 50 MHz: DROM V1.2's table has no entry below 166 MHz, so calibration reports 6000 ps. Do SRM/ARC/OSes re-measure (TOY) or trust a2/0x10? | DROM listing; console behaviour unknown | Init code writes PA 0x70 = 2 and the real cycle time (20000 ps) to skip the table; check what SRM's `show config`/OS timekeeping use |
| Q12 | State left by an arithmetic trap / MCHK in the destination register (e.g. a load hit by HARD_ERROR) | UNPREDICTABLE / not described | Arithmetic: result as section 8.4; MCHK load: destination unchanged |
| Q13 | Does HW_REI or an exception clear intr_flag? | ARM: cleared by CALL_PAL REI (PALcode's job) | Only RS/RC change it |
| Q14 | Is the VMS ICCSR probe (write bit 1, read bit 3) detecting a 21064 pass or the 21064A? | VMS code only | RAZ, which leads VMS down its PAL_TEMP2-bit-1-clear path |
| Q15 | 21071-CA behaviour the CPU relies on: does it answer non-existent memory/PCI master abort with HARD_ERROR (MCHK) or with data plus IRQ0? Do firmware probes depend on machine checks? | 21071 data sheet, not yet read for this | Bus supports both; decide in the 21071 design |
| Q16 | EMD_EN for quadword references (invert PA[2] would misalign them) | HRM says "all D-stream references" | Not implemented (no firmware sets it) |
| Q17 | Exact semantics of MFPR with several select bits | Not specified, unused | PAL > Abox > Ibox |
| Q18 | Does FETCH/FETCH_M on the chip take DTB misses (PALcode skips them via MM_CSR opcode 0x18)? | HRM 4.7.1.2 implies yes | No-op, never faults |
