//============================================================================
//
//  DEC AlphaStation 200 4/100 for MiSTer: the emu top (from Template_MiSTer).
//  The machine is rtl/as200_sys.v (the 21064, the 21071, COM1); this file is
//  the MiSTer side: hps_io and the OSD (docs/osd-standard.md layout), the
//  100 MHz clock, the settings latch, the SDRAM (main memory), DDR3 and BRAM
//  for the flashbus ROMs (rtl/mister/fbrom.v: boot0.rom = flash, boot1.rom =
//  DROM), the on-screen terminal and the UART.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_DTR} = 0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////
// OSD (docs/osd-standard.md). Status bits:
//   0        Apply and reset
//   2:1      Memory              (0 64MB, 1 32MB, 2 128MB)
//   4:3      Display             (0 Graphics, 1 Serial console)
//   6:5      Aspect ratio
//   9:7      Scale
//   10       Swap Alt/Win keys   (Input: applies at once)
//   11       J1 SROM mini-console
//   12       J2 floppy boot
//   13       J6 flash write      (0 enabled)
//   15:14    TOY year            (0 from the MiSTer RTC, 1 1999)
//   16       Console             (0 SRM, 1 ARC: the TOY CMOS 3Fh at reset)
//   20       Halt button         (T: an action)
//   24       CPU state line      (the terminal prints PC, PAL mode, irq_h, retired count each second)
//   23:21    Network interface   (0 eth0, 1 None, 2 eth1, 3 macvlan, 4 tap0; read by Main, not latched)
// Settings take effect at reset (cfg below); "Changes pending" shows while
// the OSD differs from what is running.

