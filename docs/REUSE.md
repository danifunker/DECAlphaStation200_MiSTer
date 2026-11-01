# What comes from the user's other MiSTer cores

Survey of 2026-10-31 (`../` = `/home/dani/repos`). Everything listed is
SystemVerilog unless noted, so each block is **ported to plain Verilog** as
it comes in (`logic` -> `reg`/`wire`, `always_ff`/`always_comb`, functions
without `return`, no packages). Licences: hp9000-715, IBMRS6K42p, Quadra and
PPC7300 are GPL-2; SS20 is GPL-2.0-or-later; SGI Indy is GPL-3.

**The closest relative is the IBM RS/6000 7248 core (`../IBMRS6K42p`)**: a
PReP machine with a 53C810 and the same 82378-style SIO device set, all PCI,
and it boots AIX on the board. Its local checkout is 132 commits behind
`origin/master`; read it with `git -C ../IBMRS6K42p show origin/master:<path>`
(DMA, FDC image, NVRAM save, OPL, PCnet exist only upstream).

## Plan by block

| AS200 block | Source | Work for the AS200 |
|---|---|---|
| **NCR 53C810** (IDSEL AD17, PIRQ3) | `IBMRS6K42p/rtl/machine/IBMRS6K7248_ncr810.sv` (737 lines; itself from `hp9000-715/rtl/scsi/ncr53c710.sv`) | Register map 00-5F, SIST/SIEN, the register operators, INTFLY, little-endian SCRIPTS, PCI config + BAR0 I/O already there. Missing: LOAD/STORE, BAR1 memory decode, reselection, timers but selection, FIFO -- SRM's, Linux sym53c8xx's, NT's and VMS's drivers will need LOAD/STORE and BAR1 at least. Its DMA goes behind the 21071-DA scatter/gather window. |
| **SCSI targets** (HDD ID 0, 1; CD-ROM ID 4) | `IBMRS6K42p/.../IBMRS6K7248_scsitgt.sv` (dual clock, hps_io block devices) | IDs 0/1/4. CD audio: bring `hp9000-715/rtl/scsi/cd_audio.sv` back (the RS6K dropped PLAY). |
| 8259 x2 + ELCR | `IBMRS6K7248_pic.sv` | 82378 PIRQ routing; INTACK cycle for PALcode; IRQ wiring of HARDWARE.md 3 |
| 8254 + port 61 | `IBMRS6K7248_pit.sv` | Drop-in (CLK_HZ parameter); counter 2 to the speaker |
| 8237 x2 + page registers | `IBMRS6K7248_dma.sv` (upstream only) | 82378-style already |
| BQ4285 RTC | `IBMRS6K7248_rtc.sv` (MC146818) | Periodic interrupt to **CPU IRQ4** (not the PIC); the OSD year override |
| 8242 + PS/2 | `IBMRS6K7248_kbc.sv` (alt: SGI `i8042.sv`, hp715 `ps2_dev.sv`) | KBRST to CPU IRQ5 |
| COM1/COM2 | `rtl/sio/ns16550.v` (ours, done) | -- |
| FDC (82077-class) + image | `IBMRS6K7248_fdc.sv` + `rtl/IBMRS6K7248_fdimg.sv` | 1.44 MB drive A |
| PC87332 config, LPT | `IBMRS6K7248_sio.sv` (written for the PC87312) | 87332 register differences |
| AD1848 WSS + OPL3 | `IBMRS6K7248_cs4232.sv` (CS4231 is an AD1848 superset), `IBMRS6K7248_opl.sv` + jtopl (`.v`, OPL2 only) | Low priority |
| PCI config / host bridge | RS6K `_mpc105.sv`, `_firecoral.sv`, CF8/CFC decode; `MacPPC7300_MiSTer/rtl/machine/MacPPC7300_pcicfg.sv` | Templates only: the 21071-DA (sparse/dense spaces, S/G TLB, IACK) is new work |
| 21040 Tulip | none exists | New. The Main-side bridge: RS6K `_enetbox.sv` + `_ddrarb.sv`, or SS20 `rtl/mister/eth_hps.sv`; `support/*_enet.cpp` |
| SDRAM | RS6K `IBMRS6K7248_sdram.sv` (99 MHz BL8 CL2, board-tested); `hp9000-715/rtl/mister/sdram64.sv`; SS20 `rtl/mister/sdram64.sv` (two ranks) | Little-endian byte lanes; two ranks for 128 MB |
| Flashbus NVRAM to SD | RS6K `rtl/IBMRS6K7248_nvsave.sv`; hp715 `rtl/mister/eeprom_save.sv`; SS20 `rtl/mister/nvram_sd.sv` | 8 KB |
| Debug | hp715 `rtl/mister/trace_ddr3.sv` + `tools/mister/trace_dump.py`, `ddr3_port.sv`, `tools/mister/board.sh` | Directly reusable |
| Simulation | hp715 `verilator/romsim/tb_rom.cpp` (`--until/--type/--disk/--cd/--snapshot`), RS6K `sim/` (`tb_main.cpp`, `sdram_chip.h`, per-device benches), Sun-3 `tb/verilator/hps_io_model.sv` | Grow `verilator/sim_main.cpp` along these lines |

