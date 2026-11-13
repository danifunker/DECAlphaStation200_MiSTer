# DEC AlphaStation 200 4/100 for MiSTer: working notes for Claude

An FPGA recreation of the DEC AlphaStation 200 4/100 ("Avanti": 21064 EV4,
21071-AA APECS, ZLXp-E1 TGA, NCR 53C810, 82378 SIO) for the MiSTer
(DE10-Nano, Cyclone V 5CSEBA6). Read `docs/RESUME_PROMPT.md` first (the
current resume prompt and the Mac setup, then the research history), `docs/CORE_SPEC.md` for the **locked** hardware
configuration, and `docs/REUSE.md` for what comes from the user's other cores.

## Decisions (user, 2026-10-31, initial bring-up)

| | |
|---|---|
| Project | From `../Template_MiSTer` (`5dda373`). **Core name `DECAlphaStation200`**: OSD name, rbf name, `games/DECAlphaStation200/`. `sys/` is the template's, as-is: do not edit. |
| Language | **All new components in plain Verilog (`.v`)**. The emu top `DECAlphaStation200.sv` stays SystemVerilog (it is the template's file, and hps_io's array ports need it). Components taken from other cores (mostly `.sv`) are ported to `.v` when they come in. |
| OSD | The HP 9000/715 OSD standard (`../hp9000-715/docs/osd-standard.md`): media first (Pri. disk ID 0, Disk ID 1, CD-ROM ID 4, Floppy, Load ROM), Memory, pages P1 Machine, P2 Video, P3 Input, P5 Advanced (P4 Audio when audio exists), settings latched at reset (`cfg`), "Changes pending". Status-bit map at the top of `DECAlphaStation200.sv`. |
| Board | **MiSTer at 192.168.99.143** (a MiSTer Pi; ssh root, key login). Drive and view it with **`~/Downloads/MiSTerKVMS-1.0.27-linux-x86_64/misterkvms-cli --mister 192.168.99.143`** (`status`, `screenshot OUT.png`, `key`, `type`, `wait-for-change`, `load-core RBF`); the capture stream is `mkvm://192.168.99.82/MiSTer-Pi`. MiSTer.ini runs 1080p (`video_mode=8`). |
| Main_MiSTer | Branch **`dec-alphastation`** off `master` (88d2d10) in `../Main_MiSTer`, for this core's Main needs: SCSI write buffering and CD-ROM handling like the HP/Sun/RS6K families (`support/hp9k`, `support/ibmrs6k` on `origin/ibmrs6k`), CD audio later. Don't check it out in `../Main_MiSTer` (other sessions use that tree on `hp9k-family`): use a worktree. |
| Simulator | Verilator, headless: `make -C verilator` / `make -C verilator smoke` (`verilator/sim_main.cpp` options in its header). |
| Memory | SDRAM = system RAM (32/64/128 MB), DDR3 = TGA VRAM, flash/DROM images, BRAM = caches (user's standing preference). |
| Clocks | **The CPU and the machine at 100 MHz** (the 4/100's own speed; user, 2026-11-01): PLL `outclk_0` 100 MHz system (CPU, machine, SDRAM, hps_io), `outclk_2` 65 MHz pixel (1024x768@60); SDRAM_CLK = the system clock inverted through a DDR output register. |
| Machine | **AlphaStation 200 4/100** (user, 2026-11-01; was the 4/166). DROM V1.2's speed table stops at 166 MHz, so the SROM hands over PA 0x10 = 10000 ps, 0x68 = 100 and speed code 9 at 0x70 (DROM V1.7's own 100 MHz code), plus the memory size in MB at 0x38 |
| SROM | User wants **the original SROM** baked in; the part is a **Xilinx XC1765D** 64 Kbit serial PROM at E23 and no dump is public (searched 2026-11-01). **Our replacement: `srom/avanti_srom.S`** (`docs/design/srom.md`; `tools/srom/srom.py` packs/decodes the 21064 bitstream, verified bit for bit against DEC's DEC 3000 SROM), built into `srom/build/avanti_srom.{bin,bitstream,hex}`; a real dump drops in as the same bitstream. |
| ROMs | `games/DECAlphaStation200/boot0.rom` = the 1 MB flash image, default SRM v7.0-9 + ARC 4.58 (the real chips from archive.org `alpha-station-200-roms`; ioctl index 0; Load ROM replaces it for the session), `boot1.rom` = **DROM V1.7** (index 0x40; knows 100 MHz). NVRAM: slot SC4. |

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

- **2026-11-01: the pipelined core.** `rtl/cpu/ev4_core.v` (`docs/design/pipeline.md`: F0 F1 F2
  D X M1 M2 W, 8 KB I-cache, 8 KB write-through D-cache, write buffer, the 21064's latencies with
  the measured X->X forwarding loop, precise exceptions, serialized PAL instructions) passes all
  seven T0 suites with traces identical to alphaemu (`make -C verilator cputest-pipe`), and
  loads the SROM bitstream into its I-cache after reset like the 21064 (`icmode`; `make -C
  verilator sromload` runs our replacement SROM up to its memory sizing). Timing probes and fits:
  `docs/design/cpu-timing.md` (scratch/cpu_fmax).
- **Replacement SROM**: `srom/avanti_srom.S`, `docs/design/srom.md`, `tests/srom/`.
- **System (2026-11-01):** `rtl/as200_sys.v` = ev4_core + `rtl/apecs/apecs.v` (21071: memory banks
  with the aliasing the SROM's sizing needs, CSRs, flashbus, PCI target bus per `docs/design/pci.md`,
  DMA windows) + COM1 behind a stand-in ISA bridge. **`make -C verilator system`: our SROM runs all
  its steps and enters DEC's DROM V1.7, whose console (on the SROM serial port: SL_XMIT, 19200 baud)
  prints POST Started / Epic Errors Cleared / NVRAM Test Passed / 53C810 Test Started, then fails the
  53C810's PCI ID (no device yet) and beeps.** The MiSTer top now runs this machine at 100 MHz with
  `rtl/mister/sdram_ctl.v` (SDRAM, unit-tested), `rtl/mister/fbrom.v` (boot0.rom flash in DDR3,
  boot1.rom DROM in BRAM) and `rtl/mister/con_mux.v` (the HDMI terminal shows the SROM port, COM1 and
  the LED codes). The board has boot0.rom = SRM 7.0-9 + ARC 4.58 chips, boot1.rom = DROM V1.7.
  `rtl/as200.v` + `bringup_stub.v` remain only for the bring-up Verilator smoke test.

- **2026-11-01, later:** the 53C810 and the 82378 SIO + ISA devices are in `as200_sys`; the whole
  DROM V1.7 POST passes in simulation **and on the board** (build 5), and the flash loader starts SRM.
  The core gained the ITB/DTB (T3 `t3_tlb`), interrupt delivery (T3 `t3_intr`), DC_STAT CHIP_ID,
  CC/CC_CTL, SL_XMIT/SL_RCV, FLUSH_IC as a sweep (a deadlock with an in-flight fill fixed). The
  system sim has checkpoints (`--save-led 2E`, `--restore`). Last full fit: -1.244 ns at 100 MHz,
  22k ALMs (`docs/design/cpu-timing.md`).
- **2026-11-01: development stays on the Linux box (m900)** (user). A clone with `scratch/` exists on
  the Mac (`dani@dani-dev.local:~/repos/DECAlphaStation200_MiSTer`, M1, no Homebrew/Verilator yet);
  `docs/RESUME_PROMPT.md` has the Mac setup if that changes.

## Next (in order)

1. System sim with `d8eeffe` (CHIP_ID, interrupts): a new LED-2E checkpoint, then run into SRM and
   watch COM1. SRM's next needs: TOY/8259 interrupts end to end, the FPU, its device probes.
2. A board build with the latest RTL; close timing at 100 MHz (re-group the failing paths).
3. SCSI targets on hps_io (`rtl/scsi/scsi_targets.v`), the 28F020
   command set, the FPU (T2), branch prediction and block bus transfers, TGA.

- **2026-11-01: SRM V7.0 runs and prints on COM1 in the system simulation** (after the FP
  loads/stores and the large-ITB PFN fix): its progress codes ff..e6, "ISA table corrupt /
  Initializing table to defaults" and "TIMER_TPS environment variable invalid" (both from the blank
  NVRAM, as on a real machine), then **"V7.0-9, built on Mar 18 1999" and the `>>>` prompt at ~30 s
  of machine time**. Checkpoint past the prompt: `scratch/srm30s` (valid for this simulator build).
- **2026-11-01: the same on the board (build 9, .143): SRM V7.0-9 at `>>>`, `show config` typed on
  the MiSTer keyboard** (firmware, "DECchip 21064-3 100Mhz", 64 MB in 2 banks, the ISA devices).
  Full fit: 23.0k ALMs (55%), -1.139 ns at 100 MHz (runs regardless). SRM's PCI list is empty
  (`docs/gaps.md`).
- **Board build 11 (2026-11-01):** SRM lists the PCI bus (NCR 810 = pka0, Intel SIO 82378) after the
  21071-DA pass-2 bit fix, and with an ISO on the OSD's CD-ROM slot `show device` finds **dka400
  (RRD45)**: SCSI works end to end on the FPGA. Agents (2026-11-01) are doing the CD-ROM/CD audio/
  Main_MiSTer `support/decalpha` (worktree `../Main_MiSTer-decalpha`, branch `dec-alphastation`) and
  the audio (WSS, OPL, speaker, mixer).
- **Board build 15 (2026-11-01, `cdf5d14`):** the FPU (all 292 FP codes), audio (WSS/OPL2/speaker/
  mixer), the CD-ROM's full command set and CD audio, Main `support/decalpha` (board runs
  `scsi-consolidated-2-decalpha`, local, with the backup `/media/fat/MiSTer.before-decalpha`), and
  dInvReq (DMA writes invalidate the D-cache). `boot dka400` reads the CD cleanly. 28.4k ALMs (68%),
  -1.327 ns at 100 MHz.
