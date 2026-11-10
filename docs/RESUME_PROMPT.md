# Resume prompt (2026-11-01)

> **2026-11-10:** the current state is `CLAUDE.md` (State) and `docs/PLAN_20261109.md` (Status); the board builds are
> `_20261109i` (commit `f842543`, tag `release-20261110`). Development runs on the Windows machine (WSL for Verilator and
> ssh, Quartus 17.0 in-tree, one fit at a time); the Linux-box/Mac notes below are history.

> Development stayed on the Linux box (m900) after all (user). The Mac setup below is ready for
> later: dani-dev.local has the repo clone and `scratch/` but no Homebrew/Verilator yet.

## Setup on the Mac

1. **Clone** the repo (local commits only so far: push from the Linux box first, or copy the repo
   directory). Sibling repos the docs refer to (reference only): `../hp9000-715`, `../IBMRS6K42p`
   (`origin/master`), `../Template_MiSTer`, `../Main_MiSTer`.
2. **`scratch/`** (1.7 GB, third-party material, never in git) has to be copied over. From the Mac:
   ```
   rsync -a --exclude '*.trace' --exclude 'led2e.*' --exclude 'sys_*.txt' --exclude 'srm*.txt' \
       dani@<linux-box>:repos/DECAlphaStation200_MiSTer/scratch/ scratch/
   ```
   The excluded files are simulation traces and a checkpoint that is only valid for the old
   simulator binary. What matters: `scratch/roms/` (flash, DROM V1.2/V1.7, the archive.org chip
   images, extracted SRM/ARC, the DEC 3000 SROM), `scratch/refs/` (HRM, TI manual, 21071 data
   sheet, EB64+ and AlphaPC64 guides), `scratch/ebsdk/` (DEC SDK, reference only), `scratch/disasm/`,
   `scratch/isos/`, `scratch/README.md` (manifest with SHA-1s).
3. **Tools**
   - Verilator 5.x: `brew install verilator` (the Linux box used 5.028).
   - The Alpha cross binutils/gcc (`alpha-linux-gnu-as`, `-gcc`, `-objdump`) have no Homebrew
     package. Simplest: an Ubuntu container (OrbStack or Docker) with `binutils-alpha-linux-gnu
     gcc-alpha-linux-gnu qemu-user`, run from the repo directory. They are needed for `tests/cpu`
     (T0/T3 images, ignored build dir) and `srom/` (the SROM's build products are committed, so the
     RTL builds without them). `tools/alphaemu` is plain C and builds natively.
   - **Quartus 17.0 Lite does not run on macOS.** Fits stay on the Linux box (or a Linux x86 VM
     with enough RAM): one fit at a time, `setsid nohup quartus_sh --flow compile DECAlphaStation200
     > fit.log 2>&1 < /dev/null &`.
   - Board: the MiSTer at **192.168.99.143** (ssh root, key login; the Mac needs its own key in
     `/root/.ssh/authorized_keys`). misterkvms-cli has a macOS build; on Linux it was
     `~/Downloads/MiSTerKVMS-0.9.5-linux-x86_64/misterkvms-cli --mister 192.168.99.143`.
