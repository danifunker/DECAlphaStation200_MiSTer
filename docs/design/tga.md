# The TGA: ZLXp-E1 (DECchip 21030, Bt485, 2 MB) in PCI slot 1

`rtl/tga/` models the AlphaStation 200's graphics card: a DECchip 21030 ("TGA") with 8 planes,
2 MB of VRAM and a Brooktree Bt485 RAMDAC (CORE_SPEC Video row). It is a device on the core's
internal PCI bus (`docs/design/pci.md`: target `pt_*`, master `dm_*`, `inta_n`). VRAM is in
DDR3 behind `rtl/mister/ddr3_arb.v`, shared with the flash image and the LAN mailbox.

Sources, used as references for facts only: DEC's SRM TGA driver (`scratch/ebsdk/sw/apisrm/ref/tga_driver*.c`,
`tga_sfbp_def.h`, `tga_sfbp_485.h`, `tga_sfbp_driver_crystal.h`; DEC-licensed, not copied),
the EB firmware (`scratch/ebsdk/ebfw/lib/tga.c`), Linux `drivers/video/fbdev/tgafb.c` and
`include/video/tgafb.h`, and NetBSD `sys/dev/pci/tga.c`, `tga_conf.c`, `tgareg.h`, `dev/ic/bt485.c`.
Copies of the last two are in `scratch/refs/tga/`.

| File | What |
|---|---|
| `rtl/tga/tga.v` | PCI header, request handling, command queue, the 21030 registers, the drawing engine, DMA |
| `rtl/tga/tga_bt485.v` | Bt485: registers, palette, cursor colours, cursor RAM (with copies read in the pixel clock domain) |
| `rtl/tga/tga_video.v` | the line fetch into a double line buffer, and the beam (`clk_pix`) with the palette and cursor |
| `rtl/tga/tga_vsel.v` | picks the TGA picture or the serial terminal (`vterm`) for the MiSTer video output |
| `rtl/mister/ddr3_arb.v` | the DDR3 arbiter: display fetch, TGA port (write merge + FIFO), flash (`fbrom.v` unchanged), LAN mailbox |
| `verilator/tb/tb_tga.cpp`, `tb_tga_top.v` | the bench (`make -C verilator tb_tga`) |

## 1. What the software uses

**SRM** (the console build `lx164_files.bld`: `FULL_TGA 0`, so no tests, no COPY64, no line code):
- **PCI:** it matches ID `00041011` without checking the class. If the revision is below 3, SRM forces the BAR0 size to 128 MB. It needs the command register's memory and master bits set. It writes cfg 40 and 44 = 0.
- **Identification:** it reads the **ROM word** at BAR+0, masked with `& 0x3fff`. Bits 13:12 are the module (0 = 8-plane) and bits 11:8 are the switch, which selects the mode table. It also reads register 054 (revision). It never reads the deep register and never reads the RAMDAC.
- **Init:** deep = 0x1C000 (0x0C000 with sync on green), then pixel masks, rop 3, plane mask. Next comes a block-stipple probe: it writes VRAM 0x400 in mode 0x0D and reads it back, expecting `12345678`. Then the H/V timing from the table, VVBR = 1 (so the console starts at VRAM 0x1000), SISR = 0x1F, and VVVR = 1.
- **Bt485:** it writes through EPSR 0C0 and EPDR 1F0. The values are CR0 = A2, CR1 = 40, CR2 = 35 (three-colour cursor), CR3 = 14 (64x64), mask FF. It loads the 3-3-2 palette and a cursor RAM underline at rows 14-15. Cursor colours are 1, 2 black and 3 white. The position is col*9 + 64, row*16 + 64.
- **Lines:** every mode gets +4 pixels and the "odd" bit set, so a 1024 line is 1028 bytes. Lines are not quadword aligned.
- **Text:** opaque stipple, mode 01. FG is the background colour, BG the foreground colour, and the mask is inverted. The persistent pixel mask is `1FF << (addr & 3)`.
- **Clear and fill:** block fill, mode 2D. Count words go every 32 bytes (overlapping), or through the address 03C and start 054 pair for unaligned starts. Before every fill SRM reads back the mode register (read-modify-write).
- **Scroll:** **DMA**, one scanline at a time. It sets DMA write copy (1F) from the frame buffer to host memory, then DMA read copy (17) from host memory to the frame buffer. After each step it writes 1FC = 0 and polls 1FC until it reads 0.
- **Interrupts:** none enabled. It writes SISR = 0x1F.