- **Board build 16 (2026-11-01, `53584d1`):** the TGA (ZLXp-E1, VRAM in DDR3), the 21040, the
  floppy, PCI scatter/gather. SRM's `show config` lists all four PCI devices (NCR 810, SIO, DECchip
  21040 ewa0 08-00-2B-A5-02-00, Digital ZLXp); `show device`: dka400, dva0, ewa0, pka0. **`set console
  graphics` + `init`: SRM draws its console on the TGA** (COM1 then stays silent) with PS/2 keyboard
  input. `boot dka400` reads NetBSD's bootstraps and kernel off the CD. 33.9k ALMs (81%), 43.4k
  registers, -1.897 ns at 100 MHz. (The first try of this build stalled the fitter: the floppy track
  cache was uninferred, ~98k registers; `no_rw_check` fixed it. Check `Total registers` in map.)
- **2026-11-03: Windows NT 4.0 Workstation SP1 installs and runs on the board** (core `a6e76de`,
  26.11.06 on .143): 2 GB disk (ARCINST FAT system partition + NTFS), GUI Setup completes, logon,
  desktop. Fixed on the way: ddr3_arb VRAM read-after-write race (text Setup stripes), the I-fill
  redirect loss and the lock flag (CPU), interrupt vs ITB-miss priority (every new NT process died at
  kernel32!BaseProcessStart), TGA modes 05/25, RTC register B at power-up. `tools/ntkd.py` is a
  minimal NT kernel debugger client over the MiSTer UART (see its header).
