// Bench top for the TGA (verilator/tb/tb_tga.cpp): rtl/tga/tga.v and the
// flashbus ROM (rtl/mister/fbrom.v) sharing DDR3 through
// rtl/mister/ddr3_arb.v, wired as the MiSTer top is to wire them; the bench
// models the DDRAM bridge, the PCI host side (apecs's pt_* and dm_*) and
// watches the video.
module tb_tga_top (
    input  wire        clk,
    input  wire        rst,
    input  wire        clk_pix,

    input  wire        pt_req,
    input  wire  [1:0] pt_cmd,
    input  wire  [4:0] pt_dev,
    input  wire [31:0] pt_addr,
    input  wire  [3:0] pt_be,
    input  wire        pt_we,
    input  wire [31:0] pt_wdata,
    output wire        pt_claim,
    output wire        pt_ack,
    output wire [31:0] pt_rdata,

    output wire        dm_req,
    output wire        dm_we,
    output wire [31:0] dm_addr,
    output wire  [3:0] dm_be,
    output wire [31:0] dm_wdata,
    input  wire        dm_ack,
    input  wire [31:0] dm_rdata,
    output wire        inta_n,

    input  wire        f_req,
    input  wire        f_we,
    input  wire [20:0] f_addr,
    input  wire  [7:0] f_wdata,
    output wire        f_ack,
    output wire  [7:0] f_rdata,
    input  wire        dl_wr,
    input  wire  [7:0] dl_index,
    input  wire [24:0] dl_addr,
    input  wire  [7:0] dl_data,
    output wire        dl_wait,

    input  wire        nb_req,
    input  wire        nb_we,
    input  wire [12:0] nb_addr,
    input  wire [63:0] nb_wdata,
    output wire        nb_ack,
    output wire [63:0] nb_rdata,

    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output wire        DDRAM_RD,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output wire        DDRAM_WE,

    input  wire        gfx,
    output wire        ce_pix,
    output wire        hs,
    output wire        vs,
    output wire        de,
    output wire        hblank,
    output wire        vblank,
    output wire  [7:0] r,
    output wire  [7:0] g,
    output wire  [7:0] b,
    output wire        video_on,
    output wire        showing_tga
);
    wire        vr_req, vr_we, vr_ack, vr_rvalid, vr_wq_empty;
    wire [17:0] vr_addr;
    wire  [4:0] vr_len;
    wire  [7:0] vr_be;
    wire [63:0] vr_wdata, a_rdata;
    wire        sc_req, sc_ack, sc_rvalid;
    wire [17:0] sc_addr;
    wire  [5:0] sc_len;
    wire        t_ce, t_hs, t_vs, t_de, t_hb, t_vb;
    wire  [7:0] t_r, t_g, t_b;

    tga tga (
        .stall(1'b0),
        .clk(clk), .rst(rst),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_claim(pt_claim), .pt_ack(pt_ack), .pt_rdata(pt_rdata),
        .dm_req(dm_req), .dm_we(dm_we), .dm_addr(dm_addr), .dm_be(dm_be), .dm_wdata(dm_wdata),
        .dm_ack(dm_ack), .dm_rdata(dm_rdata), .inta_n(inta_n),
        .vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_len(vr_len), .vr_be(vr_be),
        .vr_wdata(vr_wdata), .vr_ack(vr_ack), .vr_rvalid(vr_rvalid), .vr_rdata(a_rdata),
        .sc_req(sc_req), .sc_addr(sc_addr), .sc_len(sc_len), .sc_ack(sc_ack), .sc_rvalid(sc_rvalid),
        .sc_rdata(a_rdata),
        .clk_pix(clk_pix), .ce_pix(t_ce), .hs(t_hs), .vs(t_vs), .de(t_de), .hblank(t_hb), .vblank(t_vb),
        .r(t_r), .g(t_g), .b(t_b), .video_on(video_on)
    );

    wire        fb_busy, fb_dout_ready, fb_rd, fb_we;
    wire  [7:0] fb_burstcnt, fb_be;
    wire [28:0] fb_addr;
    wire [63:0] fb_dout, fb_din;
    fbrom fbrom (
        .clk(clk), .rst(rst),
        .f_req(f_req), .f_we(f_we), .f_addr(f_addr), .f_wdata(f_wdata), .f_ack(f_ack), .f_rdata(f_rdata),
        .dl_wr(dl_wr), .dl_index(dl_index), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait),
        .DDRAM_BUSY(fb_busy), .DDRAM_BURSTCNT(fb_burstcnt), .DDRAM_ADDR(fb_addr), .DDRAM_DOUT(fb_dout),
        .DDRAM_DOUT_READY(fb_dout_ready), .DDRAM_RD(fb_rd), .DDRAM_DIN(fb_din), .DDRAM_BE(fb_be),
        .DDRAM_WE(fb_we)
    );

    ddr3_arb arb (
        .clk(clk), .rst(rst),
        .sc_req(sc_req), .sc_addr(sc_addr), .sc_len(sc_len), .sc_ack(sc_ack), .sc_rvalid(sc_rvalid),
        .vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_len(vr_len), .vr_be(vr_be),
        .vr_wdata(vr_wdata), .vr_ack(vr_ack), .vr_rvalid(vr_rvalid), .vr_wq_empty(vr_wq_empty),
        .rdata(a_rdata),
        .fb_busy(fb_busy), .fb_burstcnt(fb_burstcnt), .fb_addr(fb_addr), .fb_dout(fb_dout),
        .fb_dout_ready(fb_dout_ready), .fb_rd(fb_rd), .fb_din(fb_din), .fb_be(fb_be), .fb_we(fb_we),
        .nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata), .nb_ack(nb_ack), .nb_rdata(nb_rdata),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );

    // the serial terminal's stand-in: a fixed colour, its own 1024x768 timing
    reg [10:0] vh, vv;
    always @(posedge clk_pix) begin
        if (vh == 11'd1343) begin vh <= 11'd0; vv <= vv == 11'd805 ? 11'd0 : vv + 11'd1; end
        else vh <= vh + 11'd1;
    end
    wire v_hb = vh >= 11'd1024, v_vb = vv >= 11'd768;
    tga_vsel vsel (
        .clk_pix(clk_pix), .gfx(gfx), .tga_on(video_on),
        .t_ce(t_ce), .t_hs(t_hs), .t_vs(t_vs), .t_de(t_de), .t_hb(t_hb), .t_vb(t_vb),
        .t_r(t_r), .t_g(t_g), .t_b(t_b),
        .v_hs(vh >= 11'd1048 && vh < 11'd1184), .v_vs(vv >= 11'd771 && vv < 11'd777),
        .v_de(!v_hb && !v_vb), .v_hb(v_hb), .v_vb(v_vb), .v_r(8'h12), .v_g(8'h34), .v_b(8'h56),
        .ce(ce_pix), .hs(hs), .vs(vs), .de(de), .hblank(hblank), .vblank(vblank),
        .r(r), .g(g), .b(b), .showing_tga(showing_tga)
    );
endmodule