**Linux tgafb:**
- **Identification:** the type comes from `readl(BAR+0) >> 12 & 0xF`. Registers are at 0x100000 and the frame buffer at 0x200000.
- **set_par:** writes VVVR with video and blank set, then deep 0x14000 (busy-wait on 1F8 around it), rop 3, mode 0, base 0, clock bits, plane mask and pixel mask FFFFFFFF, then the H/V timing. Bt485 values are CR0 A2, CR3 14, CR1 40, CR2 20, mask FF, then the palette. Finally VVVR = 1.
- **Drawing:** block fill 2D with count | align<17:16>, both mask registers 0x80 and 0x5C, and opaque stipple 01 for text.
- **Copies:** COPY64 (160/164) for whole lines. Copy mode 07 (source/destination pairs) for other copies aligned to 8 pixels.
- **Mode:** the default is 640x480.

**NetBSD tga:**
- **Requirements:** BAR0 must be **prefetchable**, or it panics. GREV<7:0> must be 1-4. It identifies the board from the deep register as written by the firmware: 8-plane, a 4 MB map, and "wide" (bit 9 = 0) gives T8-02, with the frame buffer at 2 MB and VVBR in units of 4 KB.
- **Geometry:** the width comes from VHCR. If odd is set it clears odd and bit 0. It writes CCBR = 0 and VVBR = 1.
- **Drawing:** opaque stipple 01 for text, block fill 2D, and COPY64 with register aliases every 1 KB.
- **Bt485:** writes go to EPDR `(rs << 9) | val`. Reads write EPSR `(rs << 1) | 1` and take EPDR<23:16>. It uses the Bt485 cursor (+64 bias) and reads CR0, CR2 and CR3 (indirect). It uses the end-of-frame interrupt (SISR 0x10001) for colour-map updates.

## 2. PCI

