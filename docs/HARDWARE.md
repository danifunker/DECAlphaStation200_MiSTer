# DEC AlphaStation 200: Hardware Inventory

> The configuration the core implements is locked in **`docs/CORE_SPEC.md`**. This file describes the real machine.

Reference for building a MiSTer core. Unless marked otherwise, every fact here comes from
**EK-PCDSA-TI, *Digital AlphaStation 200/400 Series Technical Information*, April 1995**
(`scratch/refs/ek-pcdsa-ti.pdf`, extracted text in `scratch/refs/ek-pcdsa-ti.txt`).
Facts that are unverified or come from secondary sources are marked **(unverified)**.

## 1. Models

| Model | CPU | CPU clock | On-chip cache (I/D) | Bcache |
|---|---|---|---|---|
| AlphaStation 200 4/100 | DECchip 21064 (EV4) | 100 MHz | 8 KB / 8 KB | 512 KB |
| AlphaStation 200 4/166 | DECchip 21064 (EV4) | 166 MHz | 8 KB / 8 KB | 512 KB |
| AlphaStation 200 4/233 | DECchip 21064A (EV45) | 233 MHz | 16 KB / 16 KB | 512 KB |

- Codename: the firmware calls the platform **"AVANTI"** (strings `DEC AVANTI`, `AVANTI_SRM`,
  `AVANTI_ARC` and `AVANTI-DROM` appear in the ROM dumps). Wikipedia uses "Mustang" for the
  200 and "Avanti" for the 400 **(unverified)**. One firmware image covers the AS200 and AS250.
- The CPU receives a 2x clock (333 MHz for the 4/166) and divides it by 2 internally.
- The AS400 is the same core design in a deskside case with a CPU module. Linux, NetBSD and
  OpenBSD treat the 200, 250 and 400 as a single platform.

## 2. Chip-level bill of materials

### CPU and core logic
| Function | Part | Bus | Notes |
|---|---|---|---|
| CPU | DECchip 21064 / 21064A | — | 64-bit Alpha, dual-issue, pipelined IEEE + VAX FP, 34-bit physical address, 6 IRQ inputs, PALcode |
| Serial ROM (SROM) | **Xilinx XC1765D** (E23, PLCC-20 socket, "SERIAL ROM" silkscreen; from the board photo in archive.org `alpha-station-200-roms`) | CPU SROM port | Loaded into the I-cache at reset: 65,536 bits, 7,136 bytes of code |
| Core logic | **DECchip 21071-AA** chipset (also called APECS): | sysBus | |
| ↳ Cache/memory controller | 1x **21071-CA** ("COMANCHE") | | Bcache control, DRAM banks 0–2, bank 8 = flashbus |
| ↳ Data path | 2x **21071-BA** | | 64-bit memory path, read/merge/I/O/DMA buffers |
| ↳ PCI bridge | 1x **21071-DA** ("EPIC") | PCI | Scatter/gather with an 8-entry TLB, sparse and dense space, config cycles |
| Bcache | 512 KB of 15 ns SRAM | 128 + 4 parity bits | Direct-mapped, 32-byte lines |
| Main memory | 6x 72-pin SIMM sockets (3 banks of 2) | 64 + 2 parity bits | 70 ns parity SIMMs. Max 384 MB in theory, 192 MB supported in 1995 |

### Flashbus (8-bit side bus behind the 21071-CA, memory bank 8)
| Device | Part (from ROM dump labels) | Size |
|---|---|---|
| FlashROM 0–3 | Intel N28F020 / AMD AM28F020 (-150) | 4x 256 KB = 1 MB (SRM + ARC + PALcode). "Half-flash" boards fit only 2 |
| Diagnostic ROM (DROM) | TI TMS27PC512 (socket E47) | 64 KB (POST; loads the console from flash or floppy) |
| NVRAM | (part not identified) | 8 KB (console environment variables) |
| Diagnostic LEDs | 8 LEDs (write-only latch) | 1 byte |
| Jumpers | read-only register | 1 byte |

