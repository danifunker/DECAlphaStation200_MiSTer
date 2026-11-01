# SCSI: the NCR 53C810 and its targets

| File | What |
|---|---|
| `rtl/scsi/ncr53c810.v` | The 53C810: a PCI device (number 6, IDSEL AD17) on the internal PCI target bus and DMA port of `pci.md`. INTA goes to PIRQ3 |
| `rtl/scsi/scsi_targets.v` | Hard disks at ID 0 (`dka0`) and ID 1 (`dka100`), and a CD-ROM at ID 4 (`dka400`), on hps_io block-device slots 0, 1 and 2 |
| `rtl/scsi/cd_audio.v` | The CD's audio player, inside `scsi_targets` (from the HP 9000/715 core's `cd_audio.sv`; `cdrom.md`) |
| `verilator/tb/tb_ncr810.cpp`, `tb_ncr810_top.v` | The unit bench: `make -C verilator tb_ncr810` |

Both RTL files are ported to Verilog-2001 from the user's IBM RS/6000 7248 core. The sources are
`rtl/machine/IBMRS6K7248_ncr810.sv` and `IBMRS6K7248_scsitgt.sv` on `origin/master`, and that
core's `docs/scsi_design.md` describes the SCRIPTS engine. Those were themselves derived from the
HP 9000/715 core's `ncr53c710.sv` and `scsi_targets.sv`.

## 1. Interface

### Controller (`ncr53c810 #(DEVNUM = 6, REV = 8'h02, STO_UNIT = 6250)`)

- `clk`, `reset`: the system clock (100 MHz target). `STO_UNIT` is the number of clocks in 1/16 ms.
- **PCI target bus**, exactly as in `pci.md` 2:
  - Inputs: `pt_req`, `pt_cmd`, `pt_dev`, `pt_addr`, `pt_be`, `pt_we`, `pt_wdata`.
  - `pt_claim` is combinational. It is set for:
    - a configuration access with `pt_dev == DEVNUM` and function 0;
    - an I/O access inside BAR0 while command bit 0 is set;
    - a memory access inside BAR1 while command bit 1 is set.
  - The accepted request (`pt_addr`, `pt_be`, `pt_we`, `pt_wdata`) is registered. The register
    access runs from that copy in the next cycle, and `pt_ack`, a one-cycle pulse, follows in the
    cycle after: two cycles after the request is accepted. The device accepts nothing while a
    request is pending or `pt_ack` is high.
  - `pt_rdata` is valid with `pt_ack` and **0 otherwise**, so several devices' read data can be
    ORed together.
  - A read always returns all 32 bits, whatever the byte enables. The DROM depends on this: it reads
    the vendor ID with a byte-length access.
