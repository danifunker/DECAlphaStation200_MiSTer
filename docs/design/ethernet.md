# Ethernet: the DECchip 21040 and Main_MiSTer's bridge

| File | What |
|---|---|
| `rtl/net/tulip21040.v` | The 21040 "Tulip": a PCI bus master (device 11, IDSEL AD22, INTA -> PIRQ0) on the internal PCI target bus and DMA port of `pci.md`, with its Ethernet ID ROM. Instantiates `tulip_nb` |
| `rtl/net/tulip_nb.v` | The wire: Main_MiSTer's Ethernet mailbox in DDR3 (the `nb_*` port) |
| `verilator/tb/tb_tulip.cpp` | The unit bench: `make -C verilator tb_tulip` |
| Main: `support/decalpha/decalpha_enet.cpp/.h` | The host side of the mailbox (branches `dec-alphastation` in `../Main_MiSTer-decalpha`, `scsi-consolidated-2-decalpha` in `../Main_MiSTer-consolidated`) |

References: DEC's *DECchip 21040 Ethernet LAN Controller for PCI Hardware Reference Manual*
(EC-N0752-72) and data sheet (EC-N0280-72), `scratch/refs/`; SRM's `ew_driver.c`, `tu.h`,
`tupb.h` (`scratch/ebsdk/sw/srmconsole/5.8/src/`, DEC-licensed, read for facts only); AXPbox
`DEC21143.cpp` (GPL-2, reference only). No code comes from either.

## 1. Interface

`tulip21040 #(DEVNUM = 11, REV = 8'h23, CLK_MHZ = 100, ROM_WAIT = 32, POLL = 4096)`

| Port | Dir | What |
|---|---|---|
| `clk`, `reset` | in | the system clock (100 MHz), the machine reset (also restarts the mailbox) |
| `pt_*` | | the PCI target bus exactly as `pci.md` 2: `pt_claim` combinational (config: `pt_dev == DEVNUM`, function 0; I/O inside CBIO with CFCS<0>; memory inside CBMA with CFCS<1>), the request registered, `pt_ack` two cycles after acceptance, `pt_rdata` 0 except with `pt_ack` |
| `dm_*` | | the DMA port of `pci.md` 3: one longword per request, `dm_req` held until `dm_ack`, all outputs registered. Descriptor reads/writes, setup frames, transmit buffers (read a longword, used a byte at a time, any alignment), receive buffers (aligned longwords, `dm_be` for a partial last longword) |
| `inta_n` | out | registered, active low, level: `NIS & CSR7<16> | AIS & CSR7<15>` |
| `mac[47:0]` | in | the ID ROM's station address, first byte in 47:40 |
| `link_up` | in | the medium: 10BASE-T link pass (or AUI carrier) |
| `nb_req, nb_we, nb_addr[12:0], nb_wdata[63:0]` | out | the mailbox port (section 5) |
| `nb_ack, nb_rdata[63:0]` | in | |
| `nb_pmac[47:0], nb_pmac_ok` | out | Main's ROM address (mailbox word 7, bit 63 = valid) |
| `nb_link` | out | Main's bridge is up (word 7 bit 62) |

The top derives the ROM address: `mac = nb_pmac_ok ? nb_pmac : 48'h08002B_xxxxxx` (a fixed DEC
address when Main has no bridge), and `link_up = 1'b1` (always a link: SRM and the OSes see a
working 10BASE-T port with nothing on it when the OSD says None) or `nb_link`.

## 2. PCI configuration (HRM 3.1)

| Reg | Value |
|---|---|
| CFID 00 | `0002_1011` |
| CFCS 04 | command bits 8, 6, 2, 1, 0 writable; status: DEVSEL medium (01), fast back-to-back (bit 23), bits 31-28 and 24 write-1-to-clear (never set: no parity or aborts) |
| CFRV 08 | `0200_00` + `REV` = `0x23`: pass 2.3. SRM's `tu_init_device` issues the software reset only for rev >= 0x20 on a 21040, NetBSD's tlp refuses pass 1 (< 0x20). The HRM gives `0200FF2x` (bits 15:8 = FF): this core reads 00 there, the class code PCI expects |
| CFLT 0C | bits 15:8 (latency timer) |
| CBIO 10 | I/O, 128 bytes (bits 31:7) |
| CBMA 14 | memory, 128 bytes |
| CFIT 3C | interrupt pin 1 (INTA), line writable |
| CFDA 40 | bits 15:8, the driver's (SRM writes 0 there: "the serial ROM") |

Software reset (CSR0<0>) leaves the configuration alone (HRM 5.1).

## 3. CSRs (HRM 3.2; at CBIO/CBMA + 8n, longword access; the odd longwords read 0)

