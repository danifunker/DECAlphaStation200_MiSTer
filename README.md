# DEC AlphaStation 200 core for MiSTer

An FPGA core for the MiSTer (DE10-Nano) recreating a **DEC AlphaStation 200 4/100**: the 21064 (EV4) Alpha CPU, the
21071 "APECS" chipset, a ZLXp-E1 TGA graphics card, NCR 53C810 SCSI, and the 82378 SIO with standard PC peripherals.
Target OSes: the SRM and ARC consoles, NetBSD/Linux, Digital UNIX 4.0x, OpenVMS, Windows NT 3.51/4.0 and the Windows 2000 RC1 Alpha build.

Status: **initial bring-up.** The MiSTer project (`DECAlphaStation200`), the OSD, COM1 with a bring-up stub in place of the CPU, the
on-screen serial terminal and a Verilator simulation exist; the 21064 is next. Working notes: `CLAUDE.md`.

## Repository layout
| Path | Contents |
|---|---|
| `DECAlphaStation200.{qpf,qsf,sdc,srf,sv}`, `files.qip` | Quartus project (from Template_MiSTer); `DECAlphaStation200.sv` is the MiSTer `emu` top with the OSD |
| `sys/` | MiSTer framework, as-is from Template_MiSTer |
| `rtl/` | The core: `as200.v` (the machine), `sio/` (PC peripherals), `mister/` (board side: terminal, keyboard), `pll*` |
| `verilator/` | Headless simulation: `make -C verilator smoke` |
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
