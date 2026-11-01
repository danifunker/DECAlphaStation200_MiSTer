//============================================================================
//
//  DEC AlphaStation 200 4/166 for MiSTer: the emu top (from Template_MiSTer).
//  The machine itself is rtl/as200.v; this file is the MiSTer side: hps_io
//  and the OSD (docs/osd-standard.md layout), clocks, the settings latch,
//  video and the UART.
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
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
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
//   20       Halt button         (T: an action)
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
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1-,AlphaStation 200 4/166;",
	"P1-,DECchip 21064 (EV4);",
	"P1-;",
	"P1T[20],Halt button;",

	"P2O[4:3],Display,Graphics,Serial console;",
	"P2O[6:5],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[9:7],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",

	"P3O[10],Swap Alt/Win keys,No,Yes;",

	"P5O[11],J1 SROM console,Off,On;",
	"P5O[12],J2 floppy boot,Off,On;",
	"P5O[13],J6 flash write,Enabled,Disabled;",
	"P5O[15:14],TOY year,From RTC,1999;",
	"P5-;",
	"P5SC4,NVR,NVRAM image;",

	"v,0;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [15:0] sdram_sz;
wire         cfg_pending;
// 128 MB needs the 128 MB SDRAM module (sdram_sz[1:0]: 1 = 32 MB, 2 = 64 MB, 3 = 128 MB)
wire         sdram_128 = sdram_sz[1:0] == 2'd3;

wire  [31:0] sd_lba[5];
wire   [4:0] sd_rd = 0;
wire   [4:0] sd_wr = 0;
wire   [7:0] sd_buff_din[5];
assign sd_lba      = '{default: 32'd0};
assign sd_buff_din = '{default: 8'd0};

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
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_buff_din(sd_buff_din),

	.ps2_key(ps2_key)
);

//////////////////////////////////////////////////////////////////
// Clocks: 50 MHz system, 50 MHz shifted (the SDRAM's, later), 65 MHz pixels

wire clk_sys, clk_sdram, clk_pix, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_pix),
	.locked(pll_locked)
);

//////////////////////////////////////////////////////////////////
// Reset and the settings latch

wire reset_req = RESET | status[0] | buttons[1] | ~pll_locked;
reg  [3:0] rst_cnt = 4'hF;
always @(posedge clk_sys) begin
	if (reset_req) rst_cnt <= 4'hF;
	else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
end
wire m_reset = rst_cnt != 0;

// the settings the machine runs with, taken from the OSD at every reset
reg [127:0] cfg;
always @(posedge clk_sys) if (reset_req) cfg <= status;
// Input settings (10) and the Halt button (20) stay out
assign cfg_pending = {status[9:1], status[15:11]} != {cfg[9:1], cfg[15:11]};

// a saved 128MB with a smaller module falls back to 64MB
wire [1:0] cfg_mem = (cfg[2:1] == 2'd2 && !sdram_128) ? 2'd0 : cfg[2:1];

//////////////////////////////////////////////////////////////////
// The machine

wire       com1_tx_stb;
wire [7:0] com1_tx_byte;
wire       kbd_stb;
wire [7:0] kbd_ascii;
wire       serial_console = cfg[4:3] == 2'd1;

as200 machine
(
	.clk(clk_sys),
	.rst(m_reset),
	.cfg_mem(cfg_mem),

	.com1_txd(UART_TXD),
	.com1_rxd(UART_RXD),
	.com1_rts_n(),
	.com1_dtr_n(),
	.com1_cts_n(1'b0),
	.com1_dsr_n(1'b0),
	.com1_dcd_n(1'b0),
	.com1_tx_stb(com1_tx_stb),
	.com1_tx_byte(com1_tx_byte),
	.com1_kbd_stb(kbd_stb),
	.com1_kbd_byte(kbd_ascii)
);

// The MiSTer keyboard types into COM1. Until the 8242 and a graphics console
// exist this holds for both Display settings; later only for Serial console.
ps2_ascii ps2_ascii
(
	.clk(clk_sys),
	.rst(m_reset),
	.ps2_key(ps2_key),
	.strobe(kbd_stb),
	.ascii(kbd_ascii)
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
	.in_stb(com1_tx_stb),
	.in_byte(com1_tx_byte),

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
	.VGA_DE_IN(vt_de),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0), .CROP_OFF(5'd0),
	.SCALE(scale)
);

assign CLK_VIDEO = clk_pix;
assign CE_PIXEL  = 1'b1;
assign VGA_HS = vt_hs;
assign VGA_VS = vt_vs;
assign VGA_R  = vt_r;
assign VGA_G  = vt_g;
assign VGA_B  = vt_b;

//////////////////////////////////////////////////////////////////
// LED: COM1 activity

reg [22:0] act_cnt;
always @(posedge clk_sys) begin
	if (com1_tx_stb | kbd_stb) act_cnt <= 23'h7FFFFF;
	else if (act_cnt != 0) act_cnt <= act_cnt - 1'd1;
end
assign LED_USER = act_cnt != 0;

endmodule
