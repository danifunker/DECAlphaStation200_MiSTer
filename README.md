# DEC AlphaStation 200 core for MiSTer

An FPGA core for the MiSTer (DE10-Nano) recreating a **DEC AlphaStation 200 4/100**: the 21064 (EV4) Alpha CPU, the
21071 "APECS" chipset, a ZLXp-E1 TGA graphics card, NCR 53C810 SCSI, and the 82378 SIO with standard PC peripherals.
Target OSes: the SRM and ARC consoles, NetBSD/Linux, Digital UNIX 4.0x, OpenVMS, Windows NT 3.51/4.0 and the Windows 2000 RC1 Alpha build.

Status (2026-11-11, board build `_20261111a`): **the machine runs its operating systems.** SRM V7.0 and ARC 4.58 come
up from the real flash images; every installed OS image boots from SCSI, logs in and shuts down:

| OS | Console | Notes |
|---|---|---|
| OpenVMS 6.2, 7.3, 8.4 | SRM, TGA | DECwindows Motif (1.2-3, 1.2-6, 1.7) on the TGA; TCP/IP installed. Needs your licence PAKs |
| Tru64 UNIX 4.0G, 5.1B-4 | SRM, TGA | CDE on the TGA. Runs without PAKs (logs a missing OSF-BASE licence); the C compiler needs OSF-DEV |
| NetBSD 10.2 | SRM, TGA | Text console. Rejects the TOY clock (`docs/gaps.md`) |
| FreeBSD 4.6 | SRM, serial | No TGA console driver: set OSD SRM console = Serial |
| Windows NT 4.0 Workstation, Terminal Server | ARC | |
| Windows 2000 Server (build 2072) | ARC | Its last shutdown screen is "Writing unsaved data to the disk"; that is normal |

What is missing or known wrong is in `docs/gaps.md`. Working notes: `CLAUDE.md`.

## Using the core
- **Media (OSD top):** Pri. disk = SCSI ID 0 (`dka0` in SRM), Disk = ID 1, CD-ROM = ID 4 (`dka400`), Floppy, Load ROM.
  Don't change a disk image while an OS is running.
- **NVRAM image (Advanced):** an `.nvr` file holds the firmware's settings (SRM's environment, ARC's boot entries) and,
  at 8,704 bytes, the TOY CMOS as well, so SRM's `set os_type` / `set console` and ARC's console switch survive a core
  load. `tools/nvr_cmos.py FILE --pad` upgrades an old 8 KB file; `--console srm|arc` and
  `--srm-console graphics|serial` set the two CMOS bytes directly. `releases/AS200.nvr` is a blank padded file.
- **Machine > Console:** *NVRAM file* (default) starts the console the NVRAM image asks for; *SRM* and *ARC* force one.
- **Machine > SRM console:** *Graphics* (default) and *Serial* force SRM's `console` variable; *NVRAM file* uses what
  `set console` saved. SRM writes its setting back at every start, so after one boot the file follows a forced value.
- **Video > Display:** which picture the HDMI output shows (the TGA, or COM1 as a text terminal) and where the
  keyboard types. Switching it is live and does not change the guest's own console setting.
- Settings marked "Changes pending" take effect at *Apply and reset*.

## Repository layout
| Path | Contents |
|---|---|
| `DECAlphaStation200.{qpf,qsf,sdc,srf,sv}`, `files.qip` | Quartus project (from Template_MiSTer); `DECAlphaStation200.sv` is the MiSTer `emu` top with the OSD |
| `sys/` | MiSTer framework, as-is from Template_MiSTer |
| `rtl/` | The core: `as200_sys.v` (the machine), `cpu/` (the 21064), `apecs/` (21071), `sio/` (82378 and PC peripherals), `scsi/`, `tga/`, `net/` (21040), `audio/`, `mister/` (board side: terminal, keyboard, NVRAM/flash, SDRAM) |
| `verilator/` | Headless simulation: unit benches (`make -C verilator tb_cmos`, `tb_sio`, ...) and the system model (`verilator/system/tb_sys.cpp`) |
| `tools/nvr_cmos.py` | Shows or edits an `.nvr` file's TOY CMOS block (console choice, SRM console) |
| `docs/gaps.md` | What is missing or wrong, and the OS table (what runs, with dates and builds) |
| `docs/REUSE.md` | What comes from the user's other MiSTer cores (53C810, SIO devices, SDRAM, Main support) |
| `docs/CORE_SPEC.md` | **The locked hardware configuration** (what the core implements) |
| `docs/HARDWARE.md` | The real machine: chip list, address map, interrupts, boot flow, memory, video |
| `docs/CPU_TEST_PLAN.md` | 21064 functional blocks, reference models, and the test-suite plan |
| `docs/FIRMWARE_DISASM.md` | How the firmware images were unpacked and what each disassembly listing contains |
| `docs/NT_DRIVERS.md` | Windows 2000 Alpha driver binaries kept for reverse engineering (TGA, HAL, SCSI…) |
| `docs/NT5_BETAS.md` | Windows 2000 (NT 5.0) Alpha betas: AS200 support per build |
| `docs/RESUME_PROMPT.md` | Prompt for resuming work with Claude Code on a new machine |
| `tools/alphaemu/` | Minimal EV4 integer interpreter in C (runs DEC's firmware decompressor stubs; seed of a reference model) |
| `tools/fwextract.py` | Unpacks DEC "WimC" (DEFLATE) firmware images |
| `tools/disasm_all.py` | Annotated EV4 disassembly of all firmware images |
| `tools/pe_alpha_disasm.py` | Annotated disassembly of Windows NT Alpha PE/COFF binaries (`.pdata` functions, imports, strings) |
| `scratch/` | **Not in git.** Third-party and generated material, distributed as a zip. See `scratch/README.md` |

## Setup (Debian/Ubuntu)
```sh
sudo apt install build-essential python3 binutils-alpha-linux-gnu gcc-alpha-linux-gnu \
                 qemu-user cabextract ghostscript poppler-utils verilator
unzip scratch.zip            # restores ./scratch next to this README
cc -O2 -Wall -o build/alphaemu tools/alphaemu/alphaemu.c
make -C verilator smoke          # the bring-up simulation
python3 -I tools/disasm_all.py   # regenerates scratch/disasm (optional; it ships in the zip)
```
On macOS, use `brew install binutils ghostscript poppler cabextract` instead (`tools/*.py` find Homebrew's objdump automatically).

## Licensing note
Our own code and documentation are in this repository. The DEC manuals, ROM dumps, firmware and Microsoft binaries in
`scratch/` belong to their owners and are kept only for research. Don't add them to the repository.
