# The 82378 SIO and the ISA devices

`rtl/sio/sio82378.v` is the Intel 82378IB System I/O as PCI device 7 (IDSEL AD18), with every ISA
device of the AlphaStation 200 behind it. It implements the interfaces of `docs/design/pci.md`
(sections 2, 3, 4, 5). The ISA devices are ported to Verilog-2001 from the user's IBM RS/6000 7248
core (GPL-2, `IBMRS6K7248_{pic,pit,dma,rtc,kbc,sio}.sv` on `origin/master`). COM1 and COM2 are the
existing `rtl/sio/ns16550.v`.

| File | Contents |
|---|---|
| `sio82378.v` | PCI target (configuration space, IACK, subtractive I/O decode), the ISA bus and its decoder, PIRQ routing, NMI logic, port 92, the UART clock, the device instances |
| `isa_pic.v` | 8259A x2 (`isa_pic_chip`) + ELCR 4D0h/4D1h, the acknowledge |
| `isa_pit.v` | 8254 (`isa_pit_ctr` x3) + port 61h (NMI status and control, speaker) |
| `isa_dma.v` | 8237 x2, page and high-page registers, the 82378's extended mode and scatter/gather registers, the transfer engine on the PCI master port |
| `isa_rtc.v` | BQ4285 TOY (MC146818 registers, 114 bytes of CMOS), set from hps_io's `rtc`, with the OSD year override |
| `isa_kbc.v` | 8242 (8042 host interface) with a PS/2 keyboard and mouse made from hps_io's `ps2_key` / `ps2_mouse` |
| `isa_superio.v` | PC87332 configuration (398h/399h), parallel port; the FDC (`isa_fdc.v`, `isa_fdc_img.v`: docs/design/floppy.md) |
| `verilator/tb/tb_sio.cpp` | unit bench, `make -C verilator tb_sio` (119 checks) |
| `verilator/tb/tb_sio_drom.cpp` | DEC's DROM V1.7 POST against the SIO, `make -C verilator tb_sio_drom` |

## 1. Ports of `sio82378`

Parameters: `CLK_HZ` (100 MHz), `RTC_FAST` (benches only), `DEVNUM` (7), `REVID` (43h).

| Group | Signals | Notes |
|---|---|---|
| PCI target (pci.md 2) | `pt_req pt_cmd[1:0] pt_dev[4:0] pt_addr[31:0] pt_be[3:0] pt_we pt_wdata[31:0]` in; `pt_claim` (combinational), `pt_ack`, `pt_rdata` out | plus **`pt_sub`** in: an I/O cycle that no other device claims. `as200_sys.v` drives it as `pt_req && pt_cmd == 1 && !other_claim`, with `other_claim` excluding the SIO |
| PCI master (pci.md 3) | `dm_req dm_we dm_addr dm_be dm_wdata` out, `dm_ack dm_rdata` in | the ISA DMA |
| Interrupts | `pirq_n[3:0]`, `serr`, `iochk` in; `intr` (CPU IRQ2), `nmi` (IRQ3), `toy_irq` (IRQ4), `kbrst` (OR it with HALT for IRQ5), `spk` out | `serr`/`iochk` are active high. The four CPU lines come straight from flip-flops (one clock of latency) |
| Other ISA devices | `xio_addr xio_rd xio_wr xio_wdata` out, `xio_claim` (combinational from `xio_addr`) and `xio_rdata` in, `xio_irq[15:0]` in, DMA: `xio_dreq[7:0]` in, `xio_dack xio_dack_ch xio_dack_data xio_dma_ch xio_tc` out, `xio_dev_data` in | for the sound card and so on. Same strobe rules as the internal devices. Channel 2 is shared with the FDC |
| Floppy image | `fd_mounted fd_readonly fd_size` in, `fd_lba fd_blk_cnt fd_rd fd_wr` out, `fd_ack fd_buff_addr fd_buff_dout fd_buff_wr` in, `fd_buff_din fd_led` out | hps_io slot 3 (floppy.md 1). Parameter `FD_SPEED` (4) |
| COM1, COM2 | `comN_txd/rxd/rts_n/dtr_n/cts_n/dsr_n/ri_n/dcd_n`; COM1 also has `com1_tx_stb/tx_byte` (vterm) and `com1_rx_inj_stb/byte` (keyboard into the console) | ns16550's own ports |
| Keyboard, mouse | `ps2_key[10:0]`, `ps2_mouse[24:0]` | hps_io format |
| TOY | `rtc[64:0]` (hps_io), `year_ovr_en`, `year_ovr[6:0]` (binary 0-99) | |
| | `lpt_data[7:0]` | the parallel port's data latch |