- **2026-11-09/10: the 21030 pixel mask is a simple / opaque-stipple parameter only** (manual 4.4.21): applying it to
  transparent stipples and to copies produced NT 4.0's status-bar fragments and the edges of cancelled menus
  (`32bbcff`, `f842543`; board builds `_20261109h`, `_20261109i`). The P0 SRM boot failure (keyboard reaching COM1 and
  the 8242 at once), the 8259 cascade and the TGA line engine were fixed the same day (`docs/gaps.md`, `docs/PLAN_20261109.md`).
  `tools/tgareplay.py` + `scratch/tgacap_*.sh` (lossless TGA traces with VRAM dumps) are the way to chase drawing bugs.
- **2026-11-10/11: the console choice lives in the NVRAM image.** The TOY CMOS (00h-7Fh) is kept in block 16 of an
  8,704-byte `.nvr` (`rtl/mister/nvsave.v`, marker "CMOS"; an 8 KB file keeps none). CMOS **3Fh** = the console the DROM
  starts (1 ARC, else SRM): OSD Machine > Console = NVRAM file (default) / SRM / ARC. CMOS **17h** = SRM's `console`
  variable (01 graphics, 00 serial; found by watching the CMOS in the system simulator): OSD Machine > SRM console =
  Graphics (default) / Serial / NVRAM file, status 30:29 (`2516794`, board build **`_20261111a`**, -2.062 ns, 37.5k ALMs).
  Overrides change what the guest reads, never the file; SRM writes 17h back at each start, so the file follows a forced
  value after one boot. `tools/nvr_cmos.py` pads/sets both; `tb_cmos` (43 checks).
