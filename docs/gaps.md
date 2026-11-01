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
| FPU: IEEE add/sub/mul/div/compare/convert (S, T), traps, FPCR, EXC_SUM | open | P1/P2 | Pipelined per `pipeline.md` 6; reference: AXPbox `AlphaCPU_ieeefloat.cpp` |
| FPU: VAX F/G/D arithmetic | open | P2 | OpenVMS; AXPbox `AlphaCPU_vaxfloat.cpp` |
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
| Console choice SRM/ARC (TOY CMOS byte 3Fh) lost on each core load | open | P2 | Needs CMOS save (below) or an OSD option that presets 3Fh |
| ARC 4.59 as a flash option | open | P4 | Update image only; chip check bytes unknown |

## 21071 core logic (`rtl/apecs/apecs.v`, `docs/design/pci.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| DMA scatter/gather (TLB, TBIA) | stub | P2 | Direct-mapped windows only; Digital UNIX and others use S/G |
| Error reporting (EDSR/PEAR/SEAR, master-abort bits, error interrupt to irq_h[0]) | stub | P2 | |
| D-cache invalidation on DMA writes (dInvReq) | open | P2 | Required once disks DMA into memory the CPU has cached |
| PCI type-1 configuration (bus != 0) | open | P4 | No bridges in this config |
| Sparse-memory HAXR1 high bits, dense-memory quadword ordering | partial | P3 | Check against the TGA's use |

## SCSI (`rtl/scsi/`, `docs/design/scsi.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| Targets (disk ID 0/1, CD ID 4) not wired to hps_io block devices in the top | open | P1/P2 | `scsi_targets.v` exists and is bench-tested |
| Main_MiSTer support (write buffering, CD layer) on branch `dec-alphastation` | open | P2 | Like `support/hp9k`, `support/ibmrs6k` |
| Disconnect/reselect, target mode, parity, DMA FIFO, SEL/RSL/CMP interrupts | open | P3 | scsi.md 4 |
| CD audio | open | P4 | `hp9000-715/rtl/scsi/cd_audio.sv` |

## SIO and ISA (`rtl/sio/`, `docs/design/sio.md`)

| Gap | Status | Pri | Notes |
|---|---|---|---|
| CMOS/NVRAM persistence (TOY CMOS and the flashbus NVRAM) | open | P2 | Save to the SD card (like `IBMRS6K7248_nvsave`); NVRAM slot SC4 is reserved in the OSD |
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
| Sound: AD1848 (WSS 530h) + OPL3 (388h) | open | P4 | |
| Speaker (8254 counter 2) to the audio mix | partial | P4 | `speaker` output exists, not mixed |
| COM2 on a MiSTer pin | open | P4 | |
| PS/2 keyboard and mouse into the 8242 from hps_io | partial | P2 | Wired into the SIO; the top still also types the keyboard into COM1 |

## MiSTer integration

| Gap | Status | Pri | Notes |
|---|---|---|---|
| OSD options wired to the machine (memory size, jumpers, year) | partial | P3 | cfg_mem, J1/J2 and the year override are; check the rest against the status map |
| Load ROM (replace boot0.rom for the session) | open | P4 | |
| Video: the terminal (SROM port, COM1, LEDs) until TGA | partial | P2 | Replace/overlay with TGA output |
