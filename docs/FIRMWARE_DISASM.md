# AlphaStation 200 firmware disassembly

The listings live in `scratch/disasm/` (generated, not in git).

These listings are generated, so don't edit them by hand. To regenerate them, run
`python3 -I tools/disasm_all.py` from the repo root. This needs `brew install binutils`, which provides an objdump that can decode Alpha.

Each image has two files:
- `*.dis.txt`: a linear EV4 disassembly. Addresses are the image's real load address.
- `*.strings.txt`: every printable string of 5 or more characters, with its address.

## Annotations
- **Region banners**: ROM header, decompressor stub, compressed payload, PALcode, console.
- **PAL entry labels**: at each PAL base, using 21064 HRM Tables 4-1 and 4-2 (RESET, MCHK, ARITH,
  INTERRUPT, D_FAULT, ITB/DTB miss, UNALIGN, OPCDEC, FEN, plus the 128 `CALL_PAL_xx` slots).
- **IPR names**: `hw_mfpr`/`hw_mtpr` show the register they touch, from HRM Table 4-7
  (`I:` = Ibox, `A:` = Abox, `PAL_TEMPn`).
- **Constants**: the value of each constant built by an `ldah`/`lda` pair, shown as ASCII when printable.
  This decodes the diagnostic ROM's messages, which it builds in registers. Matches against string
  addresses are marked "(if address)", because a plain number can collide with a string's address
  (1,000,000 = 0xF4240, for example).
- Register names follow OSF/1 software conventions. The header of each file gives the mapping to r0–r31.

Code and data are interleaved, so expect stretches of meaningless "instructions" in data areas.
The SRM and ARC consoles are compiled C/BLISS that reach most data relative to `gp`, so string
references there are rarely resolved. Use the `.strings.txt` addresses together with `ldq`/`lda` from `gp`.

## Images

| Listing | Source | Load address | Notes |
|---|---|---|---|
| `drom_v1.2` | flash dump E47 (TMS27PC512) | ROM offset (load address not yet known) | Diagnostic/POST ROM. Code runs 0x40–0x40B8, then zeros, with a check word at 0xFFFC. Runs in PALmode |
| `srm_v6.4-1_flash_stub` | flash E13+E19 | 0x400000 (file+0x40) | Self-relocating DEFLATE decompressor |
| `srm_v6.4-1` | **decompressed SRM from the dumped board** | 0x8000 | VMS PAL 0x8000, OSF PAL 0x14000, console from ~0x38000 |
| `arc_v4.49_flash_stub` | flash E33 | PA 0x100000 = VA 0x80100000 | Sets up the ITB and superpage, then inflates to PA 0x700000 |
| `arc_v4.49` | **decompressed ARC from the dumped board** | VA 0xFFFFFFFF80700000 (PA 0x700000) | Windows NT ARC console |
| `srm_v6.9-4`, `srm_v7.0-9` (+ `_flash_stub`) | flash images embedded in the DEC update packages | 0x8000 | v7.0-9 is the last SRM |
| `arc_v4.57`, `arc_v4.58` (+ `_flash_stub`) | same | VA 0x80700000 | v4.58 is the last ARC on DEC media |
| `apu_v6.9_update_utility`, `apu_v7.0_update_utility` | `AS200_V6_9.EXE`, `as200_v7_0.exe` | 0x8000 | Firmware update utility. The embedded flash images are skipped (see `scratch/roms/flash/`) |
| `pci_update_v1.4` | `as200_pci_v1_4.exe` | 0x8000 | PCI option-ROM update utility |
| `arcboot`, `arcboot_inner_arc` | `arcboot.exe` | 0x8000 / VA 0x80700000 (assumed) | Loads ARC from disk or floppy |
| `*_exe_stub` | the four `.exe` files | 0x400000 | Their decompressor stubs (identical code) |

## How the images were unpacked
- **Flash layout** (4× 256 KB, flashbus offsets 0x00000/0x40000/0x80000/0xC0000):
  - **E13 + E19**: one SRM image, 0x5C400 bytes. Zero padding follows.
  - **E33**: ARC. Its compressed data runs to 0x3B804. The ROM header's length field (0x3B7C5) is about 0x40 too short, so don't trust it.
  - **E46**: blank, all FF except the last byte.
  - `scratch/roms/flash/as200_flash_1MB.bin` is the four chips concatenated in that order.
- **ROM header** (0x40 bytes): `0x00000101`, `0xFFAA0055`, version[8], "DEC", platform "AVANTI",
  "ALPH", length at +0x2C, name ("AVANTI_SRM", "AVANTI_ARC" or "AVANTI-DROM") at +0x30, `0x11223344`.
- **"WimC" payload**: magic, compressed size, then either raw DEFLATE (ARC) or
  `0, 0, load_address` followed by DEFLATE (SRM and update utilities). `tools/fwextract.py` unpacks these with zlib.
- **Verification**: `tools/alphaemu` runs DEC's own stubs, about 49M instructions for SRM and 30M for ARC.
  Its output is byte-for-byte identical to zlib's output for both SRM 6.4-1 and ARC 4.49.