- **2026-11-11: baseline survey on `_20261111a` (.143, 128 MB):** OpenVMS 6.2/7.3/8.4 (DECwindows on the TGA on all
  three), Tru64 4.0G and **5.1B-4** (CDE; 5.1B runs fully for the first time), NetBSD 10.2, FreeBSD 4.6 (SRM console
  Serial), NT 4.0 Workstation and TSE, Windows 2000 Server all boot, log in and shut down (`docs/gaps.md`, the baseline
  row). Open: NetBSD rejects the TOY ("preposterous TOD clock time") and writes a stale date back; SRM text after a
  NetBSD halt is garbled. The OpenVMS SYSTEM passwords are the same on all three disks (`scratch/os_credentials.txt`);
  the Tru64 PAKs are still to be loaded (user). Backups of the OpenVMS disks and NVRAM files are ZIPs in `C:\temp`.
- **2026-11-11: CPU speed, branch `cpu-perf`** (`docs/design/cpu-perf.md`): the write buffer (`_20261111b`), then FP operations
  flowing through the FPU and branch prediction in F2 (`6650af2`, board build **`_20261111c`**, -2.472 ns, 37.5k ALMs): ubench on NT
  Dhrystone 132422 lps (index 11.3), Whetstone 49.8 MWIPS (9.1); `make -C verilator perf / fpstress / bpstress / wbstress`.
  `tb_sio`'s two TOY time/date checks fail (the bench expects BCD; not a CPU matter).
- **2026-11-11: timing, two rounds on `cpu-perf`** (`60eea26`, `10aee62` = board build **`_20261111d`**): -2.472 -> -1.737 ->
  -2.108 ns, TNS -1511 -> -616; 37.2k ALMs (89 %). Not closed: a routing-dominated wall across modules, +-0.4 ns of fit noise
  (`docs/design/cpu-timing.md`: area reduction, the DTB / D-cache hit path, fitter seeds are next). SRM, NT 4.0 and ubench as on `c`.
- **2026-11-12: area round** (`a4ed6a4` = board build **`_20261112b`**): the DMA's registers and the TOY's CMOS in MLAB register
  files (`rtl/sio/isa_lutram.v`, needs `no_rw_check`), checked against the old modules cycle by cycle (`scratch/area/eq.sh`):
  36.5k ALMs (87 %), -1.487 ns, TNS -913. **COM2 has to stay: SRM hangs after the DROM's POST without it** (`_20261112a`, retired
  to `rbf_old`). SRM, ARC, NT 4.0 and ubench checked on .143; floppy not on the board.
- **2026-11-12: MIDI on NT 4.0 "doesn't sound correct" (user).** Not from the area round: canyon.mid recorded off HDMI is the same
  on `_20261111d` and `_20261112b`. Fixed: the OPL's 49.7 kHz samples were held into the 48 kHz mix (images 1716 Hz around every
  partial); `opl_isa` now interpolates (`c4fc2ce` = board build **`_20261112c`**, -1.921 ns, 36.4k ALMs; images -20 -> -31 dB on
  the board). Still different from the real machine: the FM is an OPL2, so NT plays in AdLib mode (`docs/gaps.md`).
  `misterkvms-cli record 60s X.wav` + `scratch/area/vid/img.py` / `env.py` measure it.