## DEC's own sources (reference only, `scratch/ebsdk`)

The Alpha evaluation-board SDK (github.com/jramstedt/ebsdk) has DEC's SRM V5.8 reference sources
for this platform's devices. They are DEC-licensed, so they stay in `scratch/`: read them for
behaviour and register usage, never copy them into the core. `sw/apisrm/ref/`: `avanti.sdl`,
`apecs_def.sdl` (21071 CSRs), `i82378_def.h`, `n810_driver.c` + `n810_script*.mar` (what SRM asks of
the 53C810: the SCRIPTS it runs), `tga_driver*.c` + `tga_sfbp_485.h` (what SRM asks of the TGA and
Bt485), `pal_ev4.mar` (EV4 PALcode), `srom_def.h`; `ebfw/`: the EB64+/AlphaPC64 APECS memory setup.

## AXPbox (reference only, `scratch/axpbox`)

The ES40 emulator (github.com/lenticularis39/axpbox, GPL-2; 21264 + Tsunami + ALi M1543C), so it
cannot run the AS200's EV4 firmware. Its models are a behavioural reference where they overlap ours:
`Sym53C810.cpp` + `SCSIBus.cpp`/`SCSIDevice.cpp`/`DiskDevice.cpp` (the 53C810 and targets as DEC's
SRM and the OSes drive them), `AlphaCPU_ieeefloat.cpp` / `AlphaCPU_vaxfloat.cpp` (FPU behaviour,
rounding and traps, VAX F/G/D), `AliM1543C.cpp` (8259, 8254, RTC, 8042), `FloppyController.cpp`,
`DEC21143.cpp` (close to the AS200's 21040), `Flash.cpp`. Its S3/Cirrus VGA models are not used:
the core's graphics is the TGA (ZLXp-E1, CORE_SPEC).

## AAE (reference only, `scratch/aae`)

AAE "Bronze Edition" 0.0.2 (2006, GPL-2): an unfinished C emulator for the EB66+. Useful as one more
reading of EV4 details next to the HRM, QEMU and our `tools/alphaemu`: `src/emu/21064.h` (IPR
layouts), `src/emu/21071.h` (21071-CA/DA CSR bitfields), `src/emu/execute.c` (CALL_PAL, HW_*
instructions, TB handling). No floating point and no device models beyond headers.

## ASA-EMulatR (reference only, `scratch/emulatr`)

github.com/timothyPeer/EmulatRAppUni (GPL-3 per its README): an ES40 / 21264 emulator in progress
(Qt 6, Windows), aiming to boot Tru64/VMS/Linux. Same platform limits as AXPbox; its FP grains
(`grainFactoryLib`, `coreLib/IEEE754_FloatConversion_inl.h`) and `controllersLib` SCSI/SCRIPTS
classes are a third reading where AXPbox and the manuals disagree. Lower confidence than AXPbox.

## Main_MiSTer

Branch `dec-alphastation` (off `master`). Clone the family support code as
`support/decalpha/`, gated on the core name: the disk write buffer
(`support/hp9k/hp9k_disk.cpp` on `hp9k-family`, `support/ibmrs6k/ibmrs6k_disk.cpp`
on `origin/ibmrs6k`), the CD slot (CUE/BIN, CHD, track table, CD-audio
windows: `*_cdrom.cpp`), later Ethernet (`*_enet.cpp`).

## Other SCSI chips (not 53C8xx relatives; their target/cache code can be mined)

SS20 `esp.sv`, Pippin/PPC7300 `sc53c94.sv`, Quadra `ncr53c96.sv` + `scsi_cache.sv`,
SGI `wd33c93.sv` + `scsi_cache.sv`, Mac `ncr5380.sv`, Sun-2/3 wish5380 targets.
