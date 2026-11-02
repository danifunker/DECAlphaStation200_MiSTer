# The floppy controller and drive A:

The PC87332's floppy disk controller is an Intel 82077AA. It runs in PC-AT mode at 3F0h-3F7h
(3F6h belongs to the IDE), on IRQ 6 and ISA DMA channel 2. It has one 3.5" drive, A: (SRM's
`dva0`). The drive's medium is the OSD's "Floppy (A:)" image on hps_io block device slot 3. The
controller replaces the stub that used to be in `isa_superio.v`. It is plain Verilog-2001.

| File | Contents |
|---|---|
| `rtl/sio/isa_fdc.v` | The 82077AA: registers, the command, execution and result phases, the seek engine, DMA and non-DMA transfers, and the drive's timing |
| `rtl/sio/isa_fdc_img.v` | The medium: its geometry from the image size, write protect, the disk change, and a 12 KB track cache on hps_io slot 3 with write-back |
| `rtl/sio/isa_superio.v` | Instantiates `isa_fdc` behind the PC87332's FER/FAR decode (FER[3] on, FER[5] moves it to 370h) |
| `rtl/sio/sio82378.v` | ORs the FDC's DREQ into channel 2 of the 8237 and routes DACK/TC to it. Carries the `fd_*` ports up |
| `rtl/sio/isa_pic.v` | Edge-triggered requests drop with their line (section 5) |
| `verilator/tb/tb_fdc.cpp` | Bench: `make -C verilator tb_fdc` |
| `verilator/tb/tb_sio_drom.cpp` | `make -C verilator tb_sio_drom_floppy`: DEC's DROM V1.7 runs its J2 floppy loader |

## 1. Integration (as200_sys.v, the MiSTer top, files.qip)

New ports of `sio82378` (pass them through `as200_sys`):

| Port | Dir | Connect to (DECAlphaStation200.sv) |
|---|---|---|
| `fd_mounted` | in | `img_mounted[3]` |
| `fd_readonly` | in | hps_io `img_readonly`. It is currently left open (`.img_readonly()`); give it a wire |
| `fd_size[63:0]` | in | `img_size` (shared; it is sampled on `fd_mounted`) |
| `fd_lba[31:0]` | out | `sd_lba[3]` |
| `fd_blk_cnt[5:0]` | out | `sd_blk_cnt[3]` (up to 20: one track of a 1.68 MB DMF disk, or half a 2.88 MB track) |
| `fd_rd`, `fd_wr` | out | `sd_rd[3]`, `sd_wr[3]` |
| `fd_ack` | in | `sd_ack[3]` |
| `fd_buff_addr[13:0]`, `fd_buff_dout[7:0]`, `fd_buff_wr` | in | the shared `sd_buff_addr`, `sd_buff_dout`, `sd_buff_wr` (`as200_sys` already has them for SCSI). The cache writes only while `fd_ack` is high |
| `fd_buff_din[7:0]` | out | `sd_buff_din[3]` |
| `fd_led` | out | high while a floppy command runs. Optional, for example `LED_DISK = {1'b0, fd_led}` |

Parameter `FD_SPEED` (default 4): how many times faster than a real drive this one runs.

In the top: `sd_rd = {nv_rd, fd_rd, scsi_rd}`, `sd_wr = {nv_wr, fd_wr, scsi_wr}`,
`sd_lba[3] = fd_lba`, `sd_blk_cnt[3] = fd_blk_cnt`, `sd_buff_din[3] = fd_buff_din`.

Add `rtl/sio/isa_fdc.v` and `rtl/sio/isa_fdc_img.v` to `files.qip`.

