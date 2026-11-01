# SCSI: the NCR 53C810 and its targets

| File | What |
|---|---|
| `rtl/scsi/ncr53c810.v` | The 53C810: a PCI device (number 6, IDSEL AD17) on the internal PCI target bus and DMA port of `pci.md`. INTA goes to PIRQ3 |
| `rtl/scsi/scsi_targets.v` | Hard disks at ID 0 (`dka0`) and ID 1 (`dka100`), and a CD-ROM at ID 4 (`dka400`), on hps_io block-device slots 0, 1 and 2 |
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
  - `pt_ack` is a registered one-cycle pulse, one cycle after the request is accepted. The device
    never re-accepts while `pt_ack` is high.
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
- `inta_n` is active low and level-sensitive.
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

### Targets (`scsi_targets #(DISK0_ID = 0, DISK1_ID = 1, CD_ID = 4)`)

- A single clock: hps_io runs on the system clock in this core.
- Ports are flat; slot s occupies `[32s+31:32s]` of `img_blocks` and `sd_lba`, and `[6s+5:6s]` of
  `sd_blk_cnt`.
- `sd_rd[2:0]`, `sd_wr[2:0]`, `sd_ack[2:0]`, `sd_buff_addr`, `sd_buff_dout`, `sd_buff_wr` connect to
  hps_io's 8-bit side. There is one `sd_buff_din` for all slots; the top fans it out.
- `img_present[2:0]` and `img_blocks` (the size in 512-byte blocks) are latched by the top from
  `img_mounted`/`img_size`.
- `cd_change` is pulsed when the CD slot is remounted.
- `activity` is high while a target is connected.
- Requests are up to 4 blocks (2 KB, the sector buffer).
- The CD slot keeps the RS6K design:
  - Main serves a flat disc of 2048-byte sectors as 512-byte LBAs.
  - The track table is at block `C000_0000` (`support/*_cdrom.cpp` of the HP/RS6K families, still
    to be cloned into `support/decalpha`).

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

**The model passes this test.** Configuration 0x80-0xFF goes to the register file. The bench runs
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
| TEST UNIT READY, REZERO, FORMAT, SEEK, RESERVE/RELEASE, START STOP, SEND DIAGNOSTIC, PREVENT ALLOW, VERIFY, SYNCHRONIZE CACHE | GOOD |
| REQUEST SENSE | Supported |
| INQUIRY | DEC strings `RZ28` and `RRD45`. **EVPD gives CHECK CONDITION / ILLEGAL REQUEST (new)** |
| READ/WRITE(6/10) | Supported |
| MODE SENSE(6/10) | Pages 1, 3, 4 and 8; 0E on the CD; write-protect bit set on the CD |
| MODE SELECT(6/10) | **The CD takes the block descriptor's block length: 512 or 2048 (new)**; the rest of the parameter list is ignored |
| READ CAPACITY | Supported |
| READ TOC | From Main's table, else one data track |
| READ SUB-CHANNEL | "No audio status" |
| PLAY AUDIO, PAUSE, STOP | Accepted, do nothing |
| SDTR | Answered with the same period and an offset of at most 8 |
| Anything else | CHECK CONDITION / ILLEGAL REQUEST |

The CD's block size returns to 2048 on a bus reset or a remount.

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
- **No CD audio**: PLAY and the rest are accepted and do nothing. `hp9000-715/rtl/scsi/cd_audio.sv`
  can be brought back later.
- **Not yet in the machine**: `rtl/as200_sys.v` does not instantiate the controller yet (other work
  is in progress there), and neither the MiSTer top's hps_io slots nor Main's `support/decalpha`
  write buffer and CD layer are wired.