4. Claude's project memory on the Linux box (`~/.claude/projects/-home-dani-repos-DECAlphaStation200-MiSTer/memory/`)
   only held two pointers (board .143, the user's sibling-core rules in the hp9000-715 memory); their
   substance is in `CLAUDE.md`.
5. Start Claude Code in the repo root and paste the prompt below.

---

We're building a MiSTer (DE10-Nano) FPGA core of the **DEC AlphaStation 200 4/100** in this repo.
Read `CLAUDE.md` first (decisions, rules, state), then `docs/CORE_SPEC.md`, `docs/design/cpu.md`,
`docs/design/pipeline.md`, `docs/design/cpu-timing.md`, `docs/design/srom.md`, `docs/design/pci.md`,
`docs/design/scsi.md`, `docs/design/sio.md`.

Where it stands (2026-11-01):
- `rtl/as200_sys.v` is the machine: the pipelined 21064 `rtl/cpu/ev4_core.v` (I/D caches, ITB/DTB,
  interrupts, SROM bitstream loaded into the I-cache at reset), the 21071 model `rtl/apecs/apecs.v`
  (memory banks, CSRs, flashbus, PCI target bus, DMA windows, IACK), the 53C810 `rtl/scsi/`, the
  82378 SIO and ISA devices `rtl/sio/`. Our replacement SROM is `srom/avanti_srom.S`.
- **On the board (.143)**: build 5 runs our SROM and DEC's whole DROM V1.7 POST at 100 MHz from
  SDRAM, then the flash loader starts SRM (screens in the session history; the HDMI terminal shows the
  SROM serial port, COM1 and the LED codes).
- **In simulation** (`make -C verilator system`, checkpoints with `--save-led 2E` / `--restore`): SRM's
  flash stub decompresses SRM and enters it. SRM then printed (in its PALcode's raw string loop)
  "warning -- PALcode is not built for this CPU chip version": DC_STAT.CHIP_ID read 0. Fixed in
  `d8eeffe` (CHIP_ID = 7) together with **interrupt delivery** (HIER/SIER/ASTER, SIRR/ASTRR, PAL 0xE0).
  **That fix has not been run in the system simulation yet.**
- Tests: `make -C verilator cputest-pipe` (7 T0 suites, traces = alphaemu), `t3` (TLB + interrupt),
  `sromload`, `tb_sdram`, `tb_ncr810`, `tb_sio`, `tb_sio_drom` all pass.
- Timing (100 MHz, slow 100C corner): the last full fit (commit `0c8dfa6`, no interrupts yet) is at
  **-1.244 ns**, 22k ALMs (52%). It runs on the board regardless; the remaining paths need grouping
  again (`docs/design/cpu-timing.md` has the method and the history).

Next, in order:
1. Rebuild the system sim (`make -C verilator obj_sys/Vas200_sys`; `SIM_FAST=1` is the default and
   makes the TOY tick fast), make a new checkpoint at LED 2E, run on into SRM and watch COM1 (the
   simulator's stdout). Expect SRM's next needs: real interrupts from the TOY (IRQ4) and the 8259
   (IRQ2, the vector through IACK at 1.B000.0000), the FPU (SRM uses some FP; ICCSR.FPE), and
   whatever the console's device probes touch.
2. A board build with `d8eeffe` and later on the Linux box; close timing (re-group the failing paths).
3. The SCSI targets on the hps_io block devices (`rtl/scsi/scsi_targets.v` exists, not wired);
   CMOS/NVRAM save (TOY byte 3Fh picks SRM vs ARC); the 28F020 flash command set; the FPU (T2); TGA.

Rules: all new RTL in plain Verilog-2001 (`.v`); commit often, never push without asking; never
delete files without asking; third-party material only in `scratch/`; one Quartus fit at a time.

---

# Earlier resume prompt (2026-10-31, historical)

> 2026-11-01: historical. The target is now the **4/100**, at a 100 MHz clock target; `CLAUDE.md` and `docs/CORE_SPEC.md` are current.

Setup on the new Linux machine:
1. Clone the repo.
2. Unzip `scratch.zip` in the repo root so `scratch/` exists.
3. Run the setup commands in `README.md`.
4. Copy the NT 4.0 SP6 Alpha ISO from the NAS into `scratch/isos/`.
5. Start Claude Code in the repo root and paste the prompt below.

---

```text
We're building a MiSTer (DE10-Nano) FPGA core for the DEC AlphaStation 200 4/166. This repo holds the research and
spec phase, which was done on a Mac and has now moved to this Linux machine. No RTL exists yet.

Read these first, in order:
  README.md                 - layout, setup, licensing rule (third-party files stay in scratch/, never in git)
  docs/CORE_SPEC.md         - the LOCKED hardware configuration. Treat it as authoritative; change it only deliberately
  docs/CPU_TEST_PLAN.md     - 21064 functional blocks, reference models, test-suite plan
  docs/HARDWARE.md          - the real machine: chips, address map, interrupts, boot flow
  docs/FIRMWARE_DISASM.md, docs/NT_DRIVERS.md, docs/NT5_BETAS.md - reference material and how it was produced
scratch/README.md lists everything in scratch/ with SHA-1s.

Decisions already made (don't reopen without a reason):
- Machine: AlphaStation 200 4/166. CPU 21064 (EV4, 8K+8K caches, no BWX/FIX/CIX/MVI). Chipset 21071-AA (APECS).
- RAM: OSD option 32/64/128 MB (default 64), using identical non-split 21071-CA banks
  (32 = 1x32, 64 = 2x32, 128 = 1x128). The MiSTer SDRAM is enough; no DDR3.
- Video: ZLXp-E1 = DECchip 21030 TGA, 8-plane, 2 MB, PCI slot 1 (IDSEL AD23), default 1024x768@60.
  Chosen over TGA2 because ARC 4.58 only knows ZLXp-E1/E2/E3, and NT 3.51 and the early NT5 betas only ship the TGA driver.
- Firmware: default flash = the real board dump (SRM 6.4-1 + ARC 4.49) + DROM V1.2. SRM 7.0-9 / ARC 4.58 come later,
  after the flash check-byte question is answered.
- The original 64 Kbit SROM is NOT available. The core needs replacement init code that does the SROM's job
  (CPU/BIU init, memory sizing, 21071-CA bank setup), then jumps to the DROM.
- Bring-up path: serial console on COM1 first, then TGA.
- OS targets: SRM/ARC, NetBSD/Linux, Digital UNIX 4.0F/G, OpenVMS 6.2-7.2, NT 3.51/4.0 (NT4 SP6 ISO in scratch/isos),
  Windows 2000 RC1 2072 (main NT5 target; the Beta 2 1877 checked build is for debugging).

Facts that took effort to establish:
- Firmware images are DEC "WimC" containers holding raw DEFLATE (tools/fwextract.py). SRM decompresses to 0x8000
  (VMS PALcode @0x8000 = reset entry, OSF PALcode @0x14000, console from ~0x38000). ARC decompresses to PA 0x700000
  and runs at VA 0xFFFFFFFF80700000 (32-bit superpage). The ARC flash header's length field is about 0x40 too short.
- tools/alphaemu ran DEC's own stubs, and its output matched zlib byte for byte. It is the seed of our reference model.
- EV4 FP traps on NaN/Inf/denormal operands (OS software completion). Underflow can force +0. FP tests must model
  this; QEMU's full IEEE results won't match raw EV4 behaviour.
- No CPU test suite exists in any ROM. The DROM is an I/O POST plus an interactive monitor; the AS200 SRM has no test command.
- No hardware is available: verification is simulation-first (Verilator) against reference models.

Next tasks, in order:
1. Toolchain sanity check: alpha-linux-gnu-as/gcc with -mcpu=ev4, qemu-alpha -cpu ev4, and building tools/alphaemu.
2. Start the CPU test suite (docs/CPU_TEST_PLAN.md, tier T0): a bare-metal PALmode test harness (reset entry, pass/fail
   signature to a "tohost" address plus the diagnostic LEDs), and self-checking tests for every Ebox integer opcode.
3. Extend tools/alphaemu into the golden model: full integer ISA, trace output (PC, dest reg, value, memory writes),
   then FP with the EV4 trap rules.
4. Scaffold the RTL repo structure and a Verilator testbench that runs T0 tests and diffs traces against alphaemu.

Open items: SROM replacement design; the flash check bytes (E19 ends 0x81, E46 ends 0x52; not a sum or XOR; see the
APU update-utility listing); confirming the ZLXp-E1 RAMDAC and clock against card manual EK-T2424-OG.
```