The image module ignores the machine's reset: a mount is seen only once, and a write-back in flight
must finish. Everything runs on the one 100 MHz clock (hps_io's too).

**For the DROM's J2 floppy boot on the board**, the 21071's DMA window 1 must be open: a direct
window at PCI 1 GB onto PA 0. The DROM's ISA DMA high page is 40h, and SRM's
`io_get_window_base` is the same 1 GB. The DROM sets no window itself, and our SROM sets PBR1 = 0,
so the window is off (srom.md F6). Without it, the loader's DMA gets a master abort, the boot
block checksum fails, the beep is 3-2-3, and the DROM falls back to the flash loader. The fix is
in the SROM: TBR1 = 0, PMR1 = 3FF00000h, and PBR1 = 40080000h (bit 19 is WENB). SRM programs its
own windows, so SRM is not affected.

## 2. The medium (`isa_fdc_img.v`)

**Geometry.** It is taken from the image size at each mount: the largest row whose size the
image reaches. The cylinders are the image's whole cylinders, at most 84. There are always two
heads and 512-byte sectors.

| Blocks | Medium | Sectors a track | Rate (CCR/DSR code) |
|---|---|---|---|
| 1440 | 720 KB | 9 | 250 kbps (2) |
| 2400 | 1.2 MB | 15 | 500 kbps (0) |
| 2880 | 1.44 MB | 18 | 500 kbps (0) |
| 3360 | 1.68 MB DMF | 21 | 500 kbps (0) |
| 5760 | 2.88 MB | 36 | 1 Mbps (3) |

- An empty slot (size 0) means no medium.
- A smaller image is a medium with no cylinders: nothing can be found on it.
- The mount's read-only flag is the write-protect tab. With no medium, write protect reads as set,
  as a real drive reports it.

**Track cache.** The cache is 12 KB of true dual-port block RAM.
- The controller asks for a group of sectors: a whole track, or half of a 36-sector track
  (`want_lba`, `want_cnt`). The group is read in one hps_io request, so a track costs one Main
  turnaround and not 18.
- `trk_rdy` stays high while the cache holds that group.
- The controller marks each sector it writes as dirty. The span of dirty slots goes back to the
  image in one background request, while the next sector is being written. Any write-back finishes
  before another group is loaded.
- A mount drops the cache and anything dirty. A request not yet taken is withdrawn, and one in
  flight is finished and then thrown away.

## 3. The controller (`isa_fdc.v`)

### Registers

| Port | Read | Write |
|---|---|---|
| 3F0 | SRA (PS/2 mode): INT, /DRV2 = 1, STEP, /TRK0, HDSEL, /INDEX, /WP, DIR | |
| 3F1 | SRB: drive select 0, write enable, motors 1 and 0 | |
| 3F2 | DOR | DOR: drive select, /RESET (held low: the chip is in reset, MSR = 00), DMA gate (gates IRQ and DRQ), motors |
| 3F3 | TDR (bits 7:2 read 1) | TDR |
| 3F4 | MSR: RQM, DIO, NDM, CB, D3B-D0B | DSR: rate [1:0], precompensation and power down (stored), software reset [7] |
| 3F5 | FIFO: results, non-DMA data | FIFO: command bytes, non-DMA data |
| 3F7 | DIR: DSKCHG [7] (drive 0 selected); bits 6:0 read 1 (a floating bus) | CCR: rate [1:0] |

Every register reads from a flop. MSR and FIFO show the state one clock late.

### Commands

Commands are decoded on bits 4:0. LOCK uses bit 7, and SEEK bit 7 means RELATIVE SEEK, with bit 6
as the direction. Every other code (00, 01, 0B, 15, 17, 18 PART ID, 1A-1C, 1E, 1F) is invalid and
gets one result byte, 80h.

| Code | Command | Notes |
|---|---|---|
| 03 | SPECIFY | SRT sets the step time (16 - SRT ms at 500 kbps, twice that at 250/300 kbps, half at 1 Mbps). HUT and HLT are stored. ND selects non-DMA |
| 04 | SENSE DRIVE STATUS | ST3: WP, RDY = 1, T0, TS = 1, head, drive. Drives 1-3: T0 from their PCN, no WP |
| 07 | RECALIBRATE | Up to 79 steps toward track 0. Drives 1-3 never reach it: ST0 71h (EC) |
| 08 | SENSE INTERRUPT STATUS | After a reset: C0h-C3h with PCN, unless another interrupt came first (then they are dropped, like QEMU; the DROM needs this). Then the seek ends, lowest drive first. Otherwise 80h (one byte) |
| 0F, 8F/CF | SEEK, RELATIVE SEEK | Overlapped: the controller takes other commands while the drive seeks (D0B). A data command waits for it to end |
| 0A | READ ID | The next ID under the head |
| 06, 0C, 02 | READ DATA, READ DELETED DATA, READ TRACK | MT, SK. READ DELETED finds only regular data marks: CM is set, and with SK = 0 it ends after that sector |
| 05, 09 | WRITE DATA, WRITE DELETED DATA | Written as normal data |
| 16 | VERIFY | No transfer. Ends at EOT, or after SC sectors with EC (byte 1 bit 7) |
| 11, 19, 1D | SCAN EQUAL / LOW OR EQUAL / HIGH OR EQUAL | Host bytes against disk bytes, FFh = don't care. STP (DTL) steps R. SH or SN in ST2 |
| 0D | FORMAT TRACK | From the index pulse: one 4-byte ID from the host for each sector. The sector is filled with D when the image can hold it: right rate, N = 2, R within the track. Otherwise the ID is accepted and dropped |
| 0E | DUMPREG | PCN0-3, SPECIFY, EOT/SC, LOCK and PERPENDICULAR, CONFIGURE, PRETRK |
| 10 | VERSION | 90h (82077AA) |
| 12 | PERPENDICULAR MODE | Stored (OW gates D3-D0) |
| 13 | CONFIGURE | EIS (implied seek), EFIFO, POLL, FIFOTHR, PRETRK. Stored. Only EIS and POLL matter |
| 14, 94 | LOCK | CONFIGURE and PRETRK survive resets while it is set |

**Data commands.**
- A sector is found when the drive is drive 0, a medium is in, the rate matches it, MFM is used,
  the head's cylinder is on the medium, and the ID matches: C = the head's cylinder, H = HDS,
  N = 2, and 1 <= R <= sectors per track.
- **No ID marks** (no medium, wrong rate, FM, no drive, past the last cylinder): after two index
  pulses, ST0 40h and ST1 01h (MA).
- **An ID that does not match:** ST1 04h (ND), and ST2 10h (WC) for a wrong cylinder (02h BC when
  C = FFh).
- **Write protected:** a write or format stops at once with ST1 02h (NW).
- **End of a transfer:**
  - TC (DMA) ends it after the current sector. A read stops transferring, and a write pads the
    sector with zeros.
  - Reaching EOT without TC ends with IC = 01 and ST1 80h (EN), as on the 82077. This is also how
    non-DMA transfers end.
- **The result's C H R N:**
  - At EOT with MT = 0: C+1, R = 1.
  - At EOT on head 0 with MT: H complemented, R = 1.
  - At EOT on head 1 with MT: C+1, H complemented, R = 1.
  - Elsewhere: R+1.
- ST0 has SE when an implied seek was made.

**Interrupts.**
- **Sources:** leaving reset (DOR /RESET 0 to 1, or DSR bit 7, while polling is enabled),
  the end of a seek or recalibrate, and the result phase of a data command, READ ID or FORMAT.
- **Clearing:** any command byte written to the FIFO takes the interrupt line down. The statuses
  stay for SENSE INTERRUPT. The first result byte read also takes it.
  - SRM needs this. `dv_driver.c` resets the controller and never sends SENSE INTERRUPT, so its
    RECALIBRATE interrupt must be a new edge on the edge-triggered IRQ 6.
- **Non-DMA:** INT also follows RQM during the execution phase.
- **IRQ 6** is the INT line gated by DOR bit 3.

**DMA.**
- DREQ is a flop, gated by DOR bit 3 with ND = 0, and it drops on the clock after DACK.
- A read's byte waits in `dma_q` while DREQ is high. The 8237 samples it in T_RD, through the SIO's
  `dev_data` mux, which selects the FDC while the FDC is requesting.
- A write takes `dack_data`. TC comes with DACK.
- Mode registers decide the direction; the controller does not check them.

**Non-DMA.** MSR is {RQM, DIO, NDM = 1, CB = 1}. Each byte moves through 3F5.

### Timing

The drive runs at `FD_SPEED` times real speed (default 4; the benches use 100). A prescaler gives
microseconds of drive time.

- **Rotation.** The disk turns at 300 rpm: 200 ms a revolution, cut into one slot per sector.
  Sector R's ID passes at the start of slot R-1, and the index pulse comes before sector 1. READ ID
  answers at the next slot boundary.
- **Data rate.** A byte comes every 16 µs at 500 kbps (8, 27 or 32 µs at the other rates), counted
  from the previous byte, not from when the host took it. A track of 18 sectors reads in one
  revolution after the first ID.
- **A slow host** holds the transfer: there is no overrun. If it holds a sector past the next ID,
  that sector waits one revolution.
- **Steps.** Each step pulse is followed by the step time, and the seek ends after the last one.
  A recalibrate on track 0, or a seek to the current cylinder, ends at once.
- **Errors** end after two index pulses (400 ms real; 100 ms at `FD_SPEED` 4).

At `FD_SPEED` 4 a 1.44 MB sector takes about 2 ms of data plus up to 50 ms of rotation, and a
track about 60-110 ms. Our core's ISA accesses are much faster than a real AS200's (about 1 µs
each), so firmware loops that time out after a fixed number of polls run out sooner. The DROM's
IRR wait (1M polls, about 0.2 s here) still covers a whole revolution at `FD_SPEED` 4.

### Disk change

DSKCHG starts set at power-on. A mount sets it, including a remount of the same file. A step pulse
clears it while a medium is in, which matches what Linux, NT and NetBSD do (a seek away and back).
The machine's reset does not touch it.

## 4. What the firmware does with it

### SRM (DEC's `dv_driver.c`, SRM V5.8 reference sources; V7.0's strings are nearly the same)

The driver sees one unit, `DVA0`. `show device` takes it from the configuration table, without
probing. `ide_open` probes the densities in the order of `floppy_devtab`:

| Density | DSR | CCR | SPECIFY | EOT |
|---|---|---|---|---|
| ED | 07h | 3 | 9Eh 3Ah | 36 |
| HD | 0Ch | 0 | CFh 02h | 18 |
| DD | 0Eh | 2 | E4h 02h | 9 |

For each density it does the following, until block 0 reads:
1. `enable_controller`: DOR 08h then 0Ch, then waits for the interrupt (5 s timer). No SENSE
   INTERRUPT.
2. DSR, CCR, SPECIFY, PERPENDICULAR 84h.
3. DOR 1Ch, then a 1 s sleep.
4. RECALIBRATE: waits for the interrupt, then SENSE INTERRUPT. It is retried once if ST0 is not
   good.
5. The read of block 0, with up to MAX_RETRIES attempts: CONFIGURE 00h 0Bh 00h, the DMA set-up,
   then READ DATA `66h` (MFM, SK, no MT) with the EOT of the density.

A 1.44 MB image fails at ED (wrong rate: MA after two index pulses, for each retry) and opens as HD.

**DMA set-up** (`jensen_dma_control`):
- Command registers 0; DMA2 mode C0h (the cascade).
- Channel 2 mode 06h for a read, 0Ah for a write (the extended mode, 40Bh, is 02h).
- Address and page, then high page 481h = buffer >> 24 | 40h (the 1 GB window).
- Count = bytes - 1. Its write of a high count byte (an EISA ISP register) is not decoded by
  the 82378 and goes nowhere.
- Unmask.

**Reads and writes.** These go through an 8 KB bounce buffer, cut at track ends: one READ or WRITE
DATA for each track piece, with TC at its end. SEEK is sent when the cylinder changes, then the
interrupt and SENSE INTERRUPT. `ide_check_status` fails on any ST1 or ST2 bit, except NW before the
last retry of a write. WRITE DATA is `65h`: the SK bit is set on a write. The controller decodes
on bits 4:0, so it is accepted.

**Interrupt or polled.**
- In interrupt mode the ISR posts a semaphore and sends an EOI.
- In polled mode the driver reads the 8259's IRR (OCW3 0Ah at 20h) and tests bit 6.
- The semaphore is zeroed before each command, so the controller's level INT works for both.

### DROM V1.7's floppy loader (J2 jumper; 0x43510, LED 2B)

DROM V1.7 (`AVANTI_E47_DROM1.7.bin`) runs this loader. The steps:
1. **Print and configure.** It prints its banner on the SROM port. It reads port 26Eh: if that
   reads 88h the PC87332's index is at 26Eh, otherwise at 398h.
2. It sets the PC87332: FER = (FER & 0Fh) | 10h (the FDC kept on, at 3F0h), FAR = 11h, PTR = 80h.
   Each value is written twice.
3. **Its variables.** It uses a workspace at PA 2000h: 2 heads, 18 sectors, SPECIFY CFh 02h, and
   the current cylinder unknown (-1).
4. **The 8259s.** They get ICW 11h, 08h, 02h, 03h (AEOI) for the slave, 11h, 00h, 04h, 01h for
   the master, then OCW1 FBh: IRQ 6 stays masked. A loop of EOIs follows.
5. **Reset.** While MSR's RQM is 0: DSR = 80h, 1 ms, DOR = 0Ch. Then CCR = 0.
6. **One SENSE INTERRUPT** (C0h).
7. **SPECIFY**, then DOR 1Ch (motor A), then a 2 s wait.
8. **For each block:**
   - If the cylinder is unknown: RECALIBRATE, then SENSE INTERRUPT. ST0 must have IC = 00, with
     two tries.
   - If the cylinder changed: SEEK (head << 2, cylinder), wait, SENSE INTERRUPT.
   - DMA set-up: D0h = 0, 08h = 0, D6h = C0h, 0Bh = 46h, 40Bh = 2, then the address, page,
     high page 40h, count 1FFh, 405h = 0 (no device), D4h = 0, 0Ah = 2.
   - READ DATA `66h` hds C H R 2 18 1Bh FFh. It waits, then reads up to 7 result bytes and checks
     only ST0 & C0h. Two tries.
9. **Waiting** for each command means polling IRR bit 6: OCW3 0Ah, then a read of 20h (0x43b88).
   After a RECALIBRATE the wait has no time-out. After a SEEK or a READ it gives up after 1M
   polls. The line is masked, and nothing ever acknowledges it.
10. **Results.** These are read while MSR shows RQM with DIO, until RQM without DIO (0x43b10). The
   limit is 2M polls.
11. **Block 0 is the Alpha boot block**, loaded at FFE00h. The sum of its first 63 quadwords must
   equal the quadword at 1F8h. Then the count at 1E0h of blocks from LBN 1E8h go to 100000h.
12. **The jump.** It writes LED 2C, then `hw_rei` to 100001h (PALmode). On a failure: DOR 0Ch,
   beep 3-2-3, LED 1D, then the flash loader (2D).

What it needs from the hardware:
- **IRR bit 6 must follow the FDC's line.** It must rise with each command's interrupt and fall
  when SENSE INTERRUPT or the result read clears it.
- With the 8259 model's old edge latch (set until acknowledged), every wait after the first would
  return at once. Each SENSE INTERRUPT would then run while the seek is still going, and get 80h.
- So `isa_pic.v` now clears an edge-mode IRR bit when its line falls before the acknowledge, as
  the 8259A does: "the IR input must remain high until after the falling edge of the first INTA".
  The master's IRQ2 (the cascade) keeps the latch, because the model's pipeline holds the slave's
  INT low for two clocks after each access to the slave.
- The single SENSE INTERRUPT after the reset also needs the rule above: RECALIBRATE's interrupt
  drops the three reset statuses still owed.

## 5. Benches and results

**`make -C verilator tb_fdc`** (172 checks, about 10.5M cycles, `FD_SPEED` 100):
- **Bus and setup.** The bench drives the SIO through its PCI target bus. IRQ 6 goes through the
  8259s and the IACK. DMA channel 2 goes through the 8237 and the PCI master port to a memory
  model. Slot 3 is a model of hps_io with a 3000-clock Main turnaround. The images are patterned
  and made in the bench.
- **Registers and configuration:** reset and its four statuses, MSR in each phase, VERSION,
  invalid commands, SPECIFY, CONFIGURE, PERPENDICULAR, DUMPREG, LOCK and UNLOCK across resets,
  SENSE DRIVE STATUS (no medium, medium in, drive 1, off track 0, write protect).
- **Seeks:** RECALIBRATE, SEEK (the D0B busy time and the step timing), RELATIVE SEEK in and out,
  READ ID on both heads.
- **DMA reads:** a whole track with MT (one revolution plus the first ID), a single sector (not
  instant), MT across heads, TC in the middle of a sector (the rest not transferred), and EOT
  without TC (EN).
- **Errors:** sector 19 of 18 (ND, after two index pulses), wrong cylinder (WC), an ID head
  mismatch, 1 Mbps and 250 kbps on a 1.44 MB disk (MA), FM (MA), drive 1 (MA), and RECALIBRATE
  of drive 1 (EC).
- **Writes and the other data commands:** an implied seek (SE, PCN), DMA WRITE of 3 sectors
  checked in the image through the write-back and read back, a short write padded with zeros,
  WRITE DELETED, READ DELETED (CM), VERIFY to EOT and by count, SCAN EQUAL (SH), and a
  write-protected remount (NW, disk change).
- **Non-DMA:** a read and a write, with RQM, DIO and NDM, and INT for each byte.
- **FORMAT TRACK:** IDs by DMA, the track filled in the image and its neighbours untouched, and
  one revolution.
- **Other media:** 720 KB at 250 kbps (and its 500 kbps failure), the disk change cleared by a
  seek, and 2.88 MB at 1 Mbps across the cache's half-track boundary.
- **SRM's `ide_open`** replayed exactly: ED fails, HD opens, block 0 is read. Then a 40-block read
  cut as `ide_common_io` cuts it, with SEEKs.
- **The DROM loader's sequence:** DSR reset, one SENSE INTERRUPT, IRR 6 rising and falling,
  RECALIBRATE, SEEK, READ.

**`make -C verilator tb_sio_drom_floppy`**: DEC's DROM V1.7 runs on the EV4 interpreter against
the Verilated SIO with J2 set (jumpers 01h) and a bench-made 1.44 MB image. The image has a boot
block for 20 blocks from LBN 30, which crosses from cylinder 0 to 1. The run passes the POST (LED
24-2A), the floppy loader (2B), the load (2C) and the jump to 100000h with the 20 blocks in
memory: 361.8M cycles at `FD_SPEED` 4. It prints the 21071 windows the DROM left (all 0: see
section 1).

**`make -C verilator tb_sio`**: 119 checks. Its FDC section now runs against the real controller
with no medium, so a READ ends after two index pulses. **`tb_sio_drom`** (the POST to the flash
loader) and **`tb_audio`** still pass.

## 6. Gaps

- **Untested in this bench:** SRM itself (`boot dva0`, `show device`) and the OSes' drivers (NT,
  NetBSD, Linux). Only their sequences from the sources are replayed. The system simulation needs
  the integration of section 1 first.
- **The DROM floppy boot** needs the SROM's DMA window (section 1).
- **No overrun or underrun.** A slow host stalls the transfer. There are no CRC errors.
- **Not modelled:**
  - Deleted data marks: WRITE DELETED writes normal data.
  - The DTL byte count for N = 0.
  - Non-standard formats: other N, other sector counts, a format at another rate.
  - FIFO threshold behaviour: the FIFO is one byte deep, with stalls.
  - The 82077's power-down.
  - Head load and unload times.
  - Drives 1-3, beyond "no drive".
  - 2 Mbps.
  - PS/2-mode DIR bits.
  - The motor: the disk always turns.
- **Assumptions:**
  - DOR's drive select is not checked against the command's.
  - The remaining reset statuses are dropped by any interrupt (QEMU's rule).
  - DSKCHG reads only with DOR selecting drive 0.
  - SRA/SRB give PS/2-mode values, although AT mode has none.
