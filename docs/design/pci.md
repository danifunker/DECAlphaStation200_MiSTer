# PCI and ISA inside the core: the interfaces

The 21071-DA ("EPIC") side of `rtl/apecs/apecs.v` turns CPU accesses to the PCI spaces into
transactions on one internal **PCI target bus** shared by all PCI devices, and turns PCI masters'
**DMA** into memory accesses through the scatter/gather windows. The 82378 SIO is a PCI device
that also owns the **ISA bus**. Every device module is plain Verilog (`.v`) and implements exactly
the ports below. All signals are synchronous to the system clock (100 MHz target).

## 1. CPU address -> PCI (21071 data sheet ch. 10; Linux `core_apecs.c`)

| CPU PA | Space | PCI address |
|---|---|---|
| 1.C000.0000-1.DFFF.FFFF | sparse I/O | `PA<28:5>` (HAXR2 not used: I/O < 16 MB), length `PA<4:3>`: 0 byte, 1 word, 3 longword; byte lane from `PCIaddr<1:0>` |
| 1.E000.0000-1.FFFF.FFFF | configuration | type 0 on bus 0: device `PA<20:16>` (IDSEL = AD<11 + device>), function `PA<15:13>`, register `PA<12:7>` x 4, length as above. Bus != 0 (type 1, via HAXR2): master abort |
| 2.0000.0000-2.FFFF.FFFF | sparse memory | `{HAXR1<31:27>, PA<31:5>}`-style (21071 10.x; implemented with the TGA) |
| 3.0000.0000-3.FFFF.FFFF | dense memory | `PA<31:0>`, longword/quadword |

AS200 device numbers (HARDWARE.md): **6 = 53C810 (AD17)**, **7 = 82378 SIO (AD18)**,
11 = 21040 (AD22), 12 = PCI slot 1 / TGA (AD23), 13 = slot 2 (AD24).

## 2. PCI target bus (apecs -> devices)

apecs drives one request at a time to all devices:

| Signal | Dir (device view) | Width | Meaning |
|---|---|---|---|
| `pt_req` | in | 1 | a transaction is offered; held until this device's `pt_ack` or the cycle is abandoned (no claim) |
| `pt_cmd` | in | 2 | 0 configuration, 1 I/O, 2 memory |
| `pt_dev` | in | 5 | configuration: device number (the device compares it with its own, i.e. its IDSEL) |
| `pt_addr` | in | 32 | I/O and memory: PCI byte address (bits 1:0 = 0); configuration: `{function<2:0> in [10:8], register in [7:2]}` |
| `pt_be` | in | 4 | byte enables (active high) |
| `pt_we` | in | 1 | write |
| `pt_wdata` | in | 32 | write data, lane-aligned (byte k in bits 8k+7:8k) |
| `pt_claim` | out | 1 | **combinational**, the same cycle as `pt_req`: this device decodes the access (config: `pt_dev` is its device and the function exists; I/O/memory: inside one of its enabled BARs) |
| `pt_ack` | out | 1 | one-cycle pulse: done; for reads `pt_rdata` is valid in the same cycle |
| `pt_rdata` | out | 32 | read data, lane-aligned |

apecs waits for `pt_ack` from the claiming device. No claim: configuration and memory reads
return all ones (master abort); **I/O with no claim goes to the SIO's ISA side** (the 82378 is
the subtractive decoder), and the SIO claims it through its `pt_sub` input.

## 3. DMA (devices -> memory)

| Signal | Dir (device view) | Width | Meaning |
|---|---|---|---|
| `dm_req` | out | 1 | request, held until `dm_ack` |
| `dm_we` | out | 1 | write |
| `dm_addr` | out | 32 | PCI byte address, longword aligned |
| `dm_be` | out | 4 | byte enables |
| `dm_wdata` | out | 32 | |
| `dm_ack` | in | 1 | one-cycle pulse; `dm_rdata` valid with it |
| `dm_rdata` | in | 32 | |

apecs translates through windows 1/2 (21071-DA W_BASE/W_MASK/T_BASE; scatter/gather later) and
arbitrates with the CPU for the DRAM port. A DMA write invalidates the CPU's D-cache line
(the 21071's `dInvReq`). Several masters are muxed by a fixed-priority arbiter in `as200_sys.v`.

## 4. Interrupts

Each PCI device has `inta_n` (active low, level). AS200 wiring (HARDWARE.md 3): PIRQ0 = 21040 |
slot1 B | slot2 C, PIRQ1 = slot1 A | 1D | 2B, PIRQ2 = 1C | 2A | 2D, **PIRQ3 = 53C810**. The 82378
routes PIRQ0-3 to ISA IRQs (its PIRQ route registers) into the 8259s; the 8259 pair's INTR is
CPU IRQ2, and the PALcode reads the vector with a PCI interrupt-acknowledge cycle (apecs: a read
of the IACK space, `pt_cmd` = 3, claimed by the SIO).

## 5. ISA bus (inside the SIO module)

The SIO module (`rtl/sio/sio82378.v`) holds the 82378's own registers and the ISA devices:

| ISA I/O | Device | Module |
|---|---|---|
| 000-01F, 080-08F, 0C0-0DF, 040A/048x | 8237 x2 + page registers + 82378 extensions | `isa_dma.v` |
| 020-021, 0A0-0A1, 4D0-4D1 | 8259 x2 + ELCR | `isa_pic.v` |
| 040-043, 061 | 8254 + port B (speaker, refresh toggle) | `isa_pit.v` |
| 060, 064 | 8242 keyboard/mouse controller | `isa_kbc.v` |
| 070-071 | BQ4285 TOY/RTC (MC146818 + CMOS); periodic interrupt -> **CPU IRQ4** directly | `isa_rtc.v` |
| 398-399 | PC87332 configuration (index/data) | `isa_superio.v` |
| 3F8-3FF, 2F8-2FF | COM1, COM2 (16550) | `ns16550.v` (exists) |
| 378-37F | parallel port | `isa_superio.v` |
| 3F0-3F7 | floppy controller | later |
| 530-537, 388-38B | AD1848 WSS, OPL3 | later |

ISA devices use a byte bus: `io_addr[15:0]`, `io_rd`, `io_wr` (one-cycle strobes), `io_din[7:0]`,
`io_dout[7:0]` (combinational from registers, read side effects on the strobe), plus their IRQ
lines into the 8259s.