### PCI bus (33.33 MHz, 32-bit)
| Device | Part | IDSEL | PCI interrupt | Location |
|---|---|---|---|---|
| SCSI | **NCR 53C810** (Fast SCSI-2, 8-bit SE, 10 MB/s, SCRIPTS) | AD17 | PIRQ3 | Motherboard |
| PCI-ISA bridge | **Intel 82378IB SIO** ("Saturn") | AD18 | — | Riser card |
| Ethernet | **DECchip 21040 "Tulip"** + 32-byte Ethernet ID serial ROM | AD22 | PIRQ0 | Riser card, external MAU (10BASE-T/10BASE2) |
| PCI slot 1 | — | AD23 | A→1, B→0, C→2, D→1 | Riser |
| PCI slot 2 (PCI/ISA combo) | — | AD24 | A→2, B→1, C→0, D→2 | Riser |

### ISA bus and utility bus (behind the 82378IB)
The SIO itself contains: 2x 8259 PIC, 2x 8237 DMA, an 8254 timer, NMI logic, 4 PIRQ→IRQ routers and an X-bus/utility-bus decoder.

| Device | Part | ISA I/O | IRQ / DMA |
|---|---|---|---|
| Super I/O | **National PC87332 "Super I/O III"** (some boards: PC87312, selected by jumpers J22/J24) | — | — |
| ↳ COM1 / COM2 (16550-class) | | 3F8h / 2F8h | IRQ4 / IRQ3 |
| ↳ Parallel (bidirectional/EPP) | | 378h | IRQ7 (or IRQ5) |
| ↳ Floppy (FDC) | | 3F0–3F7h | IRQ6, DMA2 |
| Keyboard/mouse controller | **Intel 8242** (Phoenix firmware) | 60h / 64h | IRQ1 / IRQ12 |
| TOY clock / RTC | **Benchmarq BQ4285** (MC146818-compatible, 114 bytes CMOS RAM) | 70h / 71h | Periodic interrupt goes **straight to CPU IRQ4**, not through the PIC |
| Sound card (custom slot, not standard ISA) | **Analog Devices AD1848** codec (Windows Sound System) | 530h (or 604h, E80h, F40h) | IRQ 7/9/10/11; DMA 0/1/3 |
| ↳ FM synth | "Yamaha YMF562" according to the manual, most likely the YMF262 OPL3 **(unverified)** | 388–38Bh | — |
| Speaker | through the 8254 timer counter | 61h | — |

### Expansion slots (AS200)
1x PCI, 1x PCI/ISA combo (some boards have 2), 1x ISA (half-length), plus a dedicated audio slot. No video on the board: graphics comes from a PCI card, typically the **ZLXp-E1/E2/E3 (DECchip 21030 "TGA")**, 8-plane, 1280x1024 at 72 Hz.

### Memory: maximum and organization
- 6 SIMM sockets form 3 banks of 2 identical SIMMs. Each bank is 64 data bits + 2 parity bits wide (longword parity, so x33 and x36 SIMMs both work).
- Supported SIMMs (manual Table 2-2):

  | SIMM | Bank size |
  |---|---|
  | 1Mx33/36 (4 MB) | 8 MB |
  | 2M (8 MB) | 16 MB, split bank |
  | 4M (16 MB) | 32 MB |
  | 8M (32 MB) | 64 MB, split bank |
  | 16M (64 MB) | 128 MB |

- **Maximum: 384 MB** (6× 64 MB SIMMs, top address `0.17FF.FFFF`). DEC's 1995 configurations stopped at 192 MB (6× 32 MB) because 64 MB SIMMs weren't yet available.
- Minimum: 8 MB (one pair of 4 MB SIMMs).
- The SROM sizes the banks and places the largest bank lowest, because each bank must be naturally aligned. Bank 8 of the 21071-CA is the flashbus, not DRAM.
- For the core, 3 banks of at most 128 MB means a 32–128 MB SDRAM configuration is "period correct" and simple. Supporting the full 384 MB would need DDR3.

