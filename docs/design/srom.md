# Replacement SROM: design

The AS200 4/100's own SROM is not dumped (`docs/CORE_SPEC.md`: a Xilinx XC1765D at E23). Until
someone reads one, the core loads **our code**, in the chip's own SROM format, into the 21064
I-cache at reset (`docs/design/cpu.md` 1.4, option A). A real dump can replace it file for file.

| File | What |
|---|---|
| `srom/avanti_srom.S`, `srom/Makefile` | The code (`make -C srom`, `make -C srom check`) |
| `srom/build/avanti_srom.bin` | I-cache image, 6120 bytes, PA 0 upward |
| `srom/build/avanti_srom.bitstream` | The same, as an XC1765D bitstream (65,536 bits) |
| `srom/build/avanti_srom.hex` | `$readmemh`: 1024 little-endian 64-bit words (word k = bytes 8k..8k+7), for the `srom_addr`/`srom_data` port (cpu.md 11.3) |
| `tools/srom/srom.py` | Bitstream `decode` / `encode` / `deinterleave` / `checksum` / `hex` |
| `tests/srom/` | Format check against DEC's SROM, alphaemu smoke run, system-simulation expectations |

The three build products are committed (`git add -f`, since `build/` is ignored), so the RTL does
not need the Alpha toolchain.

## Sources