- **2026-11-12: the FM is an OPL3** (user: "I think I'm used to OPL3"): Greg Taylor's opl3_fpga (ao486_MiSTer's, LGPL-3,
  SystemVerilog kept as it is in `rtl/audio/opl3_fpga/`) on CLK_AUDIO behind `opl_isa.v`, stereo (`3acc56a` = `_20261112d`).
  NT 4.0 finds an OPL3 only if timer 1 starts through 38Ah/38Bh while NEW = 0: `opl_isa` maps that to bank 0 (`a6eec86` =
  board build **`_20261112e`**, -1.479 ns, 36.9k ALMs). canyon.mid on `e`: another rendering than AdLib mode, no hung note,
  both channels equal; to be judged by ear (`docs/design/audio.md` 3). In the Run box the KVM's `type` drops backslashes:
  use `d:/winnt/media/...`.
- **2026-11-12: the board cache** (user's plan of 2026-11-12, item 2: "implement if it pays"): `rtl/apecs/bcache.v`, 256 KB
  in block RAM on the 21071's DRAM port, write-through, OSD Advanced > Board cache On (default) / Off (status 19)
  (`7002bad` = board build **`_20261112f`**, -2.127 ns, 37.2k ALMs, 505 of 553 M10K). NT ubench On / Off on .143: Dhrystone
  152985 / 131499 lps, Whetstone 52.4 / 49.5 MWIPS. **Dual issue evaluated and not built** (area, timing;
  `docs/design/cpu-perf.md` 7). The NVRAM image's save to the SD card was checked on the board.
- **2026-11-12: XFree86's accelerated `tga` driver** (plan item 5, FreeBSD 5.2.1 only): it draws with the address register 03C
  and the continue register 04C alone; `tga.v` took every 04C as a line continuation. Outside the line modes 04C now does the
  mode's frame buffer operation at 03C (`c18718a` = board build **`_20261112g`**, -1.560 ns, TNS -358, 37.3k ALMs; `tb_tga`
  section 5b). **On .92 X draws with XAA** (xdm, Xfce 4, xterms; x11perf fills 5 to 30 times NoAccel's, text twice), but the
  engine's copies are 3 to 4 times slower than software ones (`docs/gaps.md`): the 5.2.1 image on .92 runs XAA with
  `XaaNoScreenToScreenCopy` and `XaaNoOffscreenPixmaps` (`/etc/X11/XF86Config.noaccel`, `.accel`, `.accel2` kept). Its root
  password is empty (the login still asks: Enter).
- **2026-11-12: the copies are slow because of the driver's divisions** (`TGACopyLineForwards` divides by the bytes per pixel;
  libc's millicode costs 600-1200 cycles, the engine's pair 224): the CPU is the place to work. **A branch right behind its
  operand's producer no longer waits** (carry-free zero test, `cb294b3` = board build **`_20261112h`**, -2.484 ns, 37.4k ALMs;
  `docs/design/cpu-perf.md` 8): division -16 % on the board. **100 MHz timing closure is not a goal** (user): judge changes by the
  board running them. **The taken-branch bubble is gone**: a 256-entry branch target buffer beside the I-cache, confirmed in F2
  (`0ab78dd` = board build **`_20261112i`**, -1.535 ns, 37.6k ALMs; `cpu-perf.md` 9): division 546 -> 477 cycles, the tga
  driver's copy pair 2652 -> 2385 on .92.
- **Fits run in this checkout, on the working branch, one at a time; no git worktrees** (user, 2026-11-09;
  the earlier `../DECAlphaStation200_fit` worktree is retired). Commit first, then fit, then edit again; never
  queue or chain fits: look at a fit's result before deciding the next build.

**`docs/gaps.md` is the list of missing hardware and features (user, 2026-11-01): keep it current
when a gap is found or closed.**

## Rules carried over from the user's other cores

- Commit often in small steps (local commits; never push without asking).
- One Quartus fit at a time on the Linux box (14 GB, 6 cores; Quartus does not run on macOS). Before a fit check
  `pgrep -a quartus` and the DSPPC603/Pippin session (it has priority). Launch
  with `setsid nohup quartus_sh --flow compile DECAlphaStation200 > fit.log 2>&1 < /dev/null &`.
  Never edit `files.qip`/QSF/SDC while a fit runs.
- Never delete files without asking.
- Third-party material (ROMs, manuals, ISOs, Microsoft binaries) stays in `scratch/`, never in git.
- Verilator treats a comment starting with the word "Verilator" as a directive: don't start comments with it.