### Video: how it works
- **There is no video on the motherboard.** The console goes to the first supported graphics card plus the PC keyboard. With no card, or with SRM `console` set to `serial`, it goes to COM1. The SRM string "KEYBOARD ERROR: console defaulting to serial port" shows this fallback.
- **Native TGA path**: the ZLXp-E1/E2/E3 (DECchip 21030 "TGA" + Bt485 RAMDAC) is the standard AS200 card. It is a PCI memory-mapped framebuffer, reached through dense space. SRM has a built-in driver (`dec_tga`, "Digital ZLXp Graphics Controller"). Tru64, OpenVMS, Linux and NetBSD all drive it directly. The E1 is 8-plane with 2 MB VRAM at 1280x1024 @ 72 Hz. The E2/E3 are 24-plane (E3 adds a Z-buffer).
- **VGA path**: for PC VGA cards SRM contains an **x86 emulator ("BIOS Emulation V1.15a")** that runs the card's own x86 VGA BIOS. Supported cards include the S3 Trio64/864, ATI Mach64, Matrox Millennium/Impression, Compaq QVision and ISA VGA (via `isacfg`). After the BIOS runs, the console uses VGA text mode through legacy I/O at 3B0–3DF (PCI sparse I/O) and memory at A0000 (PCI sparse memory). ARC uses the same BIOS emulator ("BIOS (ARC) 2.02"). Windows NT then loads its own driver.
- The 21071-CA does have a "video frame pointer register" (`1.8000.0240`), meant for designs with a framebuffer in main memory. The AS200 doesn't use it.
- **Options for the core**:
  1. A serial console on COM1 for bring-up. No video hardware is needed, and SRM works fully.
  2. An emulated **TGA 8-plane** card: a simple framebuffer + Bt485, supported by every OS. Use a lower mode such as 1024x768, because 1280x1024 needs a ~130 MHz pixel clock.
  3. A **VGA** card with an option ROM, reusing ao486's VGA. This needs an x86 option-ROM image that SRM's BIOS emulator can run.

