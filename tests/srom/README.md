# SROM tests

The replacement SROM (`srom/avanti_srom.S`, design in `docs/design/srom.md`) and the bitstream
tool (`tools/srom/srom.py`).

| Test | Needs | Checks |
|---|---|---|
| `make -C srom check` | binutils | EV4-only opcodes (`tests/cpu/check_ev4.py`), size <= 7136 bytes (XC1765D), encode -> decode round trip, check byte |
| `python3 -I tests/srom/check_format.py` | `scratch/roms/dec3000_m800_srom6.1` | The bitstream format against DEC's own SROM (see below) |
| `tests/srom/emu_smoke.sh` | `build/alphaemu`, DROM V1.7 in `scratch/` | Control flow on alphaemu -P: LED sequence, DROM copy and checksum, parameter block, flush stub, HW_REI into the DROM |

## check_format.py: the DEC 3000 M800 SROM V6.1

The 27C512 (`full-srom.bin`) holds eight 21064 bitstreams, bit i of every byte = stream i. For each
stream: `deinterleave` gives DEC's `bitstreams/srom<i>-bitstream.bin`, `decode` gives DEC's
`images/srom<i>-image.bin` byte for byte, and `encode(decode(stream))` gives back **the whole
65,536-bit stream**. That means DEC's layout is exactly what `encode` writes: V=1, ASM=1, TAG=0,
ASN=0, BHT=0 blocks, then V=0 all-zero blocks, a zero tail, and the check byte in the last byte. The
check byte is `c = rotl8(c, 1) + byte` over bytes 0..8190. It matches all eight streams.

## emu_smoke.sh: what it does and does not prove

alphaemu has flat memory and no 21071. The CSR writes land in plain memory, the sizing sees no
aliasing (every bank looks like 128 MB, 384 MB in total), and the flashbus is replaced by a RAM copy
of the DROM (`-DTEST_FLASH_RAM`, which changes only `fbrd`). `-DZERO_BASE=0x2000` keeps the zeroing
off the code, because alphaemu fetches from memory and the real chip fetches from the I-cache. So the
script proves the control flow, the checksum and header code against the real DROM V1.7, the
parameter-block layout and the hand-off. It does not test any 21071 behaviour. About 2.4 M
instructions run before the hand-off. The DROM then reads PA 0x70 = 9, skips its calibration and
writes its own LED codes (0x20, 0x21, ...).

## The system simulation (when the CPU, 21071-CA and flashbus RTL exist)

Run the core from reset with `icmode = 0` and `srom/build/avanti_srom.hex` as the SROM ROM, for each
memory option, and check:

1. **LED register** (flashbus offset 14.0000; write index `0x9400_0000`, then data): exactly
   `FF FE FD FC FB FA F9 F8 F7 F6 F3 F1 F0`, then the DROM's codes. Stuck at `FD` means sizing found
   less than 2 MB. Stuck at `F2` means the DROM header or checksum failed (PAL_TEMP0 = computed sum,
   PAL_TEMP1 = stored byte). `F5` is an unexpected exception (PAL_TEMP0 = EXC_ADDR, PAL_TEMP1 = PAL
   offset). A test failure leaves the LED at the test's code and puts the failing address in
   PAL_TEMP0.
2. **21071-CA bank CSRs** after F0:

   | Option | BASE0 / CNFG0 | BASE1 / CNFG1 | BASE2 / CNFG2 |
   |---|---|---|---|
   | 32 MB | 0x0000 / 0x004B | - / 0 | - / 0 |
   | 64 MB | 0x0000 / 0x004B | 0x0080 / 0x004B | - / 0 |
   | 128 MB | 0x0000 / 0x0007 | - / 0 | - / 0 |

   Also BASE8 = 0x4000, CNFG8 = 0x0137, GTR = 0x11, RTR = 0x412, TAGEN = 0x1FF8, GCR = 0x20.
   Timing A/B of each probed bank are 0x2695/0x1352.
3. **Parameter block** (PA, quadwords): 0x00 = 0, 0x08 = size in bytes (0x200_0000 / 0x400_0000 /
   0x800_0000), 0x10 = 10000, 0x18 = 0xDECB_0000, 0x20 = 1, 0x28 = 0, 0x30 = 0, 0x38 = size in MB
   (32/64/128), 0x40-0x60 = 0, 0x68 = 100, 0x70 = 9 (2 with `-DDROM_CALIBRATE`), 0x110 = 0. The DROM
   overwrites 0x50 ("V1.7") at its own hand-off.
4. **DROM copy**: PA 0x3FFC0..0x4FFBF equals `boot1.rom` (DROM V1.7) byte for byte. Its check byte:
   `c = rotl8(c + byte, 1)` over bytes 0..0xFFFE = byte 0xFFFF (0xF7 for V1.7, 0xDB for V1.2). The
   SROM computes this itself and stops at F2 if it differs.
5. **Flush stub** at PA 0x4FFC0: `74000024 77ff0055 47ff041f x5 7bff8000`. Retire trace: HW_REI to
   0x4FFC0 in PALmode, FLUSH_IC, HW_REI to 0x40000 with PAL_BASE = 0x40000, then the DROM's
   `mb; mb; FLUSH_IC` at 0x4007C.
6. **IPR state at DROM entry**: PAL_TEMP18 = BIU_CTL = 0x0000_000E_2000_6335 (0x...6334 with
   `-DBCACHE=0`), PAL_TEMP14 = ABOX_CTL = 0x400, PAL_TEMP2 = ICCSR (write format) = 0x0000_04F8_0000_0000,
   r1 = 0x400, r2 = BIU_CTL, r17 = size, r18 = 10000, r19 = 0xDECB0000, r20 = 1, r21 = 0.
7. **Then the DROM**: it ORs MCHK_EN into ABOX_CTL, skips its calibration (PA 0x70 != 2), zeroes
   2 MB..top, and runs POST. Its next LED codes are its own (TI Table 8-3).

**Run time**: about 2.4 M instructions. Roughly 1.6 M of them are the DROM copy: 65,536 flashbus byte
reads, each an index write, an index read-back and a data read. The low-2 MB zeroing is 64 K
iterations of four stores.
