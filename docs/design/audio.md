# Audio: the sound card, the speaker, the mix

The AlphaStation 200 has a dedicated sound card on a private ISA connector (EK-PCDSA-TI p. 1-20,
tables 3-6, 11-3 to 11-5): a Microsoft Windows Sound System interface with an **Analog Devices
AD1848** codec, I/O base 530h (jumpers SW1/SW2: 530h, 604h, E80h, F40h), and an FM synthesiser
the manual calls a "Yamaha YMF562" (most likely a YMF262 OPL3) at fixed 388h-38Bh. The card
also mixes the CD-ROM's analogue audio and the motherboard speaker.

`rtl/audio/` (plain Verilog-2001, except the OPL3 core, used as is):

| File | Contents |
|---|---|
| `as200_audio.v` | the wrapper on the 82378's xio bus (sio.md 1): the card, the FM chip, the mix |
| `wss_ad1848.v` | the WSS command/ID registers and the AD1848 (from the RS/6000 core's `IBMRS6K7248_cs4232.sv`, reduced) |
| `opl_isa.v` | the FM chip's ports in front of the OPL3, its bank rule for NEW = 0, the samples into the system clock and to 48 kHz |
| `opl3_fpga/` | Greg Taylor's opl3_fpga (LGPL-3, SystemVerilog), the YMF262, as in ao486_MiSTer `628ddbc` (`README.md` there); unchanged. `jtopl/` (the OPL2 used until `_20261112c`) was removed 2026-11-13 |
| `audio_mix.v` | WSS + FM + CD + speaker, 48 kHz, saturated |
| `audio_cdc.v` | the mix into CLK_AUDIO for `sys/` (instantiated in the MiSTer top) |
| `verilator/tb/tb_audio.cpp`, `tb_audio_top.v` | unit bench with the real SIO, `make -C verilator tb_audio` (64 checks) |

## 1. What the firmware and the OSes expect

- **SRM V7.0** knows the card as **`PCXBJ`**. Its default ISA table (the `isacfg` script in the
  SRM image) has `isacfg -slot 2 -dev 0 -mk -handle PCXBJ -irq0 9 -iobase0 530 -iobase1 388
  -etyp 1 -enadev 1 -dmachan0 0 -dmachan1 1`, and its sound init insists on it: "YOU MUST CHANGE
  ISA TABLE TO USE IRQ 9 / DMA 0 AND 1 / ADDRESS 0X530", "Sound device failed to reset", "Failed
  to find sound device". So: **530h, 388h, IRQ 9, DMA 0 and 1.**
- The card's IRQ and DMA are **software-selected** through the WSS command register (BASE+0), so
  the hardware has no fixed IRQ/DMA: the driver writes them. Out of reset the command register is
  0 (no IRQ, no DMA).
- Linux's `ad1848.c` finds the card by the WSS version at BASE+3 (04h), waits for INIT to clear,
  then probes the codec's indirect registers (section 2).
- **NT 4.0's `sndsys.sys`** (on the CD as `ALPHA\SNDSYS.SY_`; disassembled in `scratch/ntsnd/`) checks,
  in order: R0 without INIT; I12 reads 09h, 0Ah or 8Ah and does not take a write; the version at
  BASE+3. Then the **interrupt scan**: for each of IRQ 7, 9, 10, 11 it writes the command register
  with IRQSENS and that IRQSEL and takes the line as free only if BASE+3 bit 6 reads 1 (an idle ISA
  line is high; manual: "the status register returns the state of the selected interrupt channel").
  With no free line it gives up with configuration error 10. Bit 7 clear allows every DMA and IRQ.
  It uses one DMA channel, DMASEL 1-3, with I9's SDC for capture. Last comes a **live test** of
  both directions: start, wait 75 ms, stop, then an interrupt must have come and HalReadDmaCounter
  must read between 1 and the buffer size less 5 (errors 2 and 3). All of this passes on the board
  since `0640b37`; at NT's default IRQ 11 the dialog reports the line used and moves to 7.
- **Windows 2000** uses a WDM driver (`wdma_wss.inf`, `*PNPB007`, default 530h, 388h, IRQ 10, DMA 1
  and 0) that runs none of those checks.
- FM: software probes the OPL at 388h by its timers (AdLib detection) and tells an OPL3 from an
  OPL2 by the status bits 2:1 (0 on an OPL3, 1 on an OPL2).

## 2. The WSS card (`wss_ad1848.v`)

Ports (BASE = 530h, a parameter):

| Port | R/W | Register |
|---|---|---|
| BASE+0 | W | command: bit 6 IRQSENS, 5:3 IRQSEL (1 IRQ7, 2 IRQ9, 3 IRQ10, 4 IRQ11, else none), 2:0 DMASEL |
| BASE+0..3 | R | ID and status: bit 7 ChannelAvail (0: all channels free), 6 IrqSense (the codec's INT and IEN; with IRQSENS written, 1 for IRQSEL 1-4, an idle line), 5:0 version 04h |
| BASE+4 | R/W | R0 index: 7 INIT (read only), 6 MCE, 5 TRD, 3:0 the indirect register |
| BASE+5 | R/W | R1 indirect data |
| BASE+6 | R/W | R2 status: 0 INT, 1 PRDY, 4 SOUR, 5 CRDY. Any write clears INT; a read clears PUR/COR |
| BASE+7 | R/W | R3 PIO data (PPIO playback in, CPIO capture out) |

DMASEL, the AS200's own table (11-5): 1 play 0; 2 play 1; 3 play 3; 4 capture 0; 5 play 0 and
capture 0; 6 play 1 and capture 1; 7 play 3 and capture 1. I9's SDC moves capture onto the
playback channel; with SDC and both directions enabled, playback wins.

Indirect registers (AD1848: I0-I15; the index's bit 4 is ignored, so I16-I31 alias I0-I15):

| | Name | Reset | Notes |
|---|---|---|---|
| I0, I1 | ADC input control | 00 | bit 4 reads 0 (Linux's probe writes AAh/45h and 45h/AAh) |
| I2-I5 | AUX1/AUX2 input | 88 | stored |
| I6, I7 | DAC control | 80 | bit 7 mute, 5:0 attenuation, 1.5 dB steps (a shift for each 6 dB and a multiply for the rest) |
| I8 | clock and data format | 00 | **written only while MCE is set**. 6:5 format (00 8-bit unsigned, 01 mu-law, 10 16-bit little-endian, 11 A-law), 4 stereo, 3:1 CFS, 0 CSS. Playback and capture share it |
| I9 | interface configuration | 08 | 0 PEN, 1 CEN, 2 SDC, 3 ACAL, 6 PPIO, 7 CPIO; outside MCE only PEN/CEN change |
| I10 | pin control | 00 | 1 IEN, 7:6 XCTL (stored) |
| I11 | test and initialisation | - | read only: 7 COR, 6 PUR, 5 ACI, 4 DRS (a DMA request is up) |
| I12 | miscellaneous | 0A | read only: the ID, revision C. No MODE2: Linux's 40h write leaves bits 7:6 0, so it says AD1848 |
| I13 | digital mix | 00 | stored (no loopback: capture is silence) |
| I14, I15 | base count, upper, lower | 00 | frames less 1. **A write of I14 loads the counter** from I14:I15 (drivers write I15 first) |

- **INIT** reads 1 (R0 = 80h, writes ignored) for 20 us after reset; R0 then reads 40h (MCE set,
  as the chip comes out of reset).
- **Autocalibration**: clearing MCE while ACAL is set raises ACI (I11 bit 5) for 200 us. Linux
  and NT poll for it to go away.
- **Sample clock**: the AD1848's crystals (24.576 MHz with CSS = 0, 16.9344 MHz with CSS = 1) by a
  phase accumulator on the system clock, then CFS's divisor (3072, 1536, 896, 768, 448, 384, 512,
  2560): 8, 16, 27.43, 32, (54.86, 64: reserved on the AD1848), 48, 9.6 kHz and 5.5125, 11.025,
  18.9, 22.05, 37.8, 44.1, 33.075, 6.615 kHz, exact on average. The clock stops while MCE is set
  or neither PEN nor CEN is.
- **Playback** (PEN, not PPIO): the playback DREQ is up while the 16-byte FIFO has room (12 bytes
  or less, computed from the next state so it drops the clock after the last transfer the FIFO
  takes). Each frame period takes 1, 2 or 4 bytes; with too few the output holds and PUR is set.
  The frame goes through three registered stages (FIFO read, decode, attenuation) to `pcm_l/r`.
- **The counter** counts taken playback frames (captured frames when playback is off). Past 0 it
  sets INT (R2 bit 0) and reloads. IRQ = INT and IEN, routed by IRQSEL, edge-friendly for the
  8259 (it stays up until R2 is written). TRD drops the DMA requests while INT is set.
- **Capture** (CEN, not CPIO): each frame period offers a frame of silence in I8's format (80h,
  FFh mu-law, D5h A-law, 00h 16-bit) on the capture channel; overrun sets COR. CPIO reads R3.
- **PIO**: PPIO writes to R3 go into the FIFO (PRDY while it has room); CPIO reads take silence.

## 3. The FM chip (`opl_isa.v`)

388h index / status, 389h data, 38Ah/38Bh the second register pair. **An OPL3 since 2026-11-12**
(user: "I think I'm used to OPL3"): Greg Taylor's opl3_fpga, the core ao486_MiSTer uses, in
`rtl/audio/opl3_fpga/`, unchanged and in SystemVerilog (an exception to the plain-Verilog rule:
someone else's chip, better kept identical to its source). Until `_20261112c` an OPL2 (jtopl2)
stood here with bank 1 dropped, and NT 4.0 played MIDI in its AdLib mode.

- The chip runs on CLK_AUDIO (24.576 MHz), a sample every 494 clocks (49,749 Hz). Writes cross
  from the system clock through the core's 64-entry asynchronous FIFO, which empties at one byte
  per audio clock (40.7 ns): there is no pacing as with jtopl (whose 23 us per data write could
  overflow its queue on a burst of more than 32 register writes and lose key-offs; a hung note
  was heard once on `_20261112c`, cause not confirmed). `tb_audio` writes 400 bytes at one per
  3.5 system clocks and the last ones arrive; at one per 2.5 clocks the FIFO overflows (the
  bench's bus; the CPU's I/O cycles through the 21071 were not measured).
- The status (bits 2:1 = 0, an OPL3) reads at 388h; 389h-38Bh read FFh.
- **NEW = 0**: a YMF262 not yet switched to its new mode (bank 1 register 05h bit 0) is an OPL2 at
  either pair, so an index written at 38Ah selects bank 0 (05h excepted). opl3_fpga takes 38Ah
  as bank 1 always; `opl_isa` keeps NEW and chooses the bank. NT 4.0's synthesizer driver tells
  the chips apart so: timer 1 started through 38Ah/38Bh must set its flag, and must not once NEW
  is set. Without the rule (`_20261112d`) NT stayed in AdLib mode; `tb_audio` checks both halves.
- The two channels are held with a toggle in the audio clock, taken into the system clock and
  interpolated to 48 kHz (section 4).

On the board: `_20261112e`, canyon.mid in NT 4.0's Media Player recorded off HDMI: other levels
and spectrum than `d` (AdLib mode on the same chip), silence after the end, and both channels
equal (the piece's pans or the driver: not looked into).

## 4. The mix (`audio_mix.v`)

At 48 kHz (a phase accumulator on the system clock) the held values of the four sources are
summed into 18 bits and saturated to signed 16-bit:

- WSS: `pcm_l/r`, held between the codec's frames;
- FM: stereo, a line between the chip's samples (below);
- CD: `cd_audio_l/r`, signed 16-bit, held from each `cd_audio_stb` (44.1 kHz from the SCSI CD-ROM);
- the speaker (sio82378 `spk`: counter 2 gated by port 61h bits 0-1): the clocks it was high in
  the period, scaled to 0..8192 (a quarter of full scale). The averaging is a box filter: a 1 kHz
  beep comes out as a clean square without the 100 MHz edges aliasing.

All sources are at unity gain. `mute[3:0]` (0 WSS, 1 FM, 2 CD, 3 speaker) silences one: it is
there for an OSD page (P4 Audio). The WSS and the CD are resampled by zero-order hold (as on many
MiSTer cores). The FM is not (2026-11-12): held 49,716 Hz samples taken at 48 kHz put an image
1716 Hz either side of every partial, 20 dB below it, which a MIDI file played by NT 4.0 showed
plainly (a 4688 Hz partial with 2972 and 6404 Hz beside it). `opl_isa` now draws a line between
the chip's last two samples (one sample of delay, a phase counter restarted by the chip's sample strobe,
one 17 x 11 multiplier); `tb_audio` checks that the output moves in small steps, and its
`FM_DUMP=<file>` writes a tone at 48 kHz (no spur above -67 dB). On the board (`_20261112c`,
canyon.mid in NT 4.0's Media Player, 60 s recorded off HDMI) the images fell from -20 dB to the
level of the music's own partials there (-31 dB median); the notes are the same as before
(envelope correlation 0.98).

The output changes only at the 48 kHz period, with `aud_tgl` toggling; `audio_cdc.v` in the
MiSTer top synchronises the toggle into CLK_AUDIO (24.576 MHz) and takes the pair when it
changes, long stable by then. sys/ wants AUDIO_S = 1 (signed). The sys/ SDC already treats the
audio PLL as exclusive with the core's clocks.

## 5. Integration

In `rtl/as200_sys.v`:

```verilog
wire [15:0] xio_addr, xio_dack_data, xio_dev_data, xio_irq;
wire        xio_rd, xio_wr, xio_claim, xio_dack, xio_tc;
wire  [7:0] xio_wdata, xio_rdata, xio_dreq;
wire  [2:0] xio_dack_ch, xio_dma_ch;

// sio82378: replace the tied-off xio ports
    .xio_addr(xio_addr), .xio_rd(xio_rd), .xio_wr(xio_wr), .xio_wdata(xio_wdata),
    .xio_claim(xio_claim), .xio_rdata(xio_rdata), .xio_irq(xio_irq), .xio_dreq(xio_dreq),
    .xio_dack(xio_dack), .xio_dack_ch(xio_dack_ch), .xio_dack_data(xio_dack_data),
    .xio_dev_data(xio_dev_data), .xio_dma_ch(xio_dma_ch), .xio_tc(xio_tc),

as200_audio #(.CLK_HZ(100000000)) audio (
    .clk(clk), .rst(rst),
    .xio_addr(xio_addr), .xio_rd(xio_rd), .xio_wr(xio_wr), .xio_wdata(xio_wdata),
    .xio_claim(xio_claim), .xio_rdata(xio_rdata), .xio_irq(xio_irq), .xio_dreq(xio_dreq),
    .xio_dack(xio_dack), .xio_dack_ch(xio_dack_ch), .xio_dack_data(xio_dack_data),
    .xio_dev_data(xio_dev_data), .xio_dma_ch(xio_dma_ch), .xio_tc(xio_tc),
    .speaker(speaker), .cd_audio_l(cd_audio_l), .cd_audio_r(cd_audio_r), .cd_audio_stb(cd_audio_stb),
    .mute(4'd0), .aud_l(aud_l), .aud_r(aud_r), .aud_tgl(aud_tgl)
);
```

with `aud_l[15:0]`, `aud_r[15:0]`, `aud_tgl` new outputs of `as200_sys` (and `speaker` no longer
needed outside). In `DECAlphaStation200.sv`:

```verilog
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;
audio_cdc audio_cdc (.clk_audio(CLK_AUDIO), .in_l(aud_l), .in_r(aud_r), .in_tgl(aud_tgl),
                     .out_l(AUDIO_L), .out_r(AUDIO_R));
```

`files.qip`: `rtl/audio/opl3_fpga/opl3.qip` (QIP_FILE), `rtl/audio/opl3_fpga/synchronizer.sv` and `rtl/audio/{wss_ad1848,opl_isa,audio_mix,
audio_cdc,as200_audio}.v`.

## 6. Open

- The OPL3 on the board by ear (user), and whether NT pans anything (canyon.mid is equal on both
  channels).
- The FM's level against the WSS and the CD: the core's 16-bit output goes into the mix as it is.
- Capture is silence (the MiSTer has no audio input). I13's digital loopback is not mixed.
- The CD-ROM's analogue path on the real card goes through the AD1848's AUX inputs (I2-I5 gain
  and mute); here the CD goes straight to the mix at unity.
- Resampling of the WSS and the CD is zero-order hold (the FM is interpolated).
