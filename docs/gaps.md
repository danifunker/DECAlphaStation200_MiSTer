# Gaps: hardware and features still to add

The running list of what the core lacks, against the locked configuration in `docs/CORE_SPEC.md`.
Update it whenever a gap is found or closed (date and commit). Details live in the design docs
named in each row; this file is the index.

Status: **open**, **partial** (exists but incomplete), **stub** (answers probes, does nothing).
Priority: **P1** blocks SRM booting to `>>>` on COM1; **P2** needed to boot an OS from disk;
**P3** completeness (other OSes, ARC/NT, peripherals); **P4** nice to have.

## CPU (21064, `rtl/cpu/ev4_core.v`, `docs/design/cpu.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| ~~FPU: FP register file, LDS/LDT/STS/STT, LDF/LDG/STF/STG~~ | **done** 2026-11-01 | P1 | One 64-entry register file (F = 32-63); T3 `t3_fp`. Found as: SRM's PALcode state save (`STT $f0..` at 0xF2F4) trapped OPCDEC and looped |
| ~~FPU: CPYS/CPYSN/CPYSE, FCMOVxx, MT_FPCR/MF_FPCR, FP branches, CVTLQ/CVTQL~~ | **done** 2026-11-01 | P1 | T3 `t3_fp`; CVTQL/V's IOV flag not yet set |
| ~~FPU: IEEE add/sub/mul/div/compare/convert (S, T), traps, FPCR, EXC_SUM~~ | **done** 2026-11-01 | P1/P2 | `rtl/cpu/ev4_fpu.v` (agent; 6.66M vectors) integrated: X waits for the unit (6 / 30 / 59 cycles); EXC_SUM + write mask; T3 `t3_fparith`. Pipelined issue later |
| ~~FPU: VAX F/G/D arithmetic~~ | **done** 2026-11-01 | P2 | In `ev4_fpu.v` (model-checked; QEMU's VAX FP is broken) |
| FPU: pipelined issue (scoreboard, imprecise traps across the shadow) | open | P3 | The unit accepts one non-divide per cycle; the first integration holds X until done (fpu.md 4.5) |
| Machine checks: BIU_STAT/BIU_ADDR/FILL_* latching, MCHK entry, irq_h[0] (21071 errors) | stub | P2 | Error registers read 0; no MCHK is ever raised |
| Performance counters (PC0/PC1 interrupts, PCMUX) | open | P3 | ICCSR fields stored only |
| SLR (serial-line interrupt), CRR | open | P3 | |
| ABOX_CTL WB_DIS, EMD_EN (big-endian), DC_FHIT | open | P4 | Diagnostic |
| Branch prediction (BHT/BTB), dual issue | open | P3 | Performance only; static rule today |
| ~~Block (32-byte) bus transfers~~ | **done** 2026-11-01 | P3 | Cache fills are line reads: one SDRAM ACTIVE and two 8-beat READs, 4 quadword acks (`mem_line` -> `c_line` -> `d_line`); tb_sdram covers them |
| A board cache (Bcache) | open | P4 | |
| BIU_CTL / Bcache registers | partial | P4 | Stored as shadows only; no Bcache |
| Timing: 100 MHz full-system closure | partial | P2 | Build 16 (`53584d1`): -1.897 ns, 33.9k ALMs (81%); runs on the board regardless (`cpu-timing.md`) |

## Firmware path (`docs/design/srom.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| The original SROM (XC1765D at E23) | open | P4 | Not dumped anywhere; our replacement runs. Drop-in as a bitstream |
| SROM J1 mini-console, serial progress output, beep codes, flash fallback | open | P4 | srom.md S7 |
| Console choice SRM/ARC (TOY CMOS byte 3Fh) | **done** 2026-11-01 | P2 | OSD P1 "Console: SRM/ARC" presets 3Fh at reset; the rest of the CMOS is still volatile |
| ARC 4.59 as a flash option | open | P4 | Update image only; chip check bytes unknown |

## 21071 core logic (`rtl/apecs/apecs.v`, `docs/design/pci.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| ~~SRM's `show config` lists no PCI devices~~ | **done** 2026-11-01 | P1 | DCSR<31> (pass 2) read 0, so SRM used pass-1 raw IDSEL addresses; now 1. SRM lists the NCR 810 (pka0) and the SIO |
| ~~DMA scatter/gather (TLB, TBIA)~~ | **done** 2026-11-01 | P2 | 8 KB map entries, 8-entry round-robin TLB, TBIA; direct windows' translated base fixed (was one bit high); `make -C verilator tb_apecs` |
| Error reporting (EDSR/PEAR/SEAR, master-abort bits, error interrupt to irq_h[0]) | partial | P2 | DCSR ndev_err (CPU master abort, with the PCI command) and ptl_inv (invalid S/G entry), PEAR, RW1C (2026-11-01). No error interrupt or machine check yet; SEAR, the CA's EDSR errors not raised |
| ~~D-cache invalidation on DMA writes (dInvReq)~~ | **done** 2026-11-01 | P1 | apecs sends PA[12:5] of every DMA write, the core invalidates that line. Found as SRM's "bad SCSI status (b8)" at `boot dka400` (stale cached status byte and buffer) |
| PCI type-1 configuration (bus != 0) | open | P4 | No bridges in this config |
| Sparse-memory HAXR1 high bits, dense-memory quadword ordering | partial | P3 | SRM's and Linux's TGA drivers use dense longwords only (tga.md 1); the TGA handles any byte enables |

## SCSI (`rtl/scsi/`, `docs/design/scsi.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| Targets (disk ID 0/1, CD ID 4) on hps_io block devices | partial | P1/P2 | Wired in `as200_sys` and the top (2026-11-01); SRM lists dka400 on the board. The command set for SRM/NT/Unix was done 2026-11-01 (`64d57ae`: TOC 0/1/2, sub-channel, media change, NOT READY, READ CD, the (12) forms, mode pages). `cd_change` wired from `img_mounted[2]`. Hard-disk images not yet tried on the board |
| ~~Main_MiSTer support (write buffering, CD layer) on branch `dec-alphastation`~~ | **done** 2026-11-01 | P2 | `support/decalpha` (Main `3520ddd`): ISO/CUE/BIN/CHD, the track table, audio frames, the disk write buffer. On the board since build 15; with the Ethernet bridge since 2026-11-01 (consolidated `e9ffb24`). The disk write buffer is untested (no disk image mounted yet) |
| Disconnect/reselect, target mode, parity, DMA FIFO, SEL/RSL/CMP interrupts | open | P3 | scsi.md 4 |
| CD audio | partial | P4 | `rtl/scsi/cd_audio.v`: PLAY/PAUSE/STOP, page 0E, into the mixer (build 15). Not yet heard on the board. Limits: `cdrom.md` 4 |

## SIO and ISA (`rtl/sio/`, `docs/design/sio.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| Flashbus NVRAM persistence (SRM env vars, ISA table) | partial | P2 | `rtl/mister/nvsave.v` on OSD slot SC4 (8 KB file): load on mount, save 2 s after a change (2026-11-01); board test pending |
| TOY CMOS persistence (beyond 3Fh) | open | P3 | |
| ~~Floppy controller (82077AA in the PC87332), drive A on an image~~ | **done** 2026-11-01 | P3 | `rtl/sio/isa_fdc.v`, `isa_fdc_img.v` (`floppy.md`): every 82077AA command, DMA and non-DMA, media change, write protect, 720K-2.88M; `tb_fdc` (172 checks) and DROM V1.7's J2 floppy loader in `tb_sio_drom_floppy`. In the machine (`b57521b`, OSD slot 3); SRM lists dva0 on the board (build 16); not yet read from an image there |
| ~~DMA window 1 at PCI 1 GB from the SROM (DROM floppy boot)~~ | **done** 2026-11-01 | P3 | The SROM opens window 1 (PCI 4000.0000 + 1 GB -> PA 0) (`b57521b`) |
| Floppy: overrun, deleted marks, non-standard formats, FIFO threshold | open | P4 | floppy.md 6 |
| TOY year base for SRM vs ARC/NT | open | P3 | `year_ovr` gives OSD control meanwhile |
| Parallel port EPP/ECP, interrupt | open | P4 | |
| ISA memory cycles, 16-bit I/O cycles, port 92h, IRQ13 | open | P4 | sio.md 5 |

## Flashbus (`rtl/mister/fbrom.v`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| 28F020 command set (ID read, erase, program, verify) | **done** 2026-11-02 | P2 | `rtl/apecs/flash28f020.v` (`e88411e`): ID 89/BD, program, chip erase, verify; J6 (OSD P5) as write protect. ARC writes the flash at start-up: before, those commands landed in the image as data and SRM's next boot failed DROM's checksum |
| Flash changes saved back to the SD card | open | P2 | Anything ARC stores in flash is lost at power-off until fbrom writes boot0.rom back |

## Devices not built yet (CORE_SPEC)

| Device | Status | Pri | Notes |
|---|---|---|---|
| **TGA graphics** (ZLXp-E1: DECchip 21030, 2 MB VRAM in DDR3, Bt485 RAMDAC) | partial | P2 | `rtl/tga/` + `rtl/mister/ddr3_arb.v`, `docs/design/tga.md`: in the machine as PCI device 12 (`0a4d3f6`). **Board build 16: SRM's graphics console runs on it**, NetBSD's kernel reprograms it. Missing: pixel shift, line and Z modes, the TGA cursor, ICS1562 (no pixel clock above 65 MHz) |
| DECchip 21040 Ethernet (+ Ethernet ID ROM) | partial | P3 | `rtl/net/tulip21040.v` + `tulip_nb.v`, `docs/design/ethernet.md`: PCI device 11 (`a25bdb2`), OSD Network interface; SRM lists ewa0 (build 16). Main's bridge installed on the board 2026-11-01; no traffic tested yet |
| 21040: error conditions, the guest's own station address for Main's filter, external loopback to the wire | open | P4 | ethernet.md 9 |
| Sound: AD1848 (WSS 530h; SRM's PCXBJ: IRQ 9, DMA 0/1) | partial | P4 | `rtl/audio/wss_ad1848.v`, `docs/design/audio.md`: in the machine since build 15 (playback by DMA, IRQ; capture is silence). Not yet heard on the board (needs an OS driver) |
| FM at 388h: an OPL2 (jtopl2) in place of the OPL3 | partial | P4 | `rtl/audio/opl_isa.v`: bank 1 (38Ah/38Bh) dropped, OPL2 status, so OPL3 detection finds an OPL2. A real OPL3 when jtopl's YMF262 exists |
| ~~Speaker (8254 counter 2) to the audio mix~~ | **done** build 15 | P4 | `audio_mix.v` |
| Audio mix to the MiSTer (WSS + FM + CD + speaker) | partial | P4 | Wired (build 15, `audio_cdc.v`); no OSD P4 Audio page yet (volume/mute; `mute[3:0]` is ready) |
| COM2 on a MiSTer pin | open | P4 | |
| PS/2 keyboard and mouse into the 8242 from hps_io | partial | P2 | Wired into the SIO; the top still also types the keyboard into COM1 |

## MiSTer integration

| Gap | Status | Pri | Notes |
|---|---|---|---|
| OSD options wired to the machine (memory size, jumpers, year) | partial | P3 | cfg_mem, J1/J2 and the year override are; check the rest against the status map |
| Load ROM (replace boot0.rom for the session) | open | P4 | |
| ~~Video: TGA or the terminal~~ | **done** 2026-11-01 | P2 | `tga_vsel` in the top: OSD Display Graphics shows the TGA once it has video on, else the terminal |

## Operating systems (targets, 2026-11-01; images on the board in `games/DECAlphaStation200/`)

The 21064's TBs hold no ASN (HRM 2.3.2): PALcode clears the ASM=0 entries on a context switch, and the
I-cache compares physical tags after translation, so no ASN support is needed.

| OS | Console | Last version for the AS200 4/100 | Status |
|---|---|---|---|
| Windows NT 4.0 (Workstation SP1, TSE 4.0) | ARC | 4.0 (Compaq never qualified SP6, but it runs) | **Installed and boots to the desktop (2026-11-03, core `a6e76de`)**; image backup `NT4_2GB.installed-20261103.img.bak`. Open: GUI redraw leaves stale strips (save-under/copy, likely the TGA pixel shift), the time-zone map draws striped. Text-mode Setup installs to a 2 GB disk (FAT system partition + NTFS) and draws correctly since the ddr3_arb read-after-write fix (`2880d57`). GUI Setup rebooted 5 s in: every process winlogon started (services, lsass, setup) faulted fetching kernel32!BaseProcessStart because the CPU took the ITB miss before the pending APC interrupt that runs the loader (`a5838b1`; found with `tools/ntkd.py`, a KD client). TSE hangs at the kernel banner |
| Windows NT 3.51 | ARC | | First target |
| Windows 2000 RC1 (2072) | ARC | Betas/RCs only | Hangs at "Setup is starting Windows 2000" in KiAttachProcess's ready-list loop (a self-linked entry; 64 and 128 MB alike). Candidates fixed 2026-11-02: lost fetch restart (`7fafad8`), lock flag kept across I/O writes (`a83a956`) |
| OpenVMS | SRM | HP V8.4 (its release notes still carry an AS200/400 note); VSI 8.4-2L1/2L2 drop it. Min V6.1-1H1 | Images 6.2, 7.3, 8.4 |
| Digital UNIX / Tru64 | SRM | 5.1B-6 (needs 128 MB); min 3.2 | Image 4.0G |
| NetBSD 10.2 | SRM | current | Kernel starts, hangs after "Unrecognized boot flag" |
| FreeBSD | SRM | 6.x (alpha dropped after) | |
| OpenBSD | SRM | current | |