| CSR | Implemented |
|---|---|
| 0 bus mode | stored (reset FFF80000). SWR: a software reset once no DMA is out (the DMA arbiter must see its `dm_ack`); every CSR to its reset value, both processes stopped, the frame buffers' handshakes with the mailbox side untouched. DSL is the descriptor skip; BLE swaps the bytes of data buffers and the setup frame (not descriptors); TAP polls a suspended transmit process every 200 us / 800 us / 1.6 ms. PBL, CAL, BAR (round robin: implemented as alternating jobs), DAS: stored |
| 1, 2 poll demands | effective only while the process is suspended; read FFFFFFFF |
| 3, 4 list bases | a write also sets the current descriptor (the list head) |
| 5 status | TI TPS TU RI RU RPS LNF set by the engine, write-1-to-clear; NIS / AIS the OR of the bits unmasked in CSR7 (so a polled driver with NIM = 0, SRM's `0x0C007FFF`, still sees NIS); TS / RS the process states. TJT, UNF, RWT, AT, FD, SE never set |
| 6 operation mode | ST, SR (start/stop with the HRM 5.5.4 / 5.6.3 transitions: TPS / RPS on stop, the list position kept), OM (01 internal and 10 external loopback both loop inside the chip, the frame with its CRC into the receive list, DT = OM; nothing goes to the wire), PR (set after reset), PM, PB (runts kept). HP, HO, IF are read-only and follow the last setup frame's filtering type. FD, FKD, SB, BP, CA, TR, FC: stored |
| 7 interrupt mask | bits 16, 15, 13-5, 3-0 |
| 8 missed frames | count and overflow, cleared by the read |
| 9 ID ROM | a write resets the pointer and starts a byte; a read with DN clear returns the byte and starts the next (DN = bit 31 set for `ROM_WAIT` clocks meanwhile) |
| 11 | stored, reads FFFF + value |
| 12 SIA status | SIA in reset (CSR13<0>, <1>, <2> all clear): C4 (LKF), the reset value. Running: DSP DSD APS, LKF = 10BASE-T and no `link_up`, NCR = no `link_up`. A link fail sets CSR5<12> |
| 13-15 SIA | stored (reads FFFF + value); CSR13<3> picks AUI for the link report |

### The Ethernet ID ROM

The 32 bytes in DEC's station address ROM format, from `mac`: bytes 0-5 the address, 6-7 the
checksum (big-endian), 8-15 bytes 7..0, 16-23 bytes 0-7 again, 24-31 `FF 00 55 AA FF 00 55 AA`.
The checksum is DEC's: three big-endian 16-bit words, `c = 2c + w` each, mod 65535 (65535 -> 0).
SRM's `tu_check_nirom` checks exactly that (no null address, the checksum, `ni[15-i] == ni[16+i]`,
the pattern); NetBSD's `tlp_parse_old_srom` and Linux's de4x5 do the same sum on little-endian
words against bytes 6-7 as little-endian, which is the same checksum byte-swapped (a byte swap is
a multiplication by 256 mod 65535). The bench runs both checks.

## 4. The engine