| | |
|---|---|
| Header | ID `00041011`; command bits 1, 2, 6, 8 writable; status medium DEVSEL; revision **03** (`REV`); class **038000** (display, other: the 21030 is not VGA; nothing checks it); INT pin A |
| BAR0 | 128 MB (`F8000008` sizing), 32-bit, **prefetchable** (NetBSD) |
| cfg 40, 44 | read/write (palette snoop / PAER); no effect |
| Claim | combinational: config with `pt_dev` = 12 and function 0; memory with `PCI_CMD.MEM` and `pt_addr<31:27>` = BAR |
| Timing | requests registered when accepted; config, register reads and 1F8/1FC answer in 2-4 cycles; writes are posted into an 8-entry command queue (`pt_ack` 2 cycles); frame buffer reads and other register reads wait for the queue and engine to drain. 1F8/1FC are never held (the CPU polls them while the engine's DMA uses apecs). Writes to 1F8/1FC and the ROM space are dropped |

**Address map.** The BAR holds 4 MB that alias through the 128 MB. Offset 0 of the ROM space reads
`ROM_WORD` = `00000800`: module 0 and **switch 8**, which is SRM's 1024x768 @ 60 Hz table entry at
65 MHz. The rest of the ROM space reads 0. Registers are at 0x100000 and alias every 1 KB. The frame buffer is at 0x200000.

## 3. Registers

The table lists offsets from 0x100000. Every register in 000-1FF that is not listed reads back what was written.
That covers the copy buffer 000-01C, Bresenham, stencil, the Z and colour registers, the slopes and the other block colours.

| Off | Register | Model |
|---|---|---|
| 020/024 | foreground / background | data of opaque/transparent modes; byte `addr & 3` per pixel |
| 028 | plane mask | `{pm, pm}` over the quadword; not all ones = read-modify-write |
| 02C / 05C | pixel mask one-shot / persistent | one-shot until the next frame buffer write; 02C reads the mask in force |
| 030 | mode | <15:0> stored; reads `{copy toggle <20>, mode}`; a write clears the toggle |
| 034 | raster op | <3:0> the X11 function code (0 clear ... 3 copy ... 15 set); <11:8> stored |
| 038 | pixel shift | <3:0>; COPY64 reads from source - shift (NT gives aligned addresses and the offset here; SRM byte addresses with 0). Copy mode 07 ignores it |
| 03C, 054 | address, start | a write of 054 in a fill mode fills from VRAM byte 03C; 054 reads the revision (03) |
| 050 | deep | stored; <9> picks the VVBR unit (0: 4 KB, 1: 2 KB, NetBSD's T8-02/T8-01) |
| 060, 074 | TGA cursor base, XY | stored (060 reads <3:0> = 0); the TGA cursor is **not displayed** (SRM and NetBSD use the Bt485 cursor) |
| 064, 068 | horizontal, vertical | the display mode (6) |
| 06C | video base | display start = VVBR x unit |
| 070 | video valid | <0> video on, <1> blank |
| 07C | interrupt status | <4:0> status, write 1 to clear; <20:16> enables; <0> end of frame is set by the display |
| 080 | data | the fill stipple (repeats every 32 pixels from the fill's longword) |
| 098 | DMA base | PCI address of the DMA buffer |
| 0C0 | RAMDAC setup | <4:1> RS for reads |
| 140/144 | block colour 0/1 | block fill/stipple data, pixel `addr & 7` |
| 160/168/170/178, 164/16C/174/17C | COPY64 source, destination (four pairs; NT's tga.dll uses all four for 256-byte rows) | a destination write copies 64 bytes (any byte alignment); toggle 0 / 1 |
| 1E8 | ICS1562 | ignored (6) |
| 1F0 | RAMDAC data | write with <8> = 0: Bt485 RS <12:9> = <7:0>; read: Bt485 register EPSR<4:1> in <23:16> |
| 1F8, 1FC | command status | <0> busy (queue or engine); reads 0 when idle |

## 4. Drawing (frame buffer writes, by mode<7:0>)

Every operation becomes a run of quadword pixel operations (`g_*` in `tga.v`), each with byte enables
and source data. When the raster op depends on the destination, or the plane mask is not all ones,
the quadword is read first, then
`new = (rop(src, old) & pm) | (old & ~pm)`. Otherwise it is a byte-masked write, which costs 2 cycles a
quadword at the arbiter. A fill of 2048 pixels is 257 quadwords.

Mode bits: <0> not simple, <1> line, <2> transparent, <3> block, <4> Z, <5> fill. Transparent stipple and
fill are 05 and 25 (Linux tgafb; NT's tga.dll draws text in 05); 03 and 23 are accepted as the same.

| Mode | Write at A, data D |
|---|---|
| 00 (and anything not below) simple | the longword, its byte enables, pixel mask bit k for byte k of the longword (NT's one-shot masks 0F/1E/3C/78 then 01/03/07: a 4-pixel group at `x & 3`; was `(A & 31) + k`, which blocked NT's masked writes in 7 of 8 longwords), rop, plane mask |
| 01 / 05 (03) opaque / transparent stipple | 32 pixels from `A & ~3`: pixel i gets FG if D<i>, else BG (opaque) or stays (transparent); pixel mask bit i |
| 0D block stipple | as 03 with block colours, no rop |
| 2D block fill | `D<10:0> + 1` pixels from `(A & ~3) + D<17:16>`, block colours, data register stipple, plane mask, no rop |
| 21 / 25 (23) opaque / transparent fill | as 2D with FG/BG (opaque) or FG where the stipple is set, rop |
| 07 copy | the first write reads 32 bytes from `A & ~3` (its mask ignored). The second writes them at `A2 & ~3` where D<i> and the pixel mask allow, rop, plane mask (the pixel shift is not applied) |
| 1F DMA write copy | reads `D<31:16> + 1` quadwords from `A & ~7` and drops the first (the shifter primer). The rest go to host memory at 098 as longword DMA writes |
| 17 / 37 DMA read copy | `D<31:16> + 1` longwords from host memory at 098 are written from `A & ~3` with rop and plane mask. Edge masks: left1 D<3:0> (first), left2 D<7:4> (second, if 3 or more), right1 D<11:8> (last). right2 (the residue) is not modelled |

With these semantics, SRM's scroll copies its 1028-byte lines exactly (the bench runs SRM's own loop).
Its DMA read writes 4 bytes beyond the line. The next line's copy (or the bottom clear) overwrites them, as on the real card.

## 5. Bt485

The registers follow the RS numbering of `tga_sfbp_485.h` and NetBSD `bt485reg.h`:

| RS | Register |
|---|---|
| 0 | address |
| 1 | palette (RGB counter; the address steps after blue) |
| 2 | pixel mask |
| 3 | read address |
| 4/5/7 | cursor colour write address / data / read address |
| 6/8/9 | CR0 / CR1 / CR2 |
| 10 | status, or CR3 when CR0<7> is set and the address is 1 |
| 11 | cursor RAM |
| 12-15 | cursor X/Y |

The cursor RAM address is `{CR3<1:0>, address}`. It steps on every access: plane 0 is at 0-511 and plane 1 at 512-1023, 8 bytes a row, bit 7 leftmost.
- **Display:** a 64x64 cursor whose top-left is at (X-64, Y-64) in active-video coordinates.
- **Cursor modes (CR2<1:0>):** 1 three-colour, 2 XGA (complement shown as colour 3), 3 X11.
- **DAC width:** CR0<1> = 0 means 6-bit values, expanded by repeating the top bits.
- **32x32 cursor (CR3<2> = 0, NT 4.0's TGA driver):** the cursor RAM address is the 8-bit address register: plane 0 at 0-127, plane 1 at 128-255, 4 bytes a row; shown at (X-32, Y-32).
- **Not modelled:** the overscan colour (0).
- **Status:** reads 0.

## 6. Display

**Mode.** The display mode comes from VHCR/VVCR alone:

| Register | Field | Bits | Units |
|---|---|---|---|
| VHCR | active | <8:0>, plus <29:28> as bits 10:9 | 4 pixels |
| VHCR | front porch | <13:9> | 4 pixels; odd <31> adds 4 |
| VHCR | sync | <20:14> | 4 pixels |
| VHCR | back porch | <27:21> | 4 pixels |
| VVCR | active | <10:0> | lines |
| VVCR | front porch | <15:11> | lines |
| VVCR | sync | <21:16> | lines |
| VVCR | back porch | <27:22> | lines |

The ICS1562 serial bits are ignored. Pixels come at `clk_pix` (65 MHz) with `ce_pix` at
htotal x vtotal x 60 Hz, capped at 65 MHz:
- SRM switch 8 (1344 x 810 total, 1028 x 768 active) runs every clock, at 59.7 Hz.
- Linux's 640x480 runs at 39% of the clocks.
- SRM's default switch 0 (1280x1024, 130 MHz) would run at 36 Hz. That is why `ROM_WORD` picks switch 8.

The MiSTer scaler takes any of these.

**Fetch and line buffer.** Line n starts at VRAM byte VVBR x unit + n x active and is 8 bits a pixel, linear.
- At the start of line n the beam asks for line n+1, and at the start of the last line of the frame it asks for line 0. The request goes through a toggle synchroniser.
- The system-clock side reads the line in bursts of 32 quadwords through `ddr3_arb` `sc_*` into one half of a 2 x 256-quadword line buffer. That buffer is a dual-clock M10K RAM.
- Each half keeps its first pixel's byte offset, because lines need not be aligned.
- Up to 2040 pixels a line are fetched; beyond that the line is black.
- A fetch has a whole line time (20 µs), and the display is the arbiter's first client.

**Pixel pipeline.** Five stages on `ce_pix`:
1. Addresses.
2. Line buffer and cursor RAM.
3. Pixel & pixel mask, and the cursor bits.
4. Palette.
5. RGB.

The RAMs read with `ce_pix` as their enable. Syncs are active high. VVVR<1> blanks the picture.
The end-of-frame interrupt is raised at the first line after the active ones.

**Selector.** `tga_vsel.v` shows the TGA when Display = Graphics (OSD status 4:3 = 0) and `video_on` is set
(VVVR<0> and a mode is set). Otherwise it shows the terminal. It switches only in the vertical blank of the picture being shown.

## 7. DDR3 (`rtl/mister/ddr3_arb.v`)

| DDR3 byte | Client | Notes |
|---|---|---|
| 0x3000_0000 | flash image, 1 MB | `fbrom.v`'s own addresses |
| 0x3010_0000 | TGA VRAM, 2 MB | |
| 0x1FF0_0000 | LAN mailbox, 64 KB | `nb_*`, Main_MiSTer's shared Ethernet mailbox |

The arbiter runs one transaction at a time. Priorities, highest first:
1. **Display fetch** (`sc_*`, bursts of 1-32). It waits behind at most one transaction.
2. **TGA port** (`vr_*`).
   - **Writes:** go into a merge register (same quadword: bytes merged; 15-cycle timeout) and a 16-entry FIFO. They are acknowledged when queued.
   - **Reads (1-16 words):** wait until the queue is empty, so a read sees every earlier write.
3. **Flash.** `fbrom.v` connects its DDRAM_* signals to `fb_*` unchanged. `fb_busy` is low whenever the flash could go, so fbrom can raise its command. The flash alternates with the TGA port.
4. **LAN mailbox** (`nb_*`, one word a request). It goes when nothing else wants the bus, or right after the display fetch once it has waited 1024 cycles.

## 8. Integration (done by the user)

**`rtl/as200_sys.v`:**
- `tga #(.DEVNUM(5'd12)) tga (...)` on `pt_*`.
- OR `tga_claim`, `tga_ack` and `tga_rdata` into `pt_claim`, `pt_ack` and `pt_rdata` (`tga_rdata` is already 0 without its ack).
- Exclude the TGA from the SIO's subtractive decode: `pt_sub = pt_req && pt_cmd == 1 && !scsi_claim && !tga_claim`. The TGA never claims I/O, so this is only for symmetry.
- `tga_inta_n` drives PIRQ1: `.pirq_n({scsi_inta_n, 1'b1, tga_inta_n, 1'b1})`.
- The TGA becomes a third DMA master on the fixed-priority mux. It is lowest priority; the 53C810 and the 8237s stay ahead.
- New ports out of `as200_sys`:
  - `vr_*` and `sc_*`, plus `vr_rdata` and `sc_rdata` (both from the arbiter's `rdata`).
  - `clk_pix` in.
  - The video outputs and `video_on`.

**`DECAlphaStation200.sv`:**
- `ddr3_arb` takes the DDRAM_* signals. `fbrom` connects to its `fb_*` side.
- The TGA's `vr_*` and `sc_*` go to the arbiter.
- `tga_vsel` sits between `vterm` and the VGA outputs, with `.gfx(cfg[4:3] == 2'd0)`.
- `CE_PIXEL` and `VGA_DE_IN` (video_freak) come from the selector.

**`files.qip`:** add `rtl/tga/tga.v`, `tga_bt485.v`, `tga_video.v`, `tga_vsel.v` and `rtl/mister/ddr3_arb.v`.

**SDC:** `clk_sys` and `clk_pix` are already asynchronous groups (vterm crosses them). The TGA's crossings are:
- Toggles through 3 flops.
- Quasi-static mode, colour and cursor registers sampled in the pixel domain.
- Dual-clock RAMs.

## 9. Bench (`make -C verilator tb_tga`)

`tb_tga_top.v` wires `tga`, `ddr3_arb`, `fbrom` and `tga_vsel` the way the top is to wire them.
The C++ side models three things:
- The DDRAM bridge: 15% random busy, 8-20 cycles of read latency, random gaps between beats.
- apecs's PCI target cycles, and DMA with random latency.
- A reference copy of VRAM with the semantics of section 4.

After every group of operations, all 2 MB are compared. The bench covers:
- The PCI header, BAR sizing, enables and claims.
- The ROM word, register read-back and aliases, and the copy toggle.
- SRM's asic_reset and block-stipple probe.
- 40 random fills (all three modes, both forms, raster ops, plane masks, data stipples) and SRM's overlapping clear.
- 60 stipples (SRM's text masks and random ones) and 200 simple writes with raster ops, plane and pixel masks and read-back.
- 60 COPY64 (aligned and byte-misaligned) and 60 copy-mode pairs.
- SRM's DMA scroll loop on 1028-byte lines (aligned and longword-misaligned sources), and DMA read edge masks.
- The Bt485: the command registers, CR3 indirect, 256 palette entries written and read back, cursor RAM, cursor colours and the cursor position.
- A displayed frame: SRM's switch-8 mode, VVBR 1, deep 0x1C000 and the Bt485 cursor. Checked pixel for pixel against VRAM, palette and cursor, and written to `scratch/tga_frame.ppm`.
- The end-of-frame interrupt (set, INTA, clear), and the selector both ways.
- A ROM download and flash reads and writes through the arbiter while a block fill and the display run, plus LAN mailbox writes and reads at the same time.

Result 2026-11-01: **PASS** (seeds 1-4), with 6.6 M cycles and 5 frames.

## 10. Gaps

- **Pixel shift:** applied to COPY64 only (source - shift, the direction inferred from NT's use). Copy mode 07 ignores it, and the copy buffer registers 000-01C are not the engine's buffer.
- **Line modes:** 02/06 are drawn (2026-11-03, from NT 4.0 tga.dll's register stream: width 09C, address 03C, pattern 080, slope 100-13C with the octant in the register number, continue 04C). The Bresenham tie rule (step the minor axis when e > 0) is a guess. 0E and the Z and stencil modes are not drawn.
- **24-plane:** no 24-plane visuals or rotate/visual fields. The ZLXp-E1 has none.
- **TGA cursor:** CCBR/CXYR/VVVR<2> is not displayed. NetBSD's X server uses it.
- **ICS1562:** not decoded, and no pixel clock above 65 MHz. 1280x1024 runs at a lower refresh rate.
- **DMA read residue:** the right2 mask is ignored, and DMA write edge masks are ignored (as on the TURBOchannel parts).
- **Speed:**
  - A destination read-modify-write (raster op or plane mask) costs a DDR3 read per quadword, about 30 cycles.
  - SRM's 2 MB clear writes 65536 x 257 quadwords, about 0.35 s.
  - The arbiter has one transaction in flight.
- **Timing:** no standalone Quartus probe yet. A full-design fit was running at write time. The likely long paths are the engine's next-quadword decision (`cur_be`/`cur_d`, with the 128-bit funnel and the raster op, into `vr_*`) and the fill set-up adders.
- **Class code and revision:** 038000 and 03 are best guesses (no dump of a real card's header).