## 3. CPU interrupt wiring
| 21064 input | Source |
|---|---|
| IRQ0 | CPU bus and parity errors (machine check) |
| IRQ1 | unused |
| IRQ2 | All ISA and PCI device interrupts, through the 8259s in the SIO. PALcode runs a PCI INTACK cycle to get the vector |
| IRQ3 | NMI (PCI SERR#, ISA IOCHK#) from the SIO |
| IRQ4 | Interval timer from the BQ4285 TOY |
| IRQ5 | HALT button OR 8242 KBRST |

ISA IRQ8 and IRQ13 are not connected. The PCI wire-OR groups are: PIRQ0 = Ethernet\|1B\|2C, PIRQ1 = 1A\|1D\|2B, PIRQ2 = 1C\|2A\|2D, PIRQ3 = SCSI.

## 4. Physical address map (34-bit)
| CPU physical address | Region |
|---|---|
| `0.0000.0000 – 0.FFFF.FFFF` | Cacheable main memory (DRAM up to `0.17FF.FFFF`) |
| `1.0000.0000` | Flashbus index register (bit 31 = write, bits 28:8 = offset) |
| `1.0010.0000` | Flashbus data register (bits 7:0) |
| `1.8000.0000 – ` | 21071-CA CSRs (GCR, error, timing, bank base/config/timing A/B) |
| `1.A000.0000 – ` | 21071-DA CSRs (DCSR, errors, window base/mask/translated base, HAXR0–2, TLB) |
| `1.C000.0000 – 1.DFFF.FFFF` | PCI sparse I/O (byte enables encoded in A<6:3>, PCI AD = A<28:7>) |
| `1.E000.0000 – 1.FFFF.FFFF` | PCI configuration space (IDSEL encoded in A<20:16>) |
| `2.0000.0000 – 2.FFFF.FFFF` | PCI sparse memory |
| `3.0000.0000 – 3.FFFF.FFFF` | PCI dense memory (longword or larger accesses only) |

The PCI interrupt-acknowledge space is also in the `1.xxxx` noncacheable area (see manual §3). Flashbus offsets: Flash 0–3 at `00/04/08/0C.0000`, NVRAM at `10.0000`, LEDs at `14.0000`, DROM at `18.0000`, jumpers at `1C.0000`.

Example of a sparse I/O address: ISA port `n` is at CPU `1.C000.0000 + (n << 5)`, so COM1 3F8h is at `1.C000.7F00`.

## 5. Boot flow
1. The **SROM** is shifted serially into the I-cache. It initializes the CPU (BIU_CTL), sizes and tests DRAM and the Bcache, sets up the 21071 and writes progress codes to the LEDs (FF…F4).
2. The **DROM** (64 KB) runs I/O POST, then copies the console from flash, or from floppy if J2 is set to 1–2.
3. The **SRM** console (OpenVMS, Tru64, Linux, *BSD) or the **ARC** console (Windows NT). PALcode loads with the console.
4. The operating system.

Jumpers: J1 = SROM mini-console, J2 = boot from floppy, J3 = halt/reset button, J4 = clock source, J6 = flash write enable.

## 6. Materials collected

### Documents (`scratch/refs/`)
| File | Content |
|---|---|
| `ek-pcdsa-ti.pdf` (+ `.txt`) | **AS200/400 Technical Information**: the main reference for this file |
| `EK-PCDTA-UI-E01.pdf`, `EK-PCDSA-UI-B01.pdf` | AS200 / AS400 user information |
| `alpha200_v70_fw_relnote.pdf` | Firmware V7.0 release notes |
| `ec-q9zua-te.ps`, `ec-qd2ra-te.ps` | **21064/21064A Hardware Reference Manual** and update |
| `ec-qdqua-te.ps`, `ec-n0699-72.ps`, `ec-qdqva-te.ps` | 21064 / 21064A data sheets and updates |
| `ec-qaema-te.ps`, `ec-n0637-72.ps` | **21071/21072 core logic data sheet** and product brief |
| `ec-qd2ka-te.ps` | Alpha AXP Architecture Handbook v2 (ISA definition) |
| `ec-qfglb-te.ps` | PALcode for Alpha Microprocessors System Design Guide |
| `ec-n0640-72.ps` | EB64+ (21064 + 21071 PCI evaluation board) user's guide. A close relative of the AS200 board |
| `ec-n0683-72.ps` | 21030 TGA graphics reference (ZLXp-E cards) |
| `ec-n0752-72.ps`, `ec-n0280-72.ps` | 21040 Tulip hardware reference and data sheet |
| `index.txt` | Chris Demetriou's DEC documentation index (NetBSD archive) |

Every `.ps` file now also has a `.pdf` next to it, converted with Ghostscript. `ec-q9zua-te.txt` is the searchable text of the 21064 HRM.

### Firmware images: unpacked and disassembled
See `docs/FIRMWARE_DISASM.md` for the full details. In summary:
- Flash layout on the dumped board:
  - **E13 + E19**: SRM v6.4-1, compressed.
  - **E33**: ARC 4.49, compressed.
  - **E46**: blank.
  - **E47**: the DROM, uncompressed. Code runs 0x40–0x40B8.
- The compressed images are DEC "WimC" containers holding raw **DEFLATE** data, behind a self-relocating stub.
  Decompressed SRM loads at **0x8000**: VMS PALcode at 0x8000 (the reset entry), OSF PALcode at 0x14000, then the console.
  Decompressed ARC loads at PA **0x700000** and runs at VA 0x80700000 in 32-bit superpage mode.
- The v7.0 and v6.9 update packages also yield flashable **SRM v7.0-9 / ARC 4.58** and SRM v6.9-4 / ARC 4.57
  (`scratch/roms/flash/*.img`). These are the newest firmware and good boot candidates for the core.
- Tools:
  - `tools/fwextract.py` unpacks the images.
  - `tools/alphaemu/` is a minimal EV4 integer interpreter that runs DEC's stubs. Its output matched zlib byte for byte. It could also serve as a starting reference model for the CPU.
  - `tools/disasm_all.py` produces the listings.

### ROMs (`scratch/roms/`), kept as data and never executed
- `as200_rom_dump/`: a real motherboard dump (archive.org "AS200ROM", by Fraser):
  - `E13` + `E19`: SRM **v6.4-1** (2x 28F020, 256 KB each)
  - `E33` + `E46`: ARC **4.49** (2x 28F020)
  - `E47`: DROM **V1.2, Dec 1994** (TMS27PC512, 64 KB)
- `dec_firmware_v7.0/`: the official DEC firmware update images. `as200_v7_0.exe`/`.sys` contain SRM 7.0, ARC 4.58 and the VMS/OSF PALcode. The package also includes the v6.9 image, `arcboot` and the PCI update utility. These are update-utility images, not raw flash images.

## 7. Gaps still open
- **SROM image**: not in the dump. Without it, the core must preload the I-cache with
  equivalent init code, or replace the SROM's work with an HLE stub.
- **Schematics**: none found yet. The EB64+ design package (EC-QCJGA-TE) is the closest substitute.
- **8242 keyboard controller firmware**: mask ROM, not dumped. A compatible implementation from the ao486 core can probably be reused.
- Third-party data sheets to collect: Intel 82378IB SIO (290473), NCR 53C810 data manual,
  National PC87332, Benchmarq BQ4285, AD1848, Yamaha OPL3.
- To confirm: the sysBus clock divisor, the exact SROM part, and the NVRAM part.
- Software references to mine: Linux `arch/alpha/kernel/core_apecs.c` and the Avanti machine
  vector; NetBSD/OpenBSD `apecs(4)`; MAME's Alpha CPU core (the DECpc AXP 150 "Jensen" driver)
  **(unverified)**; QEMU `target/alpha` (21264 only, but its ISA decoding can serve as a reference).

## 8. Notes on fitting this into a MiSTer (DE10-Nano, Cyclone V 5CSEBA6)
- The 64-bit integer + FP datapath of the 21064 is the main logic cost. The realistic target is tens of MHz, not 166.
- The 512 KB Bcache is close to the total M10K block RAM (~682 KB), so the core probably needs a smaller cache.
- 384 MB of RAM is more than the SDRAM module holds, so a full configuration means using DDR3 through the HPS.
  32–128 MB is enough for SRM, NetBSD and Linux.
- The SIO side (8259, 8237, 8254, RTC, FDC, UARTs, 8042, OPL, WSS) closely matches what ao486 already implements.
- The 53C810 SCSI could be emulated against a disk image on the SD card. The 21040 can be omitted at first.
- Video: a 21030 TGA (or an emulated S3/VGA on ISA/PCI) is needed for a graphical console. The serial console (COM1) is enough for SRM bring-up.

## Sources
- EK-PCDSA-TI (NetBSD DEC docs archive): https://cdn.netbsd.org/pub/NetBSD/misc/dec-docs/
- DEC firmware archive mirror: https://ftp.zx.net.nz/pub/archive/ftp.digital.com/pub/DEC/Alpha/firmware/archive/astn200/
- ROM dump: https://archive.org/details/AS200ROM
- https://zx.net.nz/computers/dec/astn200/
- https://gunkies.org/wiki/AlphaStation_200_4/166
- https://en.wikipedia.org/wiki/AlphaStation
- https://man.openbsd.org/alpha/apecs.4