One state machine runs one job at a time from its idle state: the receive process's start or poll
(fetch the current descriptor's OWN), a received frame (filter, then the descriptors), or one
transmit descriptor. Receive goes first (HRM 5.2) unless CSR0<1> asks for round robin.

**Transmit.** A descriptor job reads TDES0 (host-owned: TU unless already suspended, the process
suspends), TDES1-3, then:
- **SET**: 48 longwords from TDES2, their low halves into the setup RAM (48 x 16), the filtering
  type (TDES1<28,22>) into CSR6 HP/HO/IF, TDES0 = 7FFFFFFF (HRM 4.2.3), TI if IC. FS/LS are
  ignored (SRM sets them on its setup frames).
- **data**: FS restarts the frame; buffer 1 then buffer 2 (unless TCH) go byte by byte into the
  2 KB transmit buffer (and its CRC). A descriptor without LS is released (TDES0 = 0) and the next
  one continues the frame. At LS: pad to 60 bytes unless DPD; in loopback append the CRC (unless
  AC on an unpadded frame), else hand the frame to the mailbox side (without the 4 CRC bytes the
  driver supplied with AC). TDES0 = 0 (no errors; HF is not set), TI if IC. With no link
  (`link_up` low or the SIA in reset, normal mode) the frame is not sent: TDES0 = ES | LO | NC
  (| LF in 10BASE-T).
- The next descriptor: TER -> CSR4, TCH -> TDES3, else + 16 + 4 * DSL.
A new frame waits while the previous one is still being copied into the mailbox (`tb_busy`).

**Receive.** The receive buffer (2 KB) holds one frame with its FCS. The filter reads the
destination, runs the CRC over it (the hash index is CRC<8:0> of the reflected CRC, as Linux's
`ether_crc_le & 0x1FF`; the HRM's Example 4-2 checks out) and decides: runts (< 64) only with PB;
PR; PM for multicast; hash-only (HO) or 512-bit hash + 1 (HP, multicast through the table,
physical against setup words 39-41); else the 16 perfect entries, inverted by IF. Then:
- the receive process stopped: dropped; suspended or running: the current descriptor is fetched
  (host-owned: RU unless already suspended, the frame counts in CSR8);
- the frame goes into buffer 1, then buffer 2 (unless RCH), in longwords. A buffer holds its size
  rounded down to a multiple of 4 unless the frame ends in it (SRM's 1518-byte buffers take a
  1518-byte frame whole): every buffer starts at a longword of the frame;
- more frame than buffers: the next descriptor is checked first. Ours: this one is released
  (OWN = 0, FS on the first) and the frame goes on. Host-owned: this one closes as the last with
  LS | LE | ES, RI, RU, suspended (HRM 4.2.1.1);
- the last descriptor: FL (with the CRC), ES (= TL | RF), DT = OM, RF, MF, FS, LS, TL (> 1518),
  FT (type > 1500); then RI and a prefetch of the next descriptor (host-owned: RU, suspended).

Not modelled (store-and-forward makes them impossible or they need a real wire): underflow,
overflow, collisions, jabber, the receive watchdog, dribble bits, CRC errors, heartbeat, the
full-duplex short frame (CSR11), back pressure, capture effect, the SIA's diagnostic modes.

## 5. The mailbox (`tulip_nb.v`, `nb_*`)

The layout the HP 9000, RS/6000 and Sun cores share with Main_MiSTer (`ddr3_port.sv` in the HP
core): 64 KB of DDR3 at byte **0x1FF0_0000**, 64-bit little-endian words, `nb_addr` = byte offset / 8.

| Word / offset | Owner | What |
|---|---|---|
| 0 | core | magic `DAETH001` (0x4441_4554_4830_3031), written last at start-up: Main's RX ring is 16 slots |
| 1 | core | generation (a free-running count at start-up) |
| 2 / 3 | core / Main | TXW (frames posted) / TXR (frames taken) |
| 4 / 5 | Main / core | RXW / RXR |
| 6 | core | the station address the chip answers to (the ROM address): bit 63 valid, bits 47:40 the first byte. Main filters eth0 on it (BPF) or makes the macvlan with it |
| 7 | Main | PMAC: bit 63 valid, bit 62 the bridge is up, 47:0 `08-00-2B` + the low three bytes of the MiSTer's eth0. Cleared by the core at start-up, written by Main at each new generation and when its link opens or closes |
| 0x1000 | core | 8 TX slots of 0x800 bytes: word 0 the length (bits 10:0, no FCS), the frame from word 1 |
| 0x5000 | Main | 16 RX slots: word 0 the length with the FCS, the frame from word 1 (Main pads to 60 and appends the FCS) |

Start-up (after `reset`): magic 0, TXW TXR RXW RXR 0, word 6, word 7 = 0, the generation, the
magic. Then: a frame to send reads TXR until a slot is free (gives up after ~65000 tries), writes
the words, the header, TXW + 1. Every `POLL` clocks (41 us) it reads RXW; a new frame is copied
into the chip's receive buffer when the chip can take one (not in loopback, the buffer empty), then
RXR + 1, and it looks again at once. PMAC is read at every poll until Main has written it, then
every 16th.

**The port for the DDR3 arbiter** (`rtl/mister/ddr3_arb.v` needs a client for it):
- same clock as the machine (`clk`, 100 MHz = `DDRAM_CLK`);
- `nb_req` is held until `nb_ack`; `nb_we`, `nb_addr`, `nb_wdata` stay steady meanwhile; one
  64-bit word per request: `DDRAM_ADDR = 29'h03FE_0000 + nb_addr`, `DDRAM_BURSTCNT = 1`,
  `DDRAM_BE = 8'hFF`;
- `nb_ack` is a one-cycle pulse: for a write when the bridge took it, for a read with `nb_rdata`
  (the word, `DDRAM_DOUT`);
- traffic: one read per 41 us when idle; a frame is about 2 + length / 8 back-to-back words; it
  can have the lowest priority (no deadline; latency only slows the network).

## 6. Main_MiSTer (`support/decalpha/decalpha_enet.cpp`)

Modelled on `support/ibmrs6k/ibmrs6k_enet.cpp`; gated on the core name (`is_decalpha()`), hooked in
`user_io.cpp` next to the other bridges (stop at core load, start before the ROM loads, poll in the
main loop) and `support.h`. The OSD option it reads is **`[23:21]`**: the core's
`DECAlphaStation200.sv` needs

    "O[23:21],Network interface,eth0,None,eth1,macvlan,tap0;",

(top page, as on the HP 9000/715; Main reads it at once, so it stays out of `cfg`). Modes: eth0
(promiscuous raw socket, BPF on word 6 plus multicast where the tree has
`ethernet_set_mac_filter_mcast`; the call is a weak symbol, so the PR branch off master builds with
the plain filter), None, eth1, a macvlan on eth0 named `dec0`, tap0.

## 7. What the drivers use (and the bench covers)

| Driver | Uses | Bench |
|---|---|---|
| SRM `ewa0` (ew_driver.c) | CFRV >= 0x20 -> SWR; CSR9 32 bytes with DN polling and `tu_check_nirom`; CSR0 = PBL8 \| CAL1; CSR13/14/15 media (TP `EF01`/`7F3D`/`0008`, AUI, auto-sense through CSR12 LKF); CSR6 = 0, CSR7 = `0C01FFFF` (or polled `0C007FFF`); TX ring (TER, 8 or 16), RX ring of 1518-byte buffers (RER); a 192-byte perfect setup frame with FS/LS/IC; CSR5 NIS/AIS loop with W1C; internal/external loopback for its tests | all of it but the auto-sense timing |
| NetBSD `tlp` / `de` | rev >= 0x20, the old-format ROM (LE checksum), perfect and hash setup frames, CSR12 media | ROM, both setup types, hash with HP |
| Linux `de4x5` / `tulip` | CSR9 ROM reads `while (inl(CSR9) < 0)`, CSR12 LKF/NCR for TP/AUI, rings with chained descriptors | DN, CSR12, TCH |
| Digital UNIX `tu`, NT `dc21x4` | (by the HRM) | the same register model |

`make -C verilator tb_tulip`: 1526 checks: the header, BAR sizing, reset values through both BARs,
the mailbox start-up and PMAC, the ROM as SRM reads it with SRM's and NetBSD's checks, link pass,
the perfect setup frame, TX (two buffers with an unaligned one, two chained descriptors, padding,
AC), RX (perfect, broadcast, multicast in/out of the table, 1514 bytes, PM, PR, RU, the missed
frame counter, a poll demand), the hash setup frame, a frame over three descriptors, truncation
(LE), internal loopback with the CRC checked, link fail (CSR12, LNF, TDES0), transmit automatic
polling, software reset.

## 8. Integration (as200_sys.v, the top, files.qip)

1. `files.qip`: `rtl/net/tulip21040.v`, `rtl/net/tulip_nb.v`.
2. `as200_sys.v`: instantiate `tulip21040 #(.DEVNUM(11)) u_enet` on `pt_*`; OR `enet_claim` into
   `pt_claim`, `enet_ack` into `pt_ack`, `enet_rdata` into `pt_rdata` (0 unless it acks); **add
   `!enet_claim` to the SIO's `pt_sub`** (the SIO decodes subtractively). Its DMA joins the
   fixed-priority arbiter as a third master (after the 53C810 and the SIO). `inta_n` is PIRQ0:
   `.pirq_n({scsi_inta_n, 2'b11, enet_inta_n})`. The `nb_*`, `mac`, `link_up`, `nb_pmac*` and
   `nb_link` ports go up to the top.
3. Top: `nb_*` into the DDR3 arbiter (section 5); `mac = nb_pmac_ok ? nb_pmac : 48'h08002B_xxxxxx`;
   `link_up = 1'b1` (or `nb_link`); the OSD line of section 6.

## 9. Gaps

- The address the guest uses: word 6 is the ROM address. A guest that changes its station address
  in the setup frame (DECnet's AA-00-04-00-xx-xx) gets no unicast through Main's eth0 BPF filter
  (macvlan and tap0 are not filtered that way). The core could publish setup entry 0 instead.
- Error conditions (section 4) are never reported; collisions, jabber, CRC errors cannot happen.
- External loopback does not reach the wire (the HRM's external loopback with a shunt would
  receive its own frame and also put it on the wire).
- CSR13-15 diagnostic modes, the SIA self-test, the AUI/TP pin (CSR5<10>), full-duplex
  auto-configuration (CSR11) are stored but do nothing.
- Big-endian (BLE) data buffers are implemented but not in the bench.
- No timing fit yet; the engine is registered throughout (the longest paths: the receive buffer
  size compare + add in S_RXW0, the byte CRC behind a 4:1 byte mux).