- **DMA**, as in `pci.md` 3: `dm_req` (held until `dm_ack`), `dm_we`, `dm_addr` (longword-aligned
  PCI address), `dm_be`, `dm_wdata`, `dm_ack`, `dm_rdata`.
  - One longword per request.
  - SCRIPTS words are little-endian. Data bytes keep their addresses, with byte k in lane k.
  - `pci.md` has no error return, so a master abort reads all ones (apecs's behaviour) and
    DSTAT.BF is never raised by DMA.
- `inta_n` is active low and level-sensitive. It is registered, so it follows the status one
  clock late.
- **SCSI bus** to `scsi_targets`: `sb_sel/sb_sel_id/sb_sel_atn`, `sb_sel_done/sb_sel_fail`,
  `sb_bsy`, `sb_req`, `sb_phase`, `sb_tdata`, `sb_ack`, `sb_idata`, `sb_ackhold`, `sb_atn`, `sb_rst`.
  This is the RS6K core's byte-level bus. The protocol is described in the header of
  `scsi_targets.v`.

### PCI configuration header

| Reg | Value |
|---|---|
| 00 | `0x0001_1000` (53C810, NCR/Symbios) |
| 04 | Command: bits 0 (I/O), 1 (memory), 2 (master), 6 (parity) and 8 (SERR) are writable. Status reads `DEVSEL` medium; bits 15-11 are write-one-to-clear |
| 08 | `0x0100_00` class (SCSI), revision `REV` = 0x02 (also in CTEST3<7:4>). DEC's SRM matches only the ID (`pci_size_config.c`, `probe_io.c`: revision mask 0), and the DROM checks only the vendor ID |
| 0C | Cache line size and latency timer are writable; header type 0 |
| 10 | BAR0: I/O, 256 bytes (`0xFFFFFF01` after sizing) |
| 14 | BAR1: memory, 32-bit, 256 bytes (`0xFFFFFF00` after sizing). **Decoded** (the RS6K version only stored it) |
| 3C | Interrupt line is writable; pin 1 (INTA); MIN_GNT 0x11; MAX_LAT 0x40 |
| 80-FF | **The operating registers 00-7F** (see section 2) |

Inside either BAR, offsets 80-FF alias 00-7F.

### Targets (`scsi_targets #(DISK0_ID = 0, DISK1_ID = 1, CD_ID = 4, CD_ALWAYS = 1, CLK_HZ = 100000000)`)

- A single clock: hps_io runs on the system clock in this core.
- Ports are flat; slot s occupies `[32s+31:32s]` of `img_blocks` and `sd_lba`, and `[6s+5:6s]` of
  `sd_blk_cnt`.
- `sd_rd[2:0]`, `sd_wr[2:0]`, `sd_ack[2:0]`, `sd_buff_addr`, `sd_buff_dout`, `sd_buff_wr` connect to
  hps_io's 8-bit side. There is one `sd_buff_din` for all slots; the top fans it out.
- `img_present[2:0]` and `img_blocks` (the size in 512-byte blocks) are latched by the top from
  `img_mounted`/`img_size`.
- `cd_change` is pulsed when the CD slot is (re)mounted (`img_mounted[2]`). It clears the track
  table, stops a play, returns the block size to 2048 and makes the next command see UNIT ATTENTION.
- `cd_audio_l`, `cd_audio_r` (signed 16-bit) and `cd_audio_stb` (a one-clock pulse at 44.1 kHz, from
  `CLK_HZ`) are the CD audio, for the mixer (`cdrom.md` 2).
- `activity` is high while a target is connected.
- Requests are up to 4 blocks (2 KB, the sector buffer). A CD audio frame is 5 blocks into the
  player's own buffer.
- The CD slot:
  - Main (`support/decalpha`, `cdrom.md`) serves the disc as 2048-byte sectors by disc LBA.
  - The track table is at block `C000_0000` and audio frame f at `8000_0000` + 5f.
  - With `CD_ALWAYS` the drive answers selection with no image (NOT READY, MEDIUM NOT PRESENT).

### Timing structure (100 MHz)

**Targets (2026-11-01)**: the fit failed `Equal77 -> tdata` (-1.117 ns). The compares and adders on
`d_idx` were inside the synthesised byte, and that byte went straight into `tdata`. Now:
- every response is addressed by registered cursors: `d_idx`; MODE SENSE's section, page and offset;
  READ TOC's entry byte, kind and table address;
- the byte is registered (`syn_r`), and `tdata` takes `syn_r` or the buffer's registered output;
- a data-in byte goes out three clocks after the previous one was taken (cursor, RAM / `syn_r`, send).

**Controller:**

The restructuring for the 10 ns fit (2026-11-01) removed the failing paths from `ins0`,
SCRATCHA/ADDER and `pt_addr` into DSP, DSTAT/SIST, TEMP, DNAD and the other registers, without
changing behaviour beyond a few cycles of latency.

- **Host side**: the register select is decoded from the registered request, not from `pt_addr`.
  `pt_claim` stays a combinational BAR compare, as `pci.md` requires.
- **`E_PRE`**: one state between the fetch and `E_DECODE`. It registers:
  - DSA + DSPS<23:0>, for table-indirect moves and DSA-relative LOAD/STORE;
  - DSA + DBC, for a table-indirect SELECT;
  - the transfer or WAIT RESELECT target (DSP + DSPS<23:0> when relative, else DSPS);
  - the count == 0 test;
  - the memory move's own-register, I/O-fault and alignment comparisons.
- **Register instructions** take three states: `E_REG_RD` (operand: SFBR or the register),
  `E_REG_ALU` (result and carry registered), `E_REG_WR` (the write with its side effects).
- **Transfer control** takes two states: `E_TC_EVAL` (the condition, registered) and `E_TC_DO`
  (DSP, TEMP, INTF or the SIR halt).
- **Interrupt status**: the bits an engine cycle raises are registered once (`q_*`) before they
  are stacked into DSTAT, SIST0 and SIST1.
- **Timers**: the STO and GEN timer compares are registered.

## 2. What DEC's firmware does to the chip

### DROM V1.7 power-up: "53C810 Test"

The test is at PA 0x42690-0x42868 (image offset 0x26D0). The power-up sequence calls it at 0x403B8,
after POST code 0x24 and before the 82378 test (0x42870). The `DIAGROM>` monitor runs it with `T4`,
looping and printing "Pass # n", or with `MA` (all tests).

1. Prints "53C810 Test Started". The string is built with immediates, so `strings` does not find it.
2. Reads PA 1.E006.0000 with `hw_ldl/p`: configuration space, device 6, register 0, length "byte",
   so BE = 0001. It keeps the low 16 bits and compares them with **0x1000**. A mismatch goes to the
   ID failure path at 0x427F0.
3. For lane = 0..3: writes `0xAA << 8*lane` to PA 1.E006.1B80 + 0x20*lane, issues `mb`, reads the
   same address back and compares that byte with 0xAA.
   - PA<12:7> = 0x37 selects config dword **0xDC**, and PA<6:5> selects the lane.
   - These are configuration bytes **0xDC-0xDF** = operating registers 0x5C-0x5F = **SCRATCHB**,
     through the 53C8xx mirror of the operating registers at configuration 0x80-0xFF.
   - A mismatch goes to 0x42824.
4. Repeats step 3 with 0x55. SCRATCHB is left at 0x55555555.
5. Prints "53C810 Test Passed" and returns.

On failure the DROM prints the address, the actual value and the expected value, plays beep code
3-3-1 through the 8254 and port 61, and drops into the `DIAGROM>` monitor. The rest of power-up,
including the 82378 test, is then skipped.

Everything else is untouched:
- no BAR or command register setup;
- no 21071 window or HAXR setup;
- no access to the chip through I/O or memory space;
- no SCRIPTS, DMA or interrupts.

The DROM accesses device 6 nowhere else and has no generic PCI bus sizing.

**The model passes this test**, in the bench and, since its integration into `as200_sys.v`, in the
full system simulation (`make -C verilator system`). Configuration 0x80-0xFF goes to the register file. The bench runs
the exact access sequence (byte enables per lane, data in its lane) and then checks that SCRATCHB
reads 0x55555555 through BAR1. The bench also checks that a byte-length read of register 0 returns
the full ID.

### SRM

The reference is DEC's SRM V5.8 sources in `scratch/ebsdk/sw/apisrm/ref`. These are reference
material only, never copied; the console in flash is V7.0, which may differ.

- **Files**: `n810_driver.c`, `pke_driver.c`, `pke_script.mar`, `n810_script*.mar`, `n810_def.h`.
- **Register access**: `pci_get_base_address(dev, N810_CSR_BASE = 1)`, i.e. **BAR1, memory space**,
  with byte and longword reads and writes (`inmemb`/`outmemb`/`inmeml`/`outmeml`).
- **Interrupts**: on non-RAWHIDE platforms (the AS200 included) the driver forces
  `pb->pb.vector = 0`, so it runs **polled**: DIEN = SIEN0 = SIEN1 = 0, and it polls `ISTAT & 3`.
  DIP and SIP must therefore be set whatever the masks are (fatal interrupts), and the model does
  that.
- **Init** (`n810_init_n810`):
  1. ISTAT = SRST, then ISTAT = 0.
  2. SCNTL0 = EPC|AAP, SCNTL1 = EXC, SCNTL3 = 0x33 (40 MHz; 0x55 only for an 875 below rev 3),
     SCID = host ID (7), SXFER = 0.
  3. CTEST4 = MPEE, DMODE = BL1|BL0, DIEN, DCNTL = IRQM|COM, SIEN0, SIEN1, STEST3 = EAN,
     RESPID = 1 << ID, SCRATCHB = 0x96000069 | ID << 8 | fast << 16.
- **Bus reset**: SCNTL1 = RST, 25 µs, SCNTL1 = EXC, a 250 ms sleep, then reads of SIST0, SIST1 and
  DSTAT to clear them.
- **Per command**:
  1. Patches the SELECT instruction's ID field in the SCRIPTS copy in memory.
  2. Fills a DSA table of {count, address} pairs: message out at +4, command at +12, data out at
     +20, data in at +28, status at +36.
  3. Writes STIME0 = 0x0D (selection timeout), CTEST3 = CLF, DSA, then **DSP, which starts the
     program** (DMODE.MAN = 0).
  4. When built with `SSM`, sets DCNTL.SSM and steps with DCNTL.STD, continuing on every DSTAT.SSI.
  5. The interrupt handler reads SIST0, SIST1 and DSTAT one byte each and dispatches on the INT
     number in DSPS.
  6. On a phase mismatch it reads DCMD/DBC as a longword and DFIFO (in-FIFO = (DFIFO - DBC) & 0x7F,
     which is 0 here) and SSTAT0.OLF, then restarts at another label.
- **SCRIPTS used** (`pke_script.mar`):
  - SELECT ATN with a reselection alternate.
  - Transfer control: JUMP and INT with WHEN/IF phase and data/mask compares, sense true or false.
  - Block moves, direct and table indirect (DSA-relative), in all six phases.
  - CLEAR ACK, SET/CLEAR ATN.
  - Register read-modify-write AND/OR on SCNTL2 (SDU) and SCID (RRE).
  - WAIT DISCONNECT, and WAIT SELECT/RESELECT after a disconnect.
  - Self-modifying code: an extended message's length byte is moved into the next block move's
    DBC. This works because each block move flushes the write buffer before the next fetch.
  - No LOAD/STORE and no memory moves. `n810_script.mar` has a `cop` memory-move macro that can name
    chip registers, but `pke_script` does not use it.
  - `AVANTI` disables SDTR.
- **Class driver** (`scsi.c`):
  - Sends INQUIRY, including EVPD pages 0x80 and 0x83.
  - Sends **MODE SELECT(6) with a block descriptor of 512 bytes** to every disk-type unit, then
    READ CAPACITY, and **rejects a unit whose block length is not 512**.
  - Reads and writes in 512-byte units.

## 3. Coverage

### Registers (00-5F)

All registers are readable and writable as in the RS6K port.

| Register(s) | Model behaviour |
|---|---|
| SCNTL0-3, SCID, SXFER, SDID, GPREG, SFBR, SOCL, SSID | Stored |
| SBCL | Live bus lines |
| DSTAT | DFE always 1; read clears; stacked |
| SSTAT0 | Only RST |
| SSTAT1 | The latched phase |
| SSTAT2 | 0 |
| DSA, TEMP, DNAD, DSP, DSPS, SCRATCHA/B, ADDER | Full |
| ISTAT | ABRT, SRST (holds the chip in reset until cleared), SIGP, SEM, CON, INTF (write 1 clears), SIP, DIP |
| CTEST0/4/5/6 | Stored |
| CTEST1 | F0 |
| CTEST2 | CIO/DACK; SIGP clears on read |
| CTEST3 | Revision; CLF reads 0 |
| DFIFO | DBC<6:0> (no FIFO) |
| DMODE, DIEN, DWT, DCNTL | DCNTL STD starts, SSM single step, IRQD masks INTA |
| SIEN0/1 | Stored |
| SIST0/1 | Read clears; stacked |
| SLPAR, MACNTL, GPCNTL | Stored |
| STIME0 | Selection timeout code |
| STIME1 | General-purpose timer, one shot from the write (SIST1.GEN, reported only when enabled) |
| RESPID | Stored |
| STEST0-3 | STEST3 CSF reads 0 |
| SIDL, SODL, SBDL | The last byte in, the last byte out, the live data |

### SCRIPTS

- **Block move**: direct, indirect and table indirect; all phases. ATN drops before the last
  MESSAGE OUT byte, and ACK is held after the last MESSAGE IN byte. SFBR takes the first byte. A
  phase mismatch raises MA and UDC as appropriate. A count of 0 or CHMOV gives IID.
- **I/O**:
  - SELECT (absolute or table indirect, with ATN) with the STIME0 timeout giving SIST1.STO.
  - WAIT DISCONNECT.
  - WAIT RESELECT, which only leaves on SIGP.
  - SET/CLEAR of ACK, ATN, TARGET and CARRY.
- **Register instructions**: all eight operators, in the three forms (SFBR to register, register to
  SFBR, read-modify-write).
- **Transfer control**: JUMP, CALL, RETURN, INT, INTFLY; WHEN/IF phase and data/mask compares, carry
  test, absolute or relative addressing.
- **Memory move**: 1 to 16M bytes, source and destination with the same low address bits. Either
  end can be the chip's own registers: through BAR1 in memory space, or through BAR0 in I/O space
  with DMODE.SIOM/DIOM. Other I/O-space addresses give BF.
- **LOAD/STORE (new)**: 1-4 bytes between a register and memory, absolute or DSA-relative.
- **Single step (new)**: DCNTL.SSM gives DSTAT.SSI after every instruction; STD continues.
- **Halts**: IID, SIR, SSI, ABRT, plus the SCSI interrupts. Interrupts that arrive while one is
  pending are stacked.

### Target commands

| Command(s) | Model behaviour |
|---|---|
| TEST UNIT READY, REZERO, SEEK(6/10), RESERVE/RELEASE, START STOP, SEND DIAGNOSTIC, PREVENT ALLOW, VERIFY, SYNCHRONIZE CACHE | GOOD. On the CD, SEEK and START STOP with Start = 0 stop a play |
| FORMAT UNIT | GOOD; with FmtData the defect list (its header's length) is taken and ignored. ILLEGAL on the CD |
| REQUEST SENSE | Fixed format; it reports and clears a pending UNIT ATTENTION |
| INQUIRY | DEC strings `RZ28` and `RRD45`. EVPD gives CHECK CONDITION / ILLEGAL REQUEST 24 |
| READ/WRITE(6/10/12), WRITE AND VERIFY | Supported (WRITE on the CD: DATA PROTECT 27) |
| READ CAPACITY | Supported |
| READ DEFECT DATA | An empty list (disks) |
| MODE SENSE(6/10) | Disks: pages 1, 2, 3, 4, 8, 0A (3F = all, 100 bytes). The CD: 1, 2, 0D, 0E (52 bytes). DBD drops the block descriptor. Page control: changeable gives zeros except page 0E's selection (0F) and volume (FF); default gives page 0E at unity. Write protect is set on the CD. Other pages: ILLEGAL REQUEST 24 |
| MODE SELECT(6/10) | The CD takes the block descriptor's length (512 or 2048) and page 0E's port 0/1 selection and volume (every page of the list is walked); the rest is ignored |
| READ TOC (CD) | Formats 0 (from a start track; 0xAA = the lead-out), 1 (the last session's first track; the session count) and 2 (the full TOC: A0, A1, A2, the tracks, all as session 1); LBA or M:S:F; MMC byte 2 or SCSI-2 byte 9 bits 7:6. From Main's table; with none, one data track over the image |
| READ SUB-CHANNEL (CD) | SubQ off (header only); formats 1 (position, LBA or M:S:F), 2 and 3 (not valid). Audio status 11/12/13/15; 13 is reported once |
| PLAY AUDIO (10), (12), MSF, TRACK/INDEX (CD) | `cd_audio.v`. Address FFFFFFFF / FF:FF:FF = the current position. A start beyond the lead-out gives ILLEGAL REQUEST 21, and the end is clipped to it |
| PAUSE/RESUME (CD) | With no play: ILLEGAL REQUEST 2C |
| STOP PLAY/SCAN (CD) | Supported |
| READ CD (CD) | User data only (expected type any or mode 1, flags 10h; flags 0 = no data); else ILLEGAL REQUEST 24 |
| The CD with no image | NOT READY 3A for all but INQUIRY, REQUEST SENSE, MODE SENSE/SELECT, START STOP, PREVENT ALLOW, STOP PLAY |
| The CD after a (re)mount | UNIT ATTENTION 28 once, for anything but INQUIRY and REQUEST SENSE |
| CD commands on a disk | ILLEGAL REQUEST 20 |
| SDTR | Answered with the same period and an offset of at most 8 |
| Anything else (REPORT LUNS, LOG SENSE, 16-byte CDBs ...) | CHECK CONDITION / ILLEGAL REQUEST 20. A 16-byte CDB is taken whole first |

The CD's block size returns to 2048 only at power-on. A bus reset or a remount keeps it, as a mode
parameter is kept.

This fixes "bad SCSI status (b8)" at `boot dka400` (board build 13, 2026-11-01). The cause was:
- SRM selects 512 once, when it opens the unit, and a bus reset (its port init, a command timeout)
  does not make it select again.
- The model went back to 2048 on the bus reset, so a 1-block READ sent 2048 bytes into SRM's
  512-byte buffer.
- `pke_script` then found DATA IN at `pke_check_sts` and raised err104. The driver ran `pke_flush`,
  which drains the status into its own buffer and ends with `INT ok`.
- SRM read its status byte, never written (stack garbage 0xB8).

### The bench (`make -C verilator tb_ncr810`, all checks pass)

- **PCI header**: ID, a byte-length ID read, class/revision, functions and devices that must not
  claim, interrupt pin, BAR sizing (FFFFFF01 / FFFFFF00), no memory decode before the command
  enable.
- **The DROM test's exact accesses**, then SCRATCHB = 0x55555555.
- **Register access**: through both BARs (longword and byte), the 80-FF alias, DSTAT = 0x80, ISTAT,
  the CTEST3 revision.
- **SRM's init sequence**: SRST, the register set, the bus reset with SIST0.RST and read-clear.
- **SCRIPTS** against disk 0:
  - SELECT ATN, MESSAGE OUT IDENTIFY, COMMAND, a table-indirect DATA IN or OUT, STATUS,
    MESSAGE IN, CLEAR ACK, WAIT DISCONNECT, INT.
  - Commands run: INQUIRY (the strings in DMA memory), TEST UNIT READY, READ CAPACITY,
    READ(10) of 3 blocks (compared with the image), WRITE(10) (compared in the image), an illegal
    command then REQUEST SENSE.
  - INTA asserted on SIR with DIEN.SIR and released by the DSTAT read.
- **Selection timeout** on the absent ID 1: ISTAT.SIP, SIST1.STO.
- **Register operators and SFBR**, LOAD, STORE, DSA-relative LOAD, a memory move, and a memory move
  into the chip's own SCRATCHA through BAR1.
- **Single step**: two SSI stops, then SIR.
- **The CD-ROM at ID 4**: INQUIRY type 5 removable; READ CAPACITY with 2048-byte blocks; a 2048-byte
  READ; MODE SELECT 512; READ CAPACITY with 512-byte blocks; a 512-byte READ.
- **The CD's table and audio** (2026-11-01). The model serves Main's windows: a disc of a data track and
  two audio tracks in two sessions, with each sample numbered.
  - Without the window: the made-up one-track table and its lead-out M:S:F.
  - After `cd_change`: UNIT ATTENTION once, and REQUEST SENSE taking it.
  - READ TOC formats 0 (LBA, M:S:F, from track 2, past the last track), 1 (both encodings) and 2.
  - PLAY AUDIO MSF: all 2352 samples of track 2 on `cd_audio_l/r` in order at unity, silence after,
    the strobe count, READ SUB-CHANNEL while playing (11, track, M:S:F) and after (13, then 15),
    formats 0 and 2.
  - PAUSE with no play (2C).
  - MODE SELECT page 0E (port 0 = right at 128, port 1 = left at 255), MODE SENSE back with DBD and
    as changeable.
  - PLAY TRACK/INDEX 3 with a PAUSE (silence, status 12) and RESUME: every sample, swapped and scaled.
  - STOP during a play; PLAY past the lead-out (21).
  - READ CD of 2 sectors; the CD's mode page list and its missing page 4.
  - No disc: INQUIRY answers, then UNIT ATTENTION, then NOT READY 3A for TUR and READ CAPACITY; the
    disc back.
- **SRM's own SCRIPTS** (2026-11-01): a port of `pke_script.mar` (select, IDENTIFY, the
  table-indirect phases, `pke_check_sts`, `pke_sts`, `pke_msg_in`, `pke_flush`) and of
  `pke_driver.c`'s handling: SIR dispatch, the phase-mismatch fix-up of a short data phase, and the
  flush after an errNNN.
  - SRM's open and boot sequence runs on dka400 after a mount, with SRM's buffer lengths: INQUIRY
    255 and 1, REPORT LUNS, TUR, REQUEST SENSE, START UNIT, MODE SELECT 512, READ CAPACITY,
    READ(10) of block 0 and of 15 blocks, the 10-byte vendor EC.
  - Then a bus reset and a remount, each followed by a 1-block READ and READ CAPACITY.
  - Every status byte is checked (0x00 or 0x02 as expected; 0xEE = not written).
- **The disks' commands**: READ/WRITE(12) and (6) against the image, READ past the end (21), MODE
  SENSE 3F (the six pages in order, geometry), MODE SENSE(10) page 8 with DBD, FORMAT UNIT with and
  without a defect list, READ DEFECT DATA, SYNCHRONIZE CACHE, VERIFY, START STOP, READ TOC on a disk
  (20), a 16-byte CDB.

## 4. Known gaps

- **Disks never disconnect**: there is no reselection, so WAIT RESELECT only leaves on SIGP and
  SCID.RRE is ignored. That is legal SCSI behaviour, and SRM handles it: an IDENTIFY with the
  disconnect privilege only permits a disconnect.
- **No target mode, no low-level mode** (SCNTL0.START, SOCL/SBCL driving the bus), **no loopback**
  (STEST2.SLB), **no parity**, **no handshake-to-handshake timer**, and **no DMA FIFO** (DFIFO = DBC,
  CTEST6 does not push).
- **Interrupts**: the non-fatal SCSI interrupts (SEL, RSL, CMP) are never raised. GEN is the only
  timer interrupt besides STO.
- **No DMA error path** in `pci.md`, so there is no BF from a master abort.
- **LOAD/STORE on revision 2**: a real 53C810 at revision < 0x10 has no LOAD/STORE (the 810A
  added it). The model executes them anyway. Linux's `sym53c8xx` keys LOAD/STORE use on the
  revision, so with REV = 0x02 it does not use them.
- **STIME0 scaling**: the selection timeout is 2^code/16 ms (code 0xD = 512 ms). SRM's poll of
  absent IDs costs about 0.5 s each, as on the real machine.
- **CD audio limits**: `cdrom.md` 4 (indexes, UPC/ISRC, digital audio extraction, multi-session
  full TOC).
- **`cd_change` and the audio outputs** must be wired through `as200_sys` and the top (`img_mounted[2]`
  and the mixer).
