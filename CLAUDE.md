# DEC AlphaStation 200 4/100 for MiSTer: working notes for Claude

An FPGA recreation of the DEC AlphaStation 200 4/100 ("Avanti": 21064 EV4,
21071-AA APECS, ZLXp-E1 TGA, NCR 53C810, 82378 SIO) for the MiSTer
(DE10-Nano, Cyclone V 5CSEBA6). Read `docs/RESUME_PROMPT.md` for the
research history, `docs/CORE_SPEC.md` for the **locked** hardware
configuration, and `docs/REUSE.md` for what comes from the user's other cores.

## Decisions (user, 2026-10-31, initial bring-up)

| | |
|---|---|
| Project | From `../Template_MiSTer` (`5dda373`). **Core name `DECAlphaStation200`**: OSD name, rbf name, `games/DECAlphaStation200/`. `sys/` is the template's, as-is: do not edit. |
| Language | **All new components in plain Verilog (`.v`)**. The emu top `DECAlphaStation200.sv` stays SystemVerilog (it is the template's file, and hps_io's array ports need it). Components taken from other cores (mostly `.sv`) are ported to `.v` when they come in. |
| OSD | The HP 9000/715 OSD standard (`../hp9000-715/docs/osd-standard.md`): media first (Pri. disk ID 0, Disk ID 1, CD-ROM ID 4, Floppy, Load ROM), Memory, pages P1 Machine, P2 Video, P3 Input, P5 Advanced (P4 Audio when audio exists), settings latched at reset (`cfg`), "Changes pending". Status-bit map at the top of `DECAlphaStation200.sv`. |
| Board | **MiSTer at 192.168.99.143** (a MiSTer Pi; ssh root, key login). Drive and view it with **`~/Downloads/MiSTerKVMS-0.9.5-linux-x86_64/misterkvms-cli --mister 192.168.99.143`** (`status`, `screenshot OUT.png`, `key`, `type`, `wait-for-change`, `load-core RBF`); the capture stream is `mkvm://192.168.99.82/MiSTer-Pi`. MiSTer.ini runs 1080p (`video_mode=8`). |
| Main_MiSTer | Branch **`dec-alphastation`** off `master` (88d2d10) in `../Main_MiSTer`, for this core's Main needs: SCSI write buffering and CD-ROM handling like the HP/Sun/RS6K families (`support/hp9k`, `support/ibmrs6k` on `origin/ibmrs6k`), CD audio later. Don't check it out in `../Main_MiSTer` (other sessions use that tree on `hp9k-family`): use a worktree. |
| Simulator | Verilator, headless: `make -C verilator` / `make -C verilator smoke` (`verilator/sim_main.cpp` options in its header). |
| Memory | SDRAM = system RAM (32/64/128 MB), DDR3 = TGA VRAM, flash/DROM images, BRAM = caches (user's standing preference). |
| Clocks | **Target: the CPU at 100 MHz** (the 4/100's own speed; user, 2026-11-01): a fast pipelined CPU and FPU with caches. Today's PLL: 50 MHz system (`outclk_0`), 50 MHz shifted for SDRAM (`outclk_1`, unused yet), 65 MHz pixel (`outclk_2`, 1024x768@60); the system clock moves to 100 MHz with the CPU. |
| Machine | **AlphaStation 200 4/100** (user, 2026-11-01; was the 4/166). DROM V1.2's speed table stops at 166 MHz, so the init code hands over PA 0x70 = 2, 0x10 = 10000 ps, 0x68 = 100 |
| SROM | User wants **the original SROM** baked in (a file or the core's ROM). None is dumped publicly (searched 2026-11-01: archive.org AS200ROM has only flash + DROM; EBSDK has SROM sources for 21164/21264 boards only; cetus.sh documents the DEC 3000 SROM format). Replacement init code until one turns up. |
| ROMs | `games/DECAlphaStation200/boot0.rom` = the 1 MB flash image (ioctl index 0; Load ROM replaces it for the session), `boot1.rom` = DROM V1.2 (index 0x40). NVRAM: slot SC4. |

## State

- **2026-10-31: scaffold.** The Quartus project, the OSD, `rtl/as200.v` with
  COM1 (`rtl/sio/ns16550.v`, a full 16550A) driven by `rtl/bringup_stub.v`
  (prints a banner, echoes) in place of the CPU, `rtl/mister/vterm.v` (COM1
  as a 128x48 terminal on HDMI), keyboard into COM1 (`rtl/mister/ps2_ascii.v`).
  The Verilator smoke run passes (banner, RXD echo, typed line, TXD line
  checked bit by bit against the 16550's output).
- Toolchain checked: `alpha-linux-gnu-gcc` 15.2 / binutils 2.46,
  `qemu-alpha -cpu ev4`. **Ubuntu's static glibc uses BWX** (`ldbu` in
  `__tunables_init`), so a glibc-linked binary dies with SIGILL under
  `-cpu ev4`: CPU tests need their own runtime (no glibc), and
  `as -mev4` does not reject BWX opcodes, so every test image is scanned
  with objdump for BWX/FIX/CIX/MVI opcodes.

- **Board build 3 (2026-10-31) on .143**: banner, keyboard echo through COM1, OSD with Changes
  pending; timing met on all clocks (8.1k ALMs). Note: Quartus keeps octal string escapes like
  `"\001"` literally (Verilator doesn't), so don't use them in RTL strings.
- **CPU**: `docs/design/cpu.md` is the 21064 specification (reset, ISA, PAL instructions, IPRs, PAL
  entries, translation rules, RTL plan, open questions). `rtl/cpu/ev4_ialu.v` and `ev4_imul.v` pass
  their unit benches (`make -C verilator tb_ialu tb_imul`); **`rtl/cpu/ev4_seq.v`, the sequential
  reference core, runs all seven T0 suites with retire traces identical to alphaemu**
  (`make -C verilator cputest`). T0 runs three ways: QEMU user (`make -C tests/cpu`), alphaemu user
  (`emu`) and the bare-metal PALmode images on alphaemu (`pal-emu`, `tools/alphaemu -P -H`).

## Next (in order)

1. CPU: T3 privileged tests (PAL entries, IPRs, HW_LD/ST, CALL_PAL, traps) on ev4_seq; the ITB/DTB;
   interrupts; then the FPU (T2), then the pipelined core co-simulated against ev4_seq.
2. alphaemu: PAL entries/exceptions and the IPRs, so it stays the golden model for T3.
3. The system: SROM replacement (cpu.md 1.4, option A), 21071-CA memory + flashbus, SDRAM, DROM to
   its serial output; then PCI (21071-DA), the SIO devices and the 53C810 from the RS/6000 core
   (`docs/REUSE.md`), TGA.

## Rules carried over from the user's other cores

- Commit often in small steps (local commits; never push without asking).
- One Quartus fit at a time on this box (14 GB, 6 cores). Before a fit check
  `pgrep -a quartus` and the DSPPC603/Pippin session (it has priority). Launch
  with `setsid nohup quartus_sh --flow compile DECAlphaStation200 > fit.log 2>&1 < /dev/null &`.
  Never edit `files.qip`/QSF/SDC while a fit runs.
- Never delete files without asking.
- Third-party material (ROMs, manuals, ISOs, Microsoft binaries) stays in `scratch/`, never in git.
- Verilator treats a comment starting with the word "Verilator" as a directive: don't start comments with it.
