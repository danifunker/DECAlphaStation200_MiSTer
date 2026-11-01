# MiSTer core: locked hardware configuration

Target machine: **DEC AlphaStation 200 4/100** ("Mustang"; the firmware's "Avanti" platform), as documented in `docs/HARDWARE.md`.
(Changed from the 4/166 by the user on 2026-11-01: the 4/100's 100 MHz 21064 matches the core's clock target.)
This file is the authoritative feature set for the core. Change it deliberately and record why.

## Fixed configuration

| Area | Locked choice | Notes |
|---|---|---|
| CPU | **DECchip 21064 (EV4)**, 8 KB I-cache + 8 KB D-cache, no BWX | The 4/100 part (100 MHz). The 21064A (4/233, 16 KB + 16 KB) is a possible later variant; the firmware supports both |
| CPU clock | **100 MHz target** (the 4/100's own speed), pipelined CPU and FPU with caches (user, 2026-11-01) | The init code reports the real cycle time to the DROM (PA 0x70 = 2, PA 0x10 = 10000 ps, PA 0x68 = 100): DROM V1.2's speed table only knows 166-266 MHz (`docs/design/cpu.md` Q11) |
| Core logic | 21071-AA: 21071-CA cache/memory controller, 2× 21071-BA data path, 21071-DA PCI bridge (CSRs at `1.8000.0000` / `1.A000.0000`) | Includes the PCI scatter/gather TLB and sparse/dense spaces |
| Bcache | Architecturally 512 KB, direct-mapped, 32-byte lines | Invisible to software except for diagnostics. The implementation may be smaller or omitted, as long as the 21071-CA and BIU_CTL behave consistently |
| **Main memory** | **OSD option: 32 MB / 64 MB / 128 MB** (default 64 MB) | Bank layout below. 128 MB is the maximum this core supports (the real machine reaches 384 MB) |
| Flash | 1 MB flashbus image, **default = SRM v7.0-9 + ARC 4.58 as real programmed chips** (archive.org `alpha-station-200-roms`, E13/E19/E33/E46, 2026-11-01): they equal the update-package images byte for byte plus DEC's trailing check bytes, so the check-byte question no longer blocks them | The dumped board's SRM v6.4-1 + ARC 4.49 (`scratch/roms/flash/as200_flash_1MB.bin`) stays as an alternative ROM |
| DROM | **V1.7** (`AVANTI_E47_DROM1.7.bin`, 64 KB) | Its speed table knows 100 and 133 MHz (V1.2 stops at 166), and anything below the 133 MHz window is a 4/100: 10000 ps |
| NVRAM | 8 KB on the flashbus, persisted to SD | Holds console environment variables |
| SROM | **The original SROM**: E23, a **Xilinx XC1765D** 64 Kbit serial PROM (PLCC-20; seen on the archive.org board photo). Not dumped anywhere public (searched 2026-11-01). It can be read with a microcontroller clocking CLK with CE active, or a programmer with XC17xx support; the core will load such a bitstream into the I-cache the way the 21064 does. Until one exists: **replacement init code** in the same bitstream format | User, 2026-11-01: bake the original into a file or the core's ROM |
| PCI-ISA bridge | Intel 82378IB SIO (8259 ×2, 8237 ×2, 8254, NMI, PIRQ routing) | IDSEL AD18 |
| Super I/O | National PC87332: COM1, COM2, parallel, FDC | |
| Keyboard/mouse | 8242-compatible controller, PS/2 from MiSTer | |
| TOY clock | BQ4285 (MC146818-compatible) with periodic interrupt to **CPU IRQ4** | Seeded from the MiSTer RTC, with an OSD option to override the year (e.g. 1999 for the NT 5 RC1 time-bomb) |
| **Video** | **ZLXp-E1: DECchip 21030 (TGA), 8-plane, 2 MB, in PCI slot 1** (IDSEL AD23, INTA→PIRQ1) | Bt485 RAMDAC (per Linux `tgafb`; to confirm). Default mode **1024×768 @ 60 Hz** (the real card selects modes with DIP switches) |
| SCSI | NCR 53C810, on board (IDSEL AD17, PIRQ3) | SD-card images: HDD at ID 0 (`dka0`), HDD at ID 1 (`dka100`), CD-ROM at ID 4 (`dka400`) |
| Floppy | 3.5" 1.44 MB as drive A (`dva0`), image file | Also used for firmware updates and DROM floppy boot (J2) |
| Ethernet | DECchip 21040 on the riser (IDSEL AD22, PIRQ0), with Ethernet ID ROM | Lower priority. Can be stubbed so the device is present but has no link |
| Audio | AS200 sound card: AD1848 (WSS, base 530h) + OPL3 at 388h | Lower priority |
| Speaker | 8254 counter 2 to the audio mix | |
| Serial console | COM1 routed to the MiSTer UART/USB serial | First bring-up path: SRM works fully over serial |
| Jumpers (OSD) | J1 SROM mini-console off, J2 floppy boot off, J3 = reset, J6 = flash write enabled | |

### Memory bank layout (21071-CA banks 0–2)
Only identical, non-split banks are used, to keep the memory controller model simple.

| Option | Bank 0 | Bank 1 | Bank 2 | Equivalent SIMMs |
|---|---|---|---|---|
| 32 MB | 32 MB @ 0x0000000 | — | — | 2× 16 MB (4Mx36) |
| 64 MB | 32 MB @ 0x0000000 | 32 MB @ 0x2000000 | — | 4× 16 MB (4Mx36) |
| 128 MB | 128 MB @ 0x0000000 | — | — | 2× 64 MB (16Mx36) |

All three fit the MiSTer SDRAM module (128 MB board recommended), so DDR3 is not needed.

### Not included
TGA2/PowerStorm, S3/VGA cards, more PCI or ISA cards, a second PCI slot device, power management, ECC/parity error injection, and the 21064A.

## OS targets this configuration covers
| OS | Console | Notes |
|---|---|---|
| SRM console itself | SRM | Over serial first, then TGA |
| NetBSD/alpha, Linux/alpha | SRM | Open source, so easiest for debugging the core |
| Digital UNIX 4.0F/4.0G | SRM | Needs correct PCI scatter/gather and IRQ4 timer |
| OpenVMS 6.2–7.2 | SRM | |
| Windows NT 3.51 / 4.0 | ARC 4.49 | TGA driver in the box |
| Windows 2000 RC1 (2072) | ARC (RC1 asks for the latest firmware, 4.58) | 64–128 MB. Beta 2 checked build for debugging |

## Open items
1. **SROM replacement:** write init code equivalent to the SROM. Reference: 21064 HRM SROM interface chapter, AS200 manual §8, the EB64+ guide (`scratch/refs/ec-n0640-72`), and what the DROM expects in low memory (early on it reads physical `0x70` and stores the measured cycle count at `0x110`).
2. **Flash check bytes (resolved 2026-11-01 by the real v7.0 chip images):** E19 and E46 each end in a single non-FF byte (0x81, 0x52) that is not a simple 8-bit sum or XOR. The update utility (`scratch/disasm/apu_v7.0_update_utility.dis.txt`) writes flash and should show whether a checksum is needed before using the v7.0 images.
3. Confirm the ZLXp-E1 RAMDAC and clock generator against the card manual (EK-T2424-OG) and Linux `tgafb`.