`include "build_id.v"
localparam CONF_STR = {
	"DECAlphaStation200;UART9600:19200:38400:57600:115200;",
	"-;",
	"SC0,IMGHDAVHD,Pri. disk (ID 0);",
	"SC1,IMGHDAVHD,Disk (ID 1);",
	"SC2,ISOCUECHD,CD-ROM (ID 4);",
	"SC3,IMGVFD,Floppy (A:);",
	"F0,ROMBIN,Load ROM;",
	"-;",
	"H1O[2:1],Memory,64MB,32MB;",
	"h1O[2:1],Memory,64MB,32MB,128MB;",
	"O[23:21],Network interface,eth0,None,eth1,macvlan,tap0;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1-,AlphaStation 200 4/100;",
	"P1-,DECchip 21064 (EV4);",
	"P1-;",
	"P1O[16],Console,SRM,ARC;",
	"P1T[20],Halt button;",

	"P2O[4:3],Display,Graphics,Serial console;",
	"P2O[6:5],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[9:7],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",

	"P3O[10],Swap Alt/Win keys,No,Yes;",

	"P5O[11],J1 SROM console,Off,On;",
	"P5O[12],J2 floppy boot,Off,On;",
	"P5O[13],J6 flash write,Enabled,Disabled;",
	"P5O[15:14],TOY year,From RTC,1999;",
	"P5O[24],CPU state line,Off,On;",
	"P5-;",
	"P5SC4,NVR,NVRAM image;",

	"v,0;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [64:0] rtc;
wire  [15:0] sdram_sz;
wire         cfg_pending;
// 128 MB needs the 128 MB SDRAM module (sdram_sz[1:0]: 1 = 32 MB, 2 = 64 MB, 3 = 128 MB)
wire         sdram_128 = sdram_sz[1:0] == 2'd3;

// hps_io block devices: 0 disk ID 0, 1 disk ID 1, 2 CD-ROM ID 4 (the SCSI
// targets), 3 floppy, 4 NVRAM (not yet)
wire  [31:0] sd_lba[5];
wire   [5:0] sd_blk_cnt[5];
wire   [4:0] sd_rd, sd_wr, sd_ack;
wire   [7:0] sd_buff_din[5];
wire  [13:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire         sd_buff_wr;
wire   [4:0] img_mounted;
wire  [63:0] img_size;
wire  [95:0] scsi_lba;
wire  [17:0] scsi_blk_cnt;
wire   [2:0] scsi_rd, scsi_wr;
wire   [7:0] scsi_buff_din;
assign sd_lba[0] = scsi_lba[31:0];   assign sd_lba[1] = scsi_lba[63:32];   assign sd_lba[2] = scsi_lba[95:64];
assign sd_lba[3] = fd_lba;           assign sd_lba[4] = nv_lba;
assign sd_blk_cnt[0] = scsi_blk_cnt[5:0]; assign sd_blk_cnt[1] = scsi_blk_cnt[11:6]; assign sd_blk_cnt[2] = scsi_blk_cnt[17:12];
assign sd_blk_cnt[3] = fd_blk_cnt;   assign sd_blk_cnt[4] = nv_blk_cnt;
assign sd_rd = {nv_rd, fd_rd, scsi_rd};
assign sd_wr = {nv_wr, fd_wr, scsi_wr};
assign sd_buff_din[0] = scsi_buff_din; assign sd_buff_din[1] = scsi_buff_din; assign sd_buff_din[2] = scsi_buff_din;
assign sd_buff_din[3] = fd_buff_din;  assign sd_buff_din[4] = nv_buff_din;
// slot 3: the floppy (the 82077AA's image cache, inside the SIO)
wire  [31:0] fd_lba;
wire   [5:0] fd_blk_cnt;
wire         fd_rd, fd_wr, fd_led;
wire   [7:0] fd_buff_din;
wire         img_readonly;
assign LED_DISK  = {1'b0, fd_led};       // the floppy's activity

// slot 4: the flashbus NVRAM image (rtl/mister/nvsave.v)
wire  [31:0] nv_lba;
wire   [5:0] nv_blk_cnt;
wire         nv_rd, nv_wr;
wire   [7:0] nv_buff_din;
wire  [12:0] nvb_addr;
wire         nvb_we, nv_dirty;
wire   [7:0] nvb_wdata, nvb_rdata;
nvsave #(.CLK_HZ(100000000)) nvsave
(
	.clk(clk_sys), .rst(~pll_locked),
	.img_mounted(img_mounted[4]), .img_size(img_size),
	.sd_lba(nv_lba), .sd_blk_cnt(nv_blk_cnt), .sd_rd(nv_rd), .sd_wr(nv_wr), .sd_ack(sd_ack[4]),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(nv_buff_din), .sd_buff_wr(sd_buff_wr),
	.nvb_addr(nvb_addr), .nvb_we(nvb_we), .nvb_wdata(nvb_wdata), .nvb_rdata(nvb_rdata), .nv_dirty(nv_dirty)
);

// what is mounted in the three SCSI slots, and its size in 512-byte blocks
reg    [2:0] img_present;
reg          cd_change;                  // a pulse after a CD mount, aligned with img_present
always @(posedge clk_sys) cd_change <= img_mounted[2];
reg   [95:0] img_blocks;
always @(posedge clk_sys) begin
	integer k;
	for (k = 0; k < 3; k = k + 1) if (img_mounted[k]) begin
		img_present[k] <= img_size != 64'd0;
		img_blocks[32*k +: 32] <= img_size[40:9];
	end
end

wire         ioctl_download, ioctl_wr, ioctl_wait;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(5)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, sdram_128, cfg_pending}),
	.sdram_sz(sdram_sz),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.RTC(rtc)
);

//////////////////////////////////////////////////////////////////
// Clocks: 100 MHz system (the CPU, the machine, the SDRAM, hps_io), 65 MHz pixels

wire clk_sys, clk_unused, clk_pix, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_unused),
	.outclk_2(clk_pix),
	.locked(pll_locked)
);

//////////////////////////////////////////////////////////////////
// Reset and the settings latch

wire reset_req = RESET | status[0] | buttons[1] | ~pll_locked;
// the machine also waits for the SDRAM and both ROMs (a download resets it)
reg  [1:0] roms_seen;
always @(posedge clk_sys) if (ioctl_download && ioctl_wr) begin
	if (ioctl_index[7:0] == 8'h00) roms_seen[0] <= 1'b1;
	if (ioctl_index[7:0] == 8'h40) roms_seen[1] <= 1'b1;
end
reg  [3:0] rst_cnt = 4'hF;
always @(posedge clk_sys) begin
	if (reset_req || ioctl_download || !sdram_ready || roms_seen != 2'b11) rst_cnt <= 4'hF;
	else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
end
wire m_reset = rst_cnt != 0;

// the settings the machine runs with, taken from the OSD at every reset
reg [127:0] cfg;
always @(posedge clk_sys) if (reset_req) cfg <= status;
// Input settings (10) and the Halt button (20) stay out
assign cfg_pending = {status[9:1], status[16:11]} != {cfg[9:1], cfg[16:11]};

// a saved 128MB with a smaller module falls back to 64MB
wire [1:0] cfg_mem = (cfg[2:1] == 2'd2 && !sdram_128) ? 2'd0 : cfg[2:1];

//////////////////////////////////////////////////////////////////
// The machine

wire       com1_tx_stb;
wire [7:0] com1_tx_byte;
wire       kbd_stb;
wire [7:0] kbd_ascii;
wire [7:0] leds;
wire       srom_txd;
// the 21040's LAN mailbox (DDR3 byte 0x1FF0_0000, through the DDR3 arbiter)
wire        nb_req, nb_we, nb_pmac_ok, nb_ack;
wire [12:0] nb_addr;
wire [63:0] nb_wdata, nb_rdata;
wire [47:0] nb_pmac;
// the TGA's VRAM and display fetch (DDR3 arbiter) and its video
wire        vr_req, vr_we, vr_ack, vr_rvalid, sc_req, sc_ack, sc_rvalid;
wire [17:0] vr_addr, sc_addr;
wire  [4:0] vr_len;
wire  [5:0] sc_len;
wire  [7:0] vr_be;
wire [63:0] vr_wdata, ddr_rdata;
wire        tga_ce, tga_hs, tga_vs, tga_de, tga_hb, tga_vb, tga_on;
wire  [7:0] tga_r, tga_g, tga_b;
// the OSD's Halt button (a trigger bit), stretched to 50 ms on CPU IRQ5
reg [22:0] halt_cnt;
wire       halt_btn = halt_cnt != 0;
always @(posedge clk_sys) begin
	if (status[20]) halt_cnt <= 23'd5000000;
	else if (halt_cnt != 0) halt_cnt <= halt_cnt - 1'd1;
end
wire [15:0] aud_l, aud_r;
wire       aud_tgl;

wire        d_req, d_we, d_ack, d_line;
wire [26:3] d_addr;
wire  [7:0] d_be;
wire [63:0] d_wdata, d_rdata;
wire        f_req, f_we, f_ack;
wire [20:0] f_addr;
wire  [7:0] f_wdata, f_rdata;

wire        dbg_retire, dbg_pal;    // the CPU state line (con_mux)
wire [63:0] dbg_pc;
wire  [5:0] dbg_irqh;
as200_sys machine
(
	.clk(clk_sys),
	.rst(m_reset),
	.cfg_mem(cfg_mem),
	.halt(halt_btn),
	.jumpers({6'b111111, ~cfg[12], ~cfg[11]}),   // bit 0 J1, bit 1 J2: 1 = normal (OSD On = jumper set)
	.leds(leds),
	.nvb_addr(nvb_addr), .nvb_we(nvb_we), .nvb_wdata(nvb_wdata), .nvb_rdata(nvb_rdata), .nv_dirty(nv_dirty),

	.d_req(d_req), .d_we(d_we), .d_line(d_line), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata),
	.d_ack(d_ack), .d_rdata(d_rdata),
	.f_req(f_req), .f_we(f_we), .f_addr(f_addr), .f_wdata(f_wdata),
	.f_ack(f_ack), .f_rdata(f_rdata),
	.flash_wp(cfg[13]),                    // OSD J6 flash write: Disabled = no Vpp

	.enet_mac(nb_pmac_ok ? nb_pmac : 48'h08002B_A50200),   // Main's PMAC, else a fixed DEC address
	.enet_link_up(1'b1),
	.nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata), .nb_ack(nb_ack), .nb_rdata(nb_rdata),
	.nb_pmac(nb_pmac), .nb_pmac_ok(nb_pmac_ok), .nb_link(),

	.vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_len(vr_len), .vr_be(vr_be), .vr_wdata(vr_wdata),
	.vr_ack(vr_ack), .vr_rvalid(vr_rvalid), .vr_rdata(ddr_rdata),
	.sc_req(sc_req), .sc_addr(sc_addr), .sc_len(sc_len), .sc_ack(sc_ack), .sc_rvalid(sc_rvalid), .sc_rdata(ddr_rdata),
	.clk_pix(clk_pix), .tga_ce(tga_ce), .tga_hs(tga_hs), .tga_vs(tga_vs), .tga_de(tga_de), .tga_hb(tga_hb), .tga_vb(tga_vb),
	.tga_r(tga_r), .tga_g(tga_g), .tga_b(tga_b), .tga_on(tga_on),

	.srom_txd(srom_txd),
	.srom_rxd(1'b1),

	.com1_txd(UART_TXD),
	.com1_rxd(UART_RXD),
	.com1_tx_stb(com1_tx_stb),
	.com1_tx_byte(com1_tx_byte),
	.com1_kbd_stb(kbd_stb),
	.com1_kbd_byte(kbd_ascii),
	.com2_txd(),
	.com2_rxd(1'b1),

	.img_present(img_present),
	.img_blocks(img_blocks),
	.sd_lba(scsi_lba),
	.sd_blk_cnt(scsi_blk_cnt),
	.sd_rd(scsi_rd),
	.sd_wr(scsi_wr),
	.sd_ack(sd_ack[2:0]),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(scsi_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.cd_change(cd_change),
	.fd_mounted(img_mounted[3]), .fd_readonly(img_readonly), .fd_size(img_size),
	.fd_lba(fd_lba), .fd_blk_cnt(fd_blk_cnt), .fd_rd(fd_rd), .fd_wr(fd_wr), .fd_ack(sd_ack[3]),
	.fd_buff_din(fd_buff_din), .fd_led(fd_led),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.rtc(rtc),
	.year_ovr_en(cfg[15:14] == 2'd1),      // OSD TOY year: 1999
	.year_ovr(7'd99),
	.console_arc(cfg[16]),
	.speaker(),
	.aud_l(aud_l), .aud_r(aud_r), .aud_tgl(aud_tgl),

	.dbg_retire(dbg_retire), .dbg_pc(dbg_pc), .dbg_insn(), .dbg_rwr(), .dbg_rnum(), .dbg_rval(),
	.dbg_mwr(), .dbg_maddr(), .dbg_mval(), .dbg_msize(), .dbg_pal(dbg_pal), .dbg_irqh(dbg_irqh)
);

// audio into the audio clock (rtl/audio/audio_cdc.v)
audio_cdc audio_cdc(.clk_audio(CLK_AUDIO), .in_l(aud_l), .in_r(aud_r), .in_tgl(aud_tgl), .out_l(AUDIO_L), .out_r(AUDIO_R));

// main memory: the SDRAM module
wire        sdram_ready;
wire [15:0] sd_dq_out;
wire        sd_dq_oe;
assign SDRAM_DQ = sd_dq_oe ? sd_dq_out : 16'hZZZZ;

sdram_ctl #(.CLK_MHZ(100)) sdram
(
	.clk(clk_sys), .init(~pll_locked), .ready(sdram_ready),
	.req(d_req), .we(d_we), .line(d_line), .addr(d_addr), .be(d_be), .wdata(d_wdata), .ack(d_ack), .rdata(d_rdata),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_CKE(SDRAM_CKE), .dq_out(sd_dq_out), .dq_oe(sd_dq_oe), .dq_in(SDRAM_DQ)
);

// SDRAM_CLK: the system clock inverted, from a DDR output register (as the
// user's other cores and Sorgelig's sdram.sv do)
altddio_out #(
	.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
	.lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
) sdramclk_ddr (
	.datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sys), .dataout(SDRAM_CLK),
	.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
);

// the flashbus ROMs: DROM in BRAM, flash in DDR3
assign DDRAM_CLK = clk_sys;
fbrom fbrom
(
	.clk(clk_sys), .rst(~pll_locked),
	.f_req(f_req), .f_we(f_we), .f_addr(f_addr), .f_wdata(f_wdata), .f_ack(f_ack), .f_rdata(f_rdata),
	.dl_wr(ioctl_download && ioctl_wr), .dl_index(ioctl_index[7:0]), .dl_addr(ioctl_addr[24:0]),
	.dl_data(ioctl_dout), .dl_wait(ioctl_wait),
	.DDRAM_BUSY(fb_busy), .DDRAM_BURSTCNT(fb_burstcnt), .DDRAM_ADDR(fb_addr),
	.DDRAM_DOUT(fb_dout), .DDRAM_DOUT_READY(fb_dout_ready), .DDRAM_RD(fb_rd),
	.DDRAM_DIN(fb_din), .DDRAM_BE(fb_be), .DDRAM_WE(fb_we)
);

// DDR3: the TGA's display fetch, its VRAM, the flash, the LAN mailbox (rtl/mister/ddr3_arb.v)
wire        fb_busy, fb_dout_ready, fb_rd, fb_we;
wire  [7:0] fb_burstcnt, fb_be;
wire [28:0] fb_addr;
wire [63:0] fb_dout, fb_din;
ddr3_arb ddr3_arb
(
	.clk(clk_sys), .rst(~pll_locked),
	.sc_req(sc_req), .sc_addr(sc_addr), .sc_len(sc_len), .sc_ack(sc_ack), .sc_rvalid(sc_rvalid),
	.vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_len(vr_len), .vr_be(vr_be), .vr_wdata(vr_wdata),
	.vr_ack(vr_ack), .vr_rvalid(vr_rvalid), .vr_wq_empty(), .rdata(ddr_rdata),
	.fb_busy(fb_busy), .fb_burstcnt(fb_burstcnt), .fb_addr(fb_addr), .fb_dout(fb_dout), .fb_dout_ready(fb_dout_ready),
	.fb_rd(fb_rd), .fb_din(fb_din), .fb_be(fb_be), .fb_we(fb_we),
	.nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata), .nb_ack(nb_ack), .nb_rdata(nb_rdata),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

// The MiSTer keyboard types into COM1 until the 8242 and a graphics console exist.
ps2_ascii ps2_ascii
(
	.clk(clk_sys),
	.rst(m_reset),
	.ps2_key(ps2_key),
	.strobe(kbd_stb),
	.ascii(kbd_ascii)
);

// the terminal shows the SROM serial port (the DROM's console), COM1 and the LEDs
wire       con_stb;
wire [7:0] con_byte;
con_mux #(.CLK_HZ(100000000)) con_mux
(
	.clk(clk_sys), .rst(m_reset),
	.srom_txd(srom_txd), .com1_stb(com1_tx_stb), .com1_byte(com1_tx_byte), .leds(leds),
	.st_en(status[24]), .st_retire(dbg_retire), .st_pc(dbg_pc), .st_pal(dbg_pal), .st_irq(dbg_irqh),
	.out_stb(con_stb), .out_byte(con_byte)
);

//////////////////////////////////////////////////////////////////
// Video: the serial console terminal (rtl/mister/vterm.v). The TGA
// (ZLXp-E1) takes over when it exists and Display = Graphics.

wire       vt_hs, vt_vs, vt_de, vt_hb, vt_vb;
wire [7:0] vt_r, vt_g, vt_b;

vterm vterm
(
	.clk(clk_sys),
	.rst(m_reset),
	.in_stb(con_stb),
	.in_byte(con_byte),

	.clk_pix(clk_pix),
	.hs(vt_hs), .vs(vt_vs), .de(vt_de), .hblank(vt_hb), .vblank(vt_vb),
	.r(vt_r), .g(vt_g), .b(vt_b)
);

wire [1:0] ar = cfg[6:5];
// OSD order puts V-Integer first; video_freak: 0 Normal, 1 V-Integer
wire [2:0] scale = cfg[9:7] == 3'd0 ? 3'd1 : cfg[9:7] == 3'd1 ? 3'd0 : cfg[9:7];

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vid_de),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0), .CROP_OFF(5'd0),
	.SCALE(scale)
);

assign CLK_VIDEO = clk_pix;
// the picture: the TGA once it has video on (OSD Display: Graphics), else the terminal
wire       vid_ce, vid_hs, vid_vs, vid_de, vid_hb, vid_vb;
wire [7:0] vid_r, vid_g, vid_b;
tga_vsel tga_vsel
(
	.clk_pix(clk_pix), .gfx(cfg[4:3] == 2'd0), .tga_on(tga_on),
	.t_ce(tga_ce), .t_hs(tga_hs), .t_vs(tga_vs), .t_de(tga_de), .t_hb(tga_hb), .t_vb(tga_vb),
	.t_r(tga_r), .t_g(tga_g), .t_b(tga_b),
	.v_hs(vt_hs), .v_vs(vt_vs), .v_de(vt_de), .v_hb(vt_hb), .v_vb(vt_vb), .v_r(vt_r), .v_g(vt_g), .v_b(vt_b),
	.ce(vid_ce), .hs(vid_hs), .vs(vid_vs), .de(vid_de), .hblank(vid_hb), .vblank(vid_vb),
	.r(vid_r), .g(vid_g), .b(vid_b), .showing_tga()
);
assign CE_PIXEL  = vid_ce;
assign VGA_HS = vid_hs;
assign VGA_VS = vid_vs;
assign VGA_R  = vid_r;
assign VGA_G  = vid_g;
assign VGA_B  = vid_b;

//////////////////////////////////////////////////////////////////
// LED: COM1 activity

reg [22:0] act_cnt;
always @(posedge clk_sys) begin
	if (con_stb | kbd_stb) act_cnt <= 23'h7FFFFF;
	else if (act_cnt != 0) act_cnt <= act_cnt - 1'd1;
end
assign LED_USER = act_cnt != 0;

endmodule
