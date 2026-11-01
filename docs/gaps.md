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
| Block (32-byte) bus transfers, a board cache (Bcache) | open | P3 | Performance: each miss is 4 single quadword requests |
| BIU_CTL / Bcache registers | partial | P4 | Stored as shadows only; no Bcache |
| ITB/DTB: ASN tagging | partial | P2 | Entries have ASM only; no ASN compare (cpu.md 6.5) |
| Timing: 100 MHz full-system closure | partial | P2 | Last fit -1.244 ns (`cpu-timing.md`) |

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
| Error reporting (EDSR/PEAR/SEAR, master-abort bits, error interrupt to irq_h[0]) | stub | P2 | |
| ~~D-cache invalidation on DMA writes (dInvReq)~~ | **done** 2026-11-01 | P1 | apecs sends PA[12:5] of every DMA write, the core invalidates that line. Found as SRM's "bad SCSI status (b8)" at `boot dka400` (stale cached status byte and buffer) |
| PCI type-1 configuration (bus != 0) | open | P4 | No bridges in this config |
| Sparse-memory HAXR1 high bits, dense-memory quadword ordering | partial | P3 | Check against the TGA's use |

## SCSI (`rtl/scsi/`, `docs/design/scsi.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| Targets (disk ID 0/1, CD ID 4) on hps_io block devices | partial | P1/P2 | Wired in `as200_sys` and the top (2026-11-01); SRM lists dka400 on the board. The command set for SRM/NT/Unix was done 2026-11-01 (`64d57ae`: TOC 0/1/2, sub-channel, media change, NOT READY, READ CD, the (12) forms, mode pages). `cd_change` is still to be wired from `img_mounted[2]` |
| ~~Main_MiSTer support (write buffering, CD layer) on branch `dec-alphastation`~~ | **done** 2026-11-01 | P2 | `support/decalpha` (Main `3520ddd`): ISO/CUE/BIN/CHD, the track table, audio frames, the disk write buffer. It builds; the board test is pending (`cdrom.md`) |
| Disconnect/reselect, target mode, parity, DMA FIFO, SEL/RSL/CMP interrupts | open | P3 | scsi.md 4 |
| CD audio | partial | P4 | `rtl/scsi/cd_audio.v` (2026-11-01, `64d57ae`): PLAY/PAUSE/STOP, page 0E, `cd_audio_l/r/stb` checked in the bench. Its outputs are to replace the ties at the mixer (audio.md 4). Limits: `cdrom.md` 4 |

## SIO and ISA (`rtl/sio/`, `docs/design/sio.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| Flashbus NVRAM persistence (SRM env vars, ISA table) | partial | P2 | `rtl/mister/nvsave.v` on OSD slot SC4 (8 KB file): load on mount, save 2 s after a change (2026-11-01); board test pending |
| TOY CMOS persistence (beyond 3Fh) | open | P3 | |
| Floppy controller (82077AA in the PC87332), drive A on an image | stub | P3 | Firmware updates, DROM floppy boot (J2) |
| TOY year base for SRM vs ARC/NT | open | P3 | `year_ovr` gives OSD control meanwhile |
| Parallel port EPP/ECP, interrupt | open | P4 | |
| ISA memory cycles, 16-bit I/O cycles, port 92h, IRQ13 | open | P4 | sio.md 5 |

## Flashbus (`rtl/mister/fbrom.v`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| 28F020 command set (ID read, erase, program, status) | stub | P3 | Writes go straight into DDR3; SRM/ARC flash updates and the ARC NVRAM area need the command set |
| Flash changes saved back to the SD card | open | P3 | |

## Devices not built yet (CORE_SPEC)

| Device | Status | Pri | Notes |
|---|---|---|---|
| **TGA graphics** (ZLXp-E1: DECchip 21030, 2 MB VRAM in DDR3, Bt485 RAMDAC, PCI slot 1) | open | P2 | The chosen video card; SRM console on the screen, NT/X11. Confirm the RAMDAC (CORE_SPEC open item 3) |
| DECchip 21040 Ethernet (+ Ethernet ID ROM) | open | P3 | May start as present-but-no-link; AXPbox `DEC21143.cpp` as reference |
| Sound: AD1848 (WSS 530h, IRQ/DMA by its command register; SRM's PCXBJ: IRQ 9, DMA 0/1) | partial | P4 | `rtl/audio/wss_ad1848.v`, `docs/design/audio.md` (2026-11-01): registers, playback by DMA, IRQ, capture as silence; unit bench `tb_audio`. Not yet wired into `as200_sys` / the top |
| FM at 388h: an OPL2 (jtopl2) in place of the OPL3 | partial | P4 | `rtl/audio/opl_isa.v`: bank 1 (38Ah/38Bh) dropped, OPL2 status, so OPL3 detection finds an OPL2. A real OPL3 when jtopl's YMF262 exists |
| Speaker (8254 counter 2) to the audio mix | partial | P4 | `rtl/audio/audio_mix.v` averages it per 48 kHz period; not yet wired |
| Audio mix to the MiSTer (WSS + FM + CD + speaker, `audio_cdc.v` into CLK_AUDIO) | partial | P4 | Built and bench-tested; integration steps in audio.md 5; no OSD volume/mute page yet (`mute[3:0]` is ready) |
| COM2 on a MiSTer pin | open | P4 | |
| PS/2 keyboard and mouse into the 8242 from hps_io | partial | P2 | Wired into the SIO; the top still also types the keyboard into COM1 |

## MiSTer integration

| Gap | Status | Pri | Notes |
|---|---|---|---|
| OSD options wired to the machine (memory size, jumpers, year) | partial | P3 | cfg_mem, J1/J2 and the year override are; check the rest against the status map |
| Load ROM (replace boot0.rom for the session) | open | P4 | |
| Video: the terminal (SROM port, COM1, LEDs) until TGA | partial | P2 | Replace/overlay with TGA output |