| Tag | Document | Local copy |
|---|---|---|
| HRM | 21064 Hardware Reference Manual | `scratch/refs/ec-q9zua-te.*` |
| TI | AlphaStation 200/400 Technical Information, ch. 4 (flashbus), ch. 8 (SROM) | `scratch/refs/ek-pcdsa-ti.txt` |
| 21071 | 21071/21072 data sheet, ch. 4 (21071-CA), ch. 10 (21071-DA) | `scratch/refs/ec-qaema-te.pdf` |
| EB64+ | EB64+ user's guide, App. B | `scratch/refs/ec-n0640-72.pdf` |
| PC64 | AlphaPC64 user's guide, App. B, Table B-1 | `scratch/refs/pc64_users_gde.txt` |
| SDK | DEC evaluation-board SDK: `ebtools/src/common/srom/srom.c` (DEC's packer), `ebfw/lib/eb64pmem.c` (bank size decode), `sw/apisrm/ref/apecs_def.sdl` (21071 CSRs), `avanti.sdl` | `scratch/ebsdk/` |
| DROM | DROM V1.7 (`AVANTI_E47_DROM1.7.bin`), our own disassembly; V1.2 listing | `scratch/roms/archive_alpha-station-200-roms/`, `scratch/disasm/drom_v1.2.dis.txt` |
| DEC3000 | DEC 3000 M800 SROM V6.1 image 0 (DEC's own EV4 init) | `scratch/roms/dec3000_m800_srom6.1/disassembly/srom0-asm.txt` |

DROM addresses below are **image offsets** (the V1.7 code at offset 0x40 runs at PA 0x40000).

## 1. Bitstream format

Per 32-byte block, LSB first: LW0, LW2, LW4, LW6 (32 bits each), TAG 21, ASN 6, ASM 1, V 1, LW1,
LW3, LW5, LW7, BHT 8: 293 bits (TI 8 "Loading the SROM Code"; HRM Table 6-21; SDK `srom.c`
`codeToEv4()`). Bit 0 of byte 0 shifts in first.

- **Size.** The chip shifts 256 blocks (75,008 bits). The XC1765D holds **65,536 bits**: 223 whole
  blocks = **7136 bytes** of code (TI: "the size of the loaded program is therefore 7136 bytes"),
  plus 197 bits of the 224th block. Code must end by PA 0x1BE0. Blocks 223-255 get whatever the part
  drives after its end; it must not look like V=1 with TAG 0.
- **Padding** (what `encode` writes, and what DEC wrote): the image's blocks have V=1, ASM=1,
  TAG=0, ASN=0, BHT=0. A partial last block is padded with 0x00000000 longwords (DEC's `srom.c` pads
  the same way). Then come all-zero blocks (V=0) up to the end of the part, a zero tail, and the
  **check byte** in the last byte.
- **Check byte**: `c = 0; for each byte b of bytes 0 .. N-2: c = rotl8(c, 1) + b (mod 256)`. It
  equals the last byte of all eight DEC 3000 V6.1 streams (cetus.sh's description, confirmed on the
  dump by `tests/srom/check_format.py`). It sits beyond the last whole block, so the chip never loads
  it. Whether the AS200 part carries one is unknown. Writing it costs nothing.
- **Verification**: `full-srom.bin` -> `deinterleave` -> `decode` reproduces DEC's eight images byte
  for byte, and `encode(decode(stream))` reproduces each **whole** stream bit for bit.
- **The RTL** loads 8 KB (1024 words). Our image uses 192 blocks; the rest of the hex is zero. A real
  dump decoded with `srom.py decode` gives the same kind of image.

## 2. What the code does, step by step

PALmode from PA 0, I-stream from the I-cache. In PALmode the D-stream is translated (cpu.md 6.4), so
every memory and CSR access is `hw_ldl/p`, `hw_ldq/p`, `hw_stl/p` or `hw_stq/p`. **The D-stream cannot
read the code**: there are no data tables, and every constant is built with `lda`/`ldah`/`sll`. The
PAL entry offsets inside the image (0x20 MCHK ... 0x17E0 FEN, cpu.md 5.1) each hold a two-instruction
stub to `trap`. The code fills the gaps between them, as DEC's own SROMs do. `trap` saves EXC_ADDR to
PAL_TEMP0 and the entry offset to PAL_TEMP1, shows LED F5 and spins.

| LED (TI Table 8-1) | Step |
|---|---|
| (power-up) | PA 0: BIU_CTL + PAL_TEMP18 = 0x0000_000E_2000_6334 (Bcache off, OE on) as the very first write (DEC3000 does BIU_CTL first). Then ABOX_CTL + PT14 = 0; ICCSR + PT2 = 0x0000_04F8_0000_0000; PAL_BASE, PS, ASTRR, ASTER, HIER, SIER, SIRR, SL_CLR, TB_CTL, ALT_MODE, EXC_SUM = 0; ITBZAP+DTBZAP; BC_TAG write; VA, BIU_ADDR, FILL_ADDR reads (unlock); CC = 0, CC_CTL = 1<<32. Bank 8 = flashbus: BASE8, CNFG8 |
| **FF** | CPU initialised. The latch probably shows FF from power-up anyway, because it can only be written once bank 8 works. We write FF explicitly |
| **FE** | Bank 8 done. GTR, RTR; banks 0-2 invalid; **sizing** of banks 0, 1, 2 (section 4) |
| **FD** | Sizing done. Banks placed largest first (section 4). Fewer than 2 MB: spin at FD (beep 1-3-3 is not implemented) |
| **FC** | Bcache: TAGEN, GCR. There is no Bcache RAM to sweep (CORE_SPEC: "may be smaller or omitted"), so the EB64+ B.1.7 sweep is skipped |
| **FB** | Bcache and D-cache off. Zero PA 0..2 MB (`ZERO_TOP`); memory test 1 |
| **FA** | Bcache on (BIU_CTL[BC_ENA] + PT18), D-cache off: test 2 |
| **F9** | Bcache off, D-cache on (ABOX_CTL + PT14 = 0x400): test 3 |
| **F8** | Both on: test 4 |
| **F7** | Tests done |
| **F6** | Core logic: 21071-CA EDSR clear; 21071-DA DCSR clear, TBR1/2, PBR1/2 (windows off), PMR1/2, HAXR1/2 = 0 |
| (F5, F4) | Reserved in TI; not written. F5 is our unexpected-exception code |
| **F3** | Copy the DROM: 65,536 byte reads through the flashbus (offset 18.0000 + k), packed into quadwords, stored at **PA 0x3FFC0**; checksum on the fly |
| **F2** | Header or checksum bad: spin (beep 1-1-4 and the console-from-flash fallback via TOY NVRAM are not implemented) |
| **F1** | DROM good |
| **F0** | Parameter block (section 5), flush stub, PAL_BASE = 0x40000, EXC_ADDR = stub \| 1, HW_REI |

The **memory tests** are sparse, one quadword every 64 KB across all memory: write `addr ^ pattern`,
read it all back, then write 0. The patterns are 0, 0x55555555, 0x33333333 and all ones. A failure
leaves the LED at the test's code and puts the address in PAL_TEMP0. The real SROM tests the low 8 MB
fully (TI); a full test is pointless on SDRAM and slow in simulation. **Zeroing** covers PA 0..2 MB,
because the DROM zeroes 2 MB..top itself (V1.7 0x23cc-0x23f0: from PA[0x38] << 20 down to
0x200000).

**DROM checks** (TI 8 "Leaving the SROM Code": header and checksum). The header's first quadword must
be 0xFFAA0055_00000101: longwords 0x00000101 and 0xFFAA0055, as in every AS200 ROM header,
`docs/FIRMWARE_DISASM.md`. The checksum is `c = rotl8(c + b, 1)` over bytes 0..0xFFFE and must equal
byte 0xFFFF. **Found here**: this matches DROM V1.7 (0xF7) and V1.2 (0xDB). It is add-then-rotate,
not the DEC 3000 SROM's rotate-then-add. Neither form gives the flash chips' trailing bytes per chip
(as with CORE_SPEC item 2), but over E13+E19 as one 512 KB image add-then-rotate gives 0xA2 against a
stored 0xA1. That is close enough to be worth a look.

**Hand-off.** The flush stub follows EB64+ B.1.9: you cannot flush the I-cache while running from
it. We write 8 longwords at PA 0x4FFC0, right after the DROM image:
`hw_mtpr/i r0,EXC_ADDR; hw_mtpr/a r31,FLUSH_IC; 5 x nop; hw_rei`. Then PAL_BASE = 0x40000, r0 =
0x40001, EXC_ADDR = 0x4FFC1, `hw_rei`. The stub's I-cache index (0x1FC0) is beyond our blocks, and
its tag is not 0, so it is fetched from memory. It flushes, then HW_REIs to the DROM in PALmode with
EXC_ADDR = 0x40001. Registers at DROM entry follow PC64 Table B-1: r1 = ABOX_CTL, r2 = BIU_CTL,
r17 = memory size, r18 = 10000, r19 = 0xDECB0000, r20 = 1, r21 = 0. The DROM does not read them: it
reads the PAL_TEMPs and the parameter block. Both DROMs flush the I-cache again at their own entry
(`mb; mb; FLUSH_IC` x2 at 0xbc).

**J1 (SROM mini-console): not implemented.** The DROM reads the same jumper register (flashbus
1C.0000) and branches on bit 0 (V1.7 0x440-0x450: clear -> its own console) and bit 1 (0x454-0x45c:
clear -> floppy loader, set -> flash loader). So **bit 0 = J1** and **bit 1 = J2**, 1 = normal
(inferred from the listing, not stated by TI). With J1 set, our SROM still loads the DROM, and the
DROM enters its own console. The SROM serial port (SL_XMIT) progress output that TI mentions is not
implemented either; the LEDs are the only progress output.

## 3. CPU register values

| Register | Value | Why |
|---|---|---|
| **BIU_CTL** (+PT18) | **0x0000_000E_2000_6335** final; ...6334 while the Bcache is off (FB, F9) and with `-DBCACHE=0` | BC_ENA (0) = 1: the real machine leaves the 512 KB Bcache on (TI F8: "Bcache references ON"). ECC (1) = 0: parity. **OE (2) = 1**: PC64 B-1 says it must be set or the part can be damaged. BC_RD_SPD (7:4) = 3, BC_WR_SPD (11:8) = 3, BC_WE_CTL[2:1] (14:13) = 11: **DROM V1.7's own 100 MHz value** (`0x6330`, 0x320-0x350, merged into BIU_CTL[23:4] at 0x354-0x37c). BC_SIZE (30:28) = 010 = 512 KB (HRM Table 5-13; HARDWARE.md). BC_PA_DIS (35:32) = 1110: no Bcache for PA[33:32] = 1, 2, 3 (I/O, PCI). Our CPU does not model the Bcache (cpu.md 4.3), so this value is for software that reads the shadow (the DROM ORs into it; the console gets it in t1) |
| **ABOX_CTL** (+PT14) | 0 from reset to F9, then **0x400** (DC_ENA) | The D-cache is off for sizing and the first tests, then on (TI F9/F8). MCHK_EN stays clear: the DROM sets it (`or t1,2` at 0xe0). 0x400 is what DEC3000 uses |
| **ICCSR** (+PT2) | **0x0000_04F8_0000_0000** | Write bits FPE 42, DI 39, BHE 38, JSE 37, BPE 36, PIPE 35. HWE stays off: the ARC stub sets it itself. This is the value the ARC PALcode writes. DEC3000 writes 0x5F8 (with HWE) |
| PAL_BASE | 0, then 0x40000 at hand-off | |
| CC_CTL | 1 << 32 | Counter on from 0 (the DROM rewrites it when it calibrates) |

## 4. 21071-CA programming and the memory-size mechanism

CSR addresses (21071 Table 4-1; SDK `apecs_def.sdl`). Longword accesses through `hw_stl/p`. The
bank CSRs sit at 1.8000.0800 + 0x20 n (base), 0xA00 + 0x20 n (config), 0xC00 / 0xE00 + 0x20 n
(timing A/B), n = 0..8.

| CSR | Address | Value | Source |
|---|---|---|---|
| GCR | 1.8000.0000 | 0x20 (bc_En; sysArb 0 = CPU priority) | 21071 Table 4-2 |
| EDSR | 1.8000.0040 | write 0xF (lostErr, bc_TAPErr, bc_TCPErr, nxMErr: RW1C) | 21071 Table 4-3 |
| TAGEN | 1.8000.0060 | 0x1FF8: compare PA<28:19> (512 KB cache, 512 MB cacheable) | 21071 4.2.3 (bit n = tagAdr<16+n>; worked example there) |
| GTR | 1.8000.0200 | 0x11: tRP = 3 cycles (field = value - 2), max RAS width 2 x 128 memClk | 21071 Table 4-11 |
| RTR | 1.8000.0220 | 0x412: ref_Interval 8 (x 64 memClk = 15.4 us at 33 MHz), RAS width 4 (-3), CAS-to-RAS 3 (-2) | 21071 Table 4-12 |
| BASE8 | 1.8000.0900 | 0x4000: bank 8 at **1.0000.0000** (BaseAdr<33:23> in [15:5]) | TI 4: "The base of bank 8 is programmed to noncacheable memory space by SROM code"; 21071 4.3.4 |
| CNFG8 | 1.8000.0B00 | 0x137: valid, s8_Size 1011 = 2 MB, s8_SubEna, ColSel 100, s8_Check 0 | 21071 Table 4-8 |
| TIMA8/B8 | 1.8000.0D00/0F00 | reset values (all ones: slowest) | |
| BASEn | 1.8000.08n0 | (bank base) >> 18 | 21071 Fig. 4-11 |
| CNFGn | 1.8000.0An0 | 0x07 (128 MB), 0x4B (32 MB); also 0x69 (64 MB split), 0xED (16 MB split), 0xCF (8 MB) | 21071 Table 4-7; size decode as in SDK `eb64pmem.c` `banksize()` |
| TIMAn/Bn | 1.8000.0Cn0/0En0 | 0x2695 / 0x1352 | ours (below) |

**Bank 8.** The index register (1.0000.0000) and the data register (1.0010.0000) differ only in
PA<20>. With s8_Size = 2 MB and subbanks on, PA<20> is exactly the subbank select (Table 4-8). We
infer that this is how the board tells the two registers apart. No source says it, so mark it
**(inferred)**. s8_Check = 0 requires a noncacheable base (PA<32> = 1, 21071 4.3.4), which this is.
The core's flashbus decoder may ignore BASE8/CNFG8 and decode the two addresses directly.

**Timing values** are ours: mid-range settings for 70 ns DRAM at a 30 ns sysBus cycle, not DEC's.
The core's memory controller has no use for them (SDRAM behind a model). Only the register state
matters, for software that reads it back.

**Memory size: sizing by probing**, which is what the real SROM does (TI FE "Executing memory sizing
code"; HARDWARE.md 2). For each bank n = 0, 1, 2 alone (the others invalid):

1. Timing A/B, base 0, config = valid, 128 MB, ColSel 12/12 (the largest size we support).
2. Write 0x5A5AA5A5 at PA 0 and its complement at PA 8, then read PA 0. No match means **empty**
   (size 0).
3. For s = 8, 16, 32, 64 MB: write s at PA s, then read PA 0. If PA 0 now reads s, the bank
   **aliases** at s: size = s. No alias up to 64 MB means 128 MB.
4. Config = 0 (invalid) again.

Then for each size class 128, 64, 32, 16, 8 MB, in that order, every bank of that class gets
base = next and the class's config value, and next += size (21071 4.3.4 note and EB64+ B.1.6: the
largest bank lowest, naturally aligned, contiguous). Memory size = next. Split banks (64 MB and 16 MB
from double-sided SIMMs) cannot be told from plain ones by probing. We guess that those sizes are
split, as HARDWARE.md's SIMM table says. The core never uses them.

**What this asks of the 21071-CA model** (to implement in the system RTL):
- A valid bank larger than what is installed behind it **aliases modulo the installed size**. Real
  DRAM does this: the address lines it has no rows or columns for are not connected.
- A valid bank with nothing installed returns data that does not hold a written pattern. All ones is
  what the data-bus pull-ups give. It must **not** raise an error: the bank is valid.
- The OSD option fixes what is installed: 32 MB = bank 0: 32 MB. 64 MB = banks 0 and 1: 32 MB each
  (SDRAM 0 and 32 MB). 128 MB = bank 0: 128 MB. The SROM finds and places them exactly as in the
  CORE_SPEC bank table. The table of expected CSR values is in `tests/srom/README.md`.
- An alternative the real hardware also had: the presence-detect registers (1.8000.0260/0280, which
  hold the SIMM PD pins). We do not use them. A real SROM dump would show which one DEC used.

**21071-DA** (21071 ch. 10; SDK `apecs_def.sdl`): DCSR (1.A000.0000) = 0xFF60. That writes 1 to
every RWC error bit (ioRT 5, lost 6, dDPE..mErr 8-15) and leaves tEnb, pEnb, dCEI and dPEC at 0.
The DROM later writes its own 0xFF6D (V1.7 0x2320-0x233c). TBR1/2, PBR1/2 (WENB = 0: DMA windows
off), PMR1/2 and HAXR1/2 are all set to 0. The console sets the windows up.

## 5. Low-memory parameter block and the DROM load address

| PA | Value | Notes |
|---|---|---|
| 0x00 | 0 | a0 |
| 0x08 | memory size, bytes | a1 (EB64+ B.1.2, PC64 Table B-1) |
| 0x10 | 10000 | a2: ps per RPCC count at 100 MHz |
| 0x18 | 0xDECB_0000 | a3: signature V2, system revision 0 (the AS200's revision value is unknown) |
| 0x20 | 1 | a4: processor mask |
| 0x28 | 0 | a5: system context. The DROM hands the console sp = a5 << 10 (V1.7 0x362c), but both console stubs set their own sp |
| 0x30, 0x40, 0x48 | 0 | t8, t10, t11 |
| **0x38** | **memory size in MB** | t9. **The DROM uses it**: its zeroing loop and memory test use PA[0x38] << 20 as the top of memory (V1.7 0x23cc, 0x3464). This is not in cpu.md 1.3's table |
| 0x50-0x60 | 0 | the DROM writes "V1.7" at 0x50 |
| 0x68 | 100 | CPU MHz: the DROM's SROM-port bit timing (V1.7 0x22e8, 0x3c18) |
| **0x70** | **9** (default) or 2 (`-DDROM_CALIBRATE`) | See below |
| 0x110 | 0 | the DROM's RPCC calibration count |

**PA 0x70 (correction to cpu.md 1.3/Q11 and the CLAUDE.md "Machine" row).** The listings say
**2 makes the DROM calibrate**. It does not skip it:
- V1.2 (0xe8-0xf0): `hw_ldq/p t1,0x70; cmpeq t1,2; beq -> 0x238` means skip unless the value is 2.
- V1.7 (0xe8-0xf8): calibrate if the value is 2 or 8, otherwise skip to 0x38c. After it measures, it
  re-reads 0x70 to pick a table (2: the EV4 table, 300 ... 133 MHz, below that **100 MHz / 10000 ps /
  code 9**; 8: a 300/266 MHz table, likely the 21064A). It then writes 0x10, 0x68, **0x70 = speed
  code**, and BIU_CTL[23:4] + PT18.

So the real SROM very likely writes the **CPU type** at 0x70: 2 = EV4 (`avanti.sdl`:
SLOT$_CPU_TYPE = 2, EV4), and the DROM calibrates. Our default writes **9**, the code V1.7 itself
stores for 100 MHz. Both DROM versions then skip the calibration, with 0x10 = 10000, 0x68 = 100, and
BIU_CTL already holding V1.7's 100 MHz speed bits. This is what CORE_SPEC intends (hand over the real
cycle time), it does not need the SIO 8254 that the calibration times against, and DROM V1.2, which
would misread 100 MHz as 166, works too. `-DDROM_CALIBRATE` gives the probably-real behaviour (2) for
a test of the DROM's own calibration with V1.7.

**DROM load address (Q1): image at PA 0x3FFC0, code (image offset 0x40) at 0x40000 = PAL_BASE.**
The DROM itself says so: its relocation path (V1.7 0x3404-0x3460, V1.2 near 0x32f4) copies its own
code, from flashbus 18.0040, to **PA 0x40000** and enters it with PAL_BASE = 0x40210 (effective
0x40000) and EXC_ADDR = 0x40211. We copy the whole 64 KB, header included, so that the header and
checksum can be checked in memory, and the code lands where the DROM puts itself. Other constraints
it meets:
- PAL_BASE must be 16 KB aligned (PAL_BASE[33:14]).
- Above the parameter block and the I-cache-resident range (0-0x1FFF).
- Below 2 MB: the DROM zeroes 2 MB..top.
- Below 0x100000, where the DROM puts the console stub (PAL_BASE 0x100000 at hand-off, cpu.md 10).

## 6. Assumptions and open questions

| # | Question | Our choice |
|---|---|---|
| S1 | What does the real SROM write at PA 0x70: 2 (CPU type, DROM calibrates) or a speed code? | 9 by default; 2 with `-DDROM_CALIBRATE` |
| S2 | Does the real SROM size memory by aliasing or by the presence-detect registers (1.8000.0260/0280)? | Aliasing; the 21071-CA model must alias (section 4) |
| S3 | Bank 8 decode (2 MB with PA<20> as subbank select) and CNFG8 / timing values | Inferred; the core may decode the flashbus at fixed addresses |
| S4 | Bank timing / GTR / RTR values DEC used | Ours (section 4); unused by the model |
| S5 | System revision at PA 0x18 [15:0]; contents of 0x30/0x40/0x48 | 0 |
| S6 | Bcache: final BIU_CTL with BC_ENA = 1 while the core has no Bcache. If any software then misbehaves (none known: no BC_TAG reads in DROM V1.7), build with `-DBCACHE=0` | On |
| S7 | J1 mini-console, SROM serial-port output, beep codes, console-from-flash fallback on a bad DROM | Not implemented (section 2) |
| S8 | Does the XC1765D carry the DEC 3000 style check byte, and what does it drive after its last bit (blocks 223-255)? | We write the check byte; the RTL preload should treat blocks past the image as invalid, or at least never let them hit |
| S9 | The DROM's other low-memory reads: 0x08, 0x38, 0x68, 0x70 and the a0-at block are now covered (cpu.md Q2). PAL_TEMPs other than 2/14/18, and the 21071 state the DROM tests | Trace the DROM in the system simulation |
| S10 | The flash chips' trailing bytes (CORE_SPEC item 2): add-then-rotate over E13+E19 gives 0xA2 against 0xA1 | Lead only; not needed by the SROM |