### PCI target behaviour

- **Claim**: configuration cycles to `pt_dev == 7`, function 0 (`pt_addr[10:8] == 0`).
  Interrupt acknowledge (`pt_cmd == 3`) while PCICON (40h) bit 5 IAE is set. I/O with `pt_sub`.
  Memory is never claimed: there is no ISA memory decode.
- **Configuration**: `pt_ack` follows one cycle after the request is taken. Reads return the whole
  doubleword whatever `pt_be` is. **The DROM needs this**: its ID check is a byte-length sparse read
  of register 0, and it compares 16 bits. Writes honour `pt_be` and each register's writable mask.
- **IACK**: one cycle. `pt_rdata = {24'd0, vector}` is one whole INTA sequence of the 8259 pair:
  the slave's vector through the cascade, or 07h/0Fh when nothing is pending (the spurious vector).
- **I/O**: each enabled byte lane becomes one ISA byte cycle, lowest lane first, at port
  `{pt_addr[15:2], lane}`. So a longword access to 420h writes 420h-423h. Each byte cycle takes one
  clock, and `pt_ack` comes one clock after the last. A port nothing decodes reads FFh.

### Configuration space

Header: vendor 8086h, device 0484h, PCICMD 0007h (I/O, memory and bus master fixed on, special
cycle enable bit 3 writable), PCISTS 0200h (DEVSEL medium), **revision 43h**, class code 000000h
(like the real part; Linux's alpha `quirk_isa_bridge` sets it to ISA bridge), header type 0. The
registers below are read/write with the 82378 data sheet's reset values. The defaults of 40h, 48h
and 4Ch-4Fh are confirmed by DEC's `i82378_def.h`.

| Reg | Name | Reset | Used here |
|---|---|---|---|
| 40 | PCICON | 20h | bit 5 IAE gates the IACK claim |
| 41, 42 | PAC, PAPC | 00h, 04h | stored |
| 44-47 | MEMCS control, bottom/top of hole, top of memory | 00 10 0F 00 | stored. **45h is DROM's "82378 test" register** |
| 48-4B | ISA address decoder | 01 00 10 0F | stored |
| 4C | ICRT | 56h | stored |
| 4D | ISA clock divisor | 40h | stored |
| 4E | UBCSA | 07h | bit 0 decodes the TOY (70h/71h), bit 1 the 8242 (60h/64h) |
| 4F | UBCSB | 4Fh | bit 6 decodes port 92h. The serial/parallel enables are stored only, because the PC87332 decodes its own ports |
| 54-57 | MEMCS attributes | 00h | stored |
| 60-63 | PIRQ0-3 route | 80h | bit 7 disables, bits 3:0 select the IRQ (3-7, 9-12, 14, 15). Writable mask 8Fh |
| 80-81 | BIOS timer base | 0078h | stored (no timer) |
| A0-AF | SMI/power management | A0 = 08h, A8 = 0Fh | stored (no SMI) |

All other offsets read 0, and writes to them are dropped.

## 2. The ISA side

| Port | Device | Decode condition |
|---|---|---|
| 00-0F, 80-8F, C0-DF (even), 40A, 40B, 410-43F, 480-48F, 4D4, 4D6 | `isa_dma` | always |
| 20, 21, A0, A1, 4D0, 4D1 | `isa_pic` | always |
| 40-43, 61 | `isa_pit` | always |
| 60, 64 | `isa_kbc` | UBCSA[1] |
| 70, 71 | `isa_rtc` | UBCSA[0]. A write to 70h also sets the SIO's NMI disable from bit 7 |
| 92 | port 92 (bits 1:0 stored, no effect) | UBCSB[6] |
| 398, 399, LPT (378/3BC/278), FDC (3F0-3F7 except 3F6, or 370) | `isa_superio` | its own FER/FAR |
| COM1/COM2 where FAR places them | `ns16550` x2 | FER[1], FER[2] |
| anything else | `xio_*` | `xio_claim` |

Device bus (pci.md 5): `io_addr[15:0]`, one-cycle `io_rd`/`io_wr` strobes that the SIO's decode
qualifies, `io_din`, and `io_dout` computed combinationally from the state. A read's side effects
happen on the strobe's clock.

**Interrupts** into the 8259s: 0 PIT counter 0, 1 keyboard, 2 cascade, 3 COM2, 4 COM1 (each UART's
`irq` gated by its MCR OUT2, as on a PC), 6 FDC, 7 parallel (never raised), 12 mouse, 13 the DMA's
S/G interrupt (inside the SIO). `xio_irq` is ORed in except on 2, 8 and 13, and so are the routed
PIRQs (active low in, the IRQ line high while asserted, so ELCR must make the line level-sensitive,
as software does). **ISA IRQ8 is not connected**: the TOY interrupt is `toy_irq` = CPU IRQ4
(HARDWARE.md 3).

**NMI**: port 61h bit 7 latches SERR# until bit 2 is set, and bit 6 latches IOCHK# until bit 3 is
set. `nmi` = (bit 7 or bit 6) while port 70h bit 7 is 0. Out of reset port 70h bit 7 is 1 (NMI
disabled).

### Device notes

- **8259** (`isa_pic.v`): everything the RS/6000 model has: ICW1-4 (AEOI, single, LTIM), OCW1-3,
  rotation, special mask, poll, edge/level per line through the ELCR (IRQ0-2, 8 and 13 edge only),
  and the acknowledge as a single operation. **Pipelined for 100 MHz** (the full fit's worst paths
  ran from IRR/IMR/ISR through the priority logic): each cycle, stage 1 registers the highest
  unmasked request and the highest in service (and the non-specific EOI's line). Stage 2 registers
  the request to raise INT for, and that register alone drives INT, the IACK vector, the poll and
  the acknowledge's IRR/ISR updates. A request reaches a chip's INT 3 clocks after its line rises.
  Through the slave and the master that is 6 clocks, plus 1 for the SIO's `intr` flop. For 2 clocks
  after any write, acknowledge or poll, the stale resolution is masked: INT is low, and an
  acknowledge gets the spurious vector. An edge-mode request that falls before the acknowledge
  clears its IRR bit, as on the 8259A (DEC's DROM floppy loader polls IRR 6; floppy.md 4); the
  master's IRQ2 (the cascade) keeps the latch until the acknowledge.
- **8254** (`isa_pit.v`): 1.193182 MHz by phase accumulation, all six modes, latch and read-back,
  counter 2's gate and speaker on port 61h. Mode 3 counts by two down **through 0** before it
  reloads, so the MSB-only polling of DROM's calibration sees 0 for one tick.
- **8237** (`isa_dma.v`): the RS/6000 model with its 64-bit big-endian memory port replaced by the
  32-bit little-endian PCI master port. 8-bit channels use lane `addr[1:0]` and 16-bit channels use
  lanes `{addr[1],0}`. An S/G descriptor is two longword reads: the address, then the count with the
  last flag in bit 31. Addresses carry into the page past 64 KB, as the 82378 does.
- **TOY** (`isa_rtc.v`): MC146818 time, alarm, A-D, UIP, periodic/alarm/update interrupts, 114
  bytes of CMOS (0Eh-7Fh). Each change of `rtc[64]` loads the MiSTer's BCD time (weekday 0-6 from
  Sunday becomes 1-7). `year_ovr_en` replaces the year with `year_ovr` on each update and at reset.
  The RS/6000 model's 4 KB NVRAM and save port are gone. Fixed during the port: the BCD conversion
  dropped the top bit of the tens digit, so years 80-99 read wrong. **The RS/6000 original has the
  same bug.**
- **8242** (`isa_kbc.v`): the RS/6000 8042 model (self test, interface tests, command byte, ports,
  D1-D4, set 2, set 1 by translation, **set 3**, mouse). The push staging is simplified: up to four
  bytes per cycle go straight into 16-byte flop queues. `kbrst` is a 6 µs pulse for F0h-FFh
  commands with bit 0 low, or a level while output-port bit 0 is 0.
- **PC87332** (`isa_superio.v`): registers 0-7 FER, FAR, PTR, FCR, PCR, KRR, PMC, TUP are stored,
  8 SID reads 10h, and the index reads back. FER/FAR place the UARTs (COM1-4), the parallel port and
  the FDC. Out of reset: FER 0Fh, FAR 10h (COM1, COM2, LPT 378h, FDC 3F0h, IDE off; **the AS200's
  jumper strapping is assumed**). The parallel port has its data latch, status DFh and control.
- **FDC**: an 82077AA with drive A: on the OSD's floppy image (hps_io slot 3), IRQ 6 and DMA
  channel 2 (its DREQ ORed into the 8237's channel 2, its byte on `dev_data` while it requests).
  See docs/design/floppy.md.

## 3. What DEC's DROM V1.7 POST does to the SIO

Method: `alpha-linux-gnu-objdump -D -b binary -m alpha:ev4 --adjust-vma=0x3ffc0` of
`AVANTI_E47_DROM1.7.bin` (addresses below are PAs, code at 0x40000), strings decoded from the
`lda`/`ldah a3` pairs, and the whole POST run on an EV4 interpreter against the Verilated SIO
(`tb_sio_drom`, with an I/O log through `--log`). ISA ports are reached by sparse I/O at
1.C000.0000 + port << 5 (`hw_ldl/p`, `hw_stl/p`, length field 0 = byte, data in lane `port & 3`).
The SIO's configuration space is at 1.E007.0000 + reg << 5.

**POST order and LED codes.** V1.7 writes **20h-2Fh**, not the D0h-DFh of TI Table 8-3, which
describes an earlier DROM. The order is the same.

| V1.7 LED | TI | Step (V1.7 routine) |
|---|---|---|
| 20 | DF | DROM entered, "POST Started" (0x4034c). Reached after the speed calibration when PA 0x70 is 2 or 8 |
| 21 | DE | 21071-DA errors cleared (0x422e0: DCSR \|= FF6Dh) |
| 22, 23 | DD, DC | memory test and flash ID test: **not run** in V1.7's POST (their routines, 0x42348 and 0x42458, belong to the mini-console) |
| 24 | DB | NVRAM test (0x42508, flashbus) |
| 25 | DA | 53C810 test (0x42690) |
| **26** | D9 | **82378 test** (0x42870) |
| **27** | D8 | **TOY (3287) test** (0x42a40) |
| **28** | D7 | **8242 test** (0x42c58) |
| **29** | D6 | **87332 test** (0x42e08) |
| **2A** | D5 | **Interrupts test** (0x42fe0) |
| 2B / 2D / 2F | D4 / D2 / - | jumpers (flashbus 1C.0000): bit 0 = 0 means mini-console (2F), bit 1 = 0 means floppy loader (2B), otherwise flash loader (2D, 0x43d90) |
| 2E | D1 | jumping to the flash console |

A failed test prints Addr/Act/Exp, sounds a beep code (0x44158, `t11` = the three groups low to
high) and enters the mini-console (0x40570). V1.7's codes: 82378, 87332, 53C810 and NVRAM failures
give **3-3-1**, the TOY test **1-2-1**, the Interrupts test **1-2-1**, and the 8242 test **3-2-4**,
as in TI Table 8-4. The beep itself is 8254 counter 2: port 61h = 03h, 43h = B6h, 42h = 80h, 02h
(0x44204).

### The SIO tests, access by access

1. **82378 test** (0x428b0-0x429c0)
   - Read config register 0 (byte length, lane 0) and compare its low 16 bits with **8086h**.
   - Read register 44h (lane 1, so **register 45h**: MEMCS bottom of hole) and save it.
   - Write AAh to 45h, read it back, and compare byte 1. Then the same with 55h.
   - Write the saved value back (in both the pass and the fail path).
   - What it needs: the full doubleword on a byte-length config read, and 45h fully writable.
2. **TOY test** (0x42a80-0x42b28)
   - Port 70h = 50h, read 71h (save).
   - 70h = 50h, 71h = AAh; 70h = 50h, read 71h, expect AAh.
   - The same with 55h.
   - 70h = 50h, 71h = saved.
   - The index is rewritten before every data access, and its bit 7 = 0 leaves NMI enabled. What it
     needs: CMOS byte 50h read/write.
3. **8242 test** (0x42c98-0x42ce8)
   - Poll 64h until bit 1 (IBF) is clear.
   - Delay of 16M loop iterations.
   - 64h = AAh, delay of 16M.
   - Poll 64h until IBF is clear, read 60h, expect **55h**.
   - What it needs: the self-test answer. OBF is not checked, and neither is the interface test.
4. **87332 test** (0x42e48-0x42eb8): **COM1's scratch register** 3FFh: write 00h, FFh, AAh, 55h, each
   read back and compared. The test never touches the 87332's configuration ports.
5. **Interrupts test** (0x43030-0x43158), all through the TOY and HIRR:
   1. Read B, clear SET (`& 7Fh`), set PIE (`| 40h`), write B. A = 26h (32 kHz time base, 1024 Hz).
   2. Poll C until bit 6 (PF) is set, at most 2M reads, else "RTC Did Not Perform Periodic Event".
   3. Delay 2M, read HIRR. **Bit 6 = irq_h[4] = CPU IRQ4 must be 1**, else "EV4 IRQ4 Line Was Not Set".
   4. A = 06h (divider off), poll C until PF reads clear, clear PIE and UIE (`B & 3Fh`).
   5. Delay 32M, read HIRR. **IRQ4 must be 0**, else "EV4 IRQ4 Line Was Not Cleared".
   6. A = 26h again.
   - What it needs: the periodic flag, IRQF = PF & PIE driving `toy_irq` straight to the CPU, the
     flags cleared by reading C, and DV = 000 stopping the divider.
6. **Calibration** (only when PA 0x70 = 2 or 8, before POST, 0x400bc-0x40314)
   - 43h = **26h**: counter 0, **MSB only**, mode 3. 40h = FFh: count FF00h.
   - It waits for the MSB read at 40h to become non-zero, then zero. It resets CC (`CC_CTL`) and
     counts 10 such edges (10 half periods = 10 x 7F80h ticks = 273.6 ms).
   - It picks the speed from RPCC, then writes PA 0x10, 0x68 and 0x70 and BIU_CTL.
   - With the model it finds **10000 ps / 100 MHz / code 9**, the same values our SROM hands over.
7. **After POST** (flash loader, 0x43e3c):
   - Read **CMOS byte 3Fh**: 1 means boot the **ARC** console (flash offset 80000h), anything else
     means **SRM** (offset 0).
   - So the TOY's CMOS also selects the console (SRM's `os_type`). The OSD's Console (NVRAM file,
     SRM, ARC) decides what 3Fh reads: the kept byte, 0 or 1 (`console_mode`).

The 8259s, PIRQ routing and IACK are not touched by the DROM: they are SRM's and the OSes'.

### Results

- `make -C verilator tb_sio_drom` (DROM V1.7, flash v7.0-9/4.58, jumpers 03h): every step from LED
  24 to 2A, then 2D and 2E, passes with no beep. That is 146.8M cycles.
- `DROMARGS=--calibrate`: the calibration finds 100 MHz, and the POST passes (174.2M cycles).
- `make -C verilator tb_sio` replays the sequences of tests 1-6 and the beep, and then tests each
  device further: **119 checks pass**.

DROM V1.2 (`scratch/disasm/drom_v1.2.dis.txt`) has the same test menu (T5 "82378 Test", T6 "3287
Test", T7 "8242 Test", T8 "87332 Test", T9 "Interrupts Test"). It has not been run, because the
core uses V1.7.

## 4. What SRM uses (from SRM V7.0's code and DEC's SRM V5.8 reference sources)

- **SIO identity**: SRM reads the ID (04848086h) and then the revision, and compares it with **88h**
  (`cmpult v0,0x88`, SRM V7.0 at 0x57ad0). Revisions below 88h take one path. 43h is assumed here
  (AS200/400 boards report 43h).
- **8242** (`kbd_driver.c`):
  - Self test AAh (55h), interface test ABh (00h), enable AEh, keyboard reset FFh until it is
    acknowledged.
  - Command byte through 20h/60h: SYS, disable keyboard, disable mouse and translation cleared,
    keyboard and mouse interrupts set.
  - **Scan set 3** (F0h 03h, then FCh 39h and FCh 58h make/break for the right Alt and Ctrl), then
    enable F4h.
  - It also reads and writes a TOY CMOS byte for "PS/2 mode".
  - The model answers all of this. `tb_sio` checks the self test, the interface test, the keyboard
    reset, the set 3 selection and query, and keys in set 3.
- **TOY**: the OS clock interrupt is the periodic interrupt on CPU IRQ4. CMOS 3Fh is the console
  selection. CMOS 17h is SRM's `console` variable: 01 graphics, 00 serial (found 2026-11-11 by
  watching the CMOS in the system simulator while SRM ran `set console graphics` and `set console
  serial`; no other byte changes, so no checksum covers it). The flash NVRAM's environment has no
  `console` entry.
- **8259 + IACK**: SRM's PALcode and the OSes read the vector through the 21071's
  interrupt-acknowledge space (1.B000.0000, PC64 guide 4.1.5), so `pt_cmd == 3`. PIRQ routing
  (60h-63h) is programmed by the console and the OSes (Linux `sys_sio.c`).
- SRM V7.0 does not seem to touch the PC87332's index/data ports: no `lda` of 398h or 399h appears.

## 5. Gaps and open items

1. **apecs does not issue IACK yet**: `rtl/apecs/apecs.v` declares `pt_cmd == 3` but does not decode
   1.B000.0000. Until it does, no interrupt vector can be read. `as200_sys.v` still uses the COM1
   stand-in: it needs `sio82378` in its place, with `pt_sub = pt_req && pt_cmd == 1 &&
   !other_claim`, `pirq_n = {~scsi_irq, 1, 1, 1}` (PIRQ3 = 53C810), `intr/nmi/toy_irq/kbrst` on
   `irq_h[2..5]`, and the SIO's `dm_*` port on the DMA arbiter. These files belong to another
   session.
2. ~~CMOS is not persistent~~ (2026-11-10): the CMOS (00h-7Fh) is kept in block 16 of the NVRAM
   image (an 8,704-byte file; `rtl/mister/nvsave.v` through `isa_rtc`'s `cm_*` port, saved 2 s
   after a guest write). OSD Console = NVRAM file (the default) reads 3Fh as kept; SRM and ARC
   override the read only (and the ARC year mapping), the guest's writes still go to the file.
   OSD SRM console (2026-11-11) does the same for 17h: Graphics (the default) and Serial override
   what 17h reads at reset, NVRAM file reads it as `set console` left it in the image. SRM writes
   17h back at every start (board, `_20261111a`), so the image follows an override after one boot.
3. **TOY epoch**: the MiSTer's two-digit year goes in as is. Which year base SRM, ARC/NT and the
   OSes assume (1900/2000 vs ARC's 1980) has not been checked. `year_ovr` gives the OSD full
   control.
4. The parallel port has no EPP/ECP and no interrupt. (The FDC is real since 2026-11-01:
   docs/design/floppy.md.)
5. **Not modelled**: the BIOS timer (80h), SMI/APM (A0h-AFh), the configuration RAM at 0C00h/0800h
   (UBCSB[7]), ISA memory cycles (`pt_cmd == 2` is never claimed, so an ISA VGA's A0000h would need
   it), 16-bit ISA I/O cycles (split into bytes), port 92h effects, IRQ13 from FERR#, the PC87332's
   two-writes rule and PTR's power down. The UBCSB serial/parallel enables are stored only.
6. **Assumptions to confirm on hardware or in the data sheets**: revision 43h, the 87332's
   strapped defaults (FER 0Fh, FAR 10h), the 8254 mode 3 sequence through 0, and the hps_io weekday
   convention.
