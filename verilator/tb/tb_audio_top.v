// Bench top for rtl/audio (verilator/tb/tb_audio.cpp): the 82378 SIO with
// as200_audio on its xio bus, wired the way rtl/as200_sys.v wires them, so
// the real 8237 does the DMA; plus a lone audio_mix (mx_*) for the
// saturation tests.
module tb_audio_top (
    input  wire        clk,
    input  wire        rst,

    input  wire        pt_req,
    input  wire  [1:0] pt_cmd,
    input  wire  [4:0] pt_dev,
    input  wire [31:0] pt_addr,
    input  wire  [3:0] pt_be,
    input  wire        pt_we,
    input  wire [31:0] pt_wdata,
    input  wire        pt_sub,
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

    output wire        intr,
    input  wire [15:0] cd_l,
    input  wire [15:0] cd_r,
    input  wire        cd_stb,
    input  wire        spk_force,          // OR into the SIO's speaker
    input  wire  [3:0] mute,

    output wire [15:0] aud_l,
    output wire [15:0] aud_r,
    output wire        aud_tgl,
    output wire [15:0] wss_l,              // the codec's output
    output wire [15:0] wss_r,
    output wire [15:0] fm,                 // the OPL's, left
    output wire [15:0] fm_r,
    output wire [15:0] irq,                // the card's IRQ lines
    output wire  [7:0] dreq,

    input  wire [15:0] mx_a_l, mx_a_r, mx_b, mx_b_r, mx_c_l, mx_c_r,
    input  wire        mx_c_stb, mx_spk,
    output wire [15:0] mx_l, mx_r,
    output wire        mx_tgl
);
    wire [15:0] xio_addr, xio_dack_data, xio_dev_data, xio_irq;
    wire        xio_rd, xio_wr, xio_claim, xio_dack, xio_tc;
    wire  [7:0] xio_wdata, xio_rdata, xio_dreq;
    wire  [2:0] xio_dack_ch, xio_dma_ch;
    wire        spk;

    // the audio clock: 24.576 MHz out of the bench's 100 MHz (a phase accumulator's top bit)
    reg [31:0] ca;
    always @(posedge clk) ca <= ca + 32'd1055531162;
    wire clk_audio = ca[31];

    sio82378 #(.CLK_HZ(100000000), .RTC_FAST(1)) sio (
        .clk(clk), .rst(rst),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_sub(pt_sub), .pt_claim(pt_claim), .pt_ack(pt_ack),
        .pt_rdata(pt_rdata),
        .dm_req(dm_req), .dm_we(dm_we), .dm_addr(dm_addr), .dm_be(dm_be), .dm_wdata(dm_wdata),
        .dm_ack(dm_ack), .dm_rdata(dm_rdata),
        .pirq_n(4'hF), .serr(1'b0), .iochk(1'b0),
        .intr(intr), .nmi(), .toy_irq(), .kbrst(), .spk(spk),
        .xio_addr(xio_addr), .xio_rd(xio_rd), .xio_wr(xio_wr), .xio_wdata(xio_wdata),
        .xio_claim(xio_claim), .xio_rdata(xio_rdata), .xio_irq(xio_irq), .xio_dreq(xio_dreq),
        .xio_dack(xio_dack), .xio_dack_ch(xio_dack_ch), .xio_dack_data(xio_dack_data),
        .xio_dev_data(xio_dev_data), .xio_dma_ch(xio_dma_ch), .xio_tc(xio_tc),
        .com1_txd(), .com1_rxd(1'b1), .com1_rts_n(), .com1_dtr_n(), .com1_cts_n(1'b1), .com1_dsr_n(1'b1),
        .com1_ri_n(1'b1), .com1_dcd_n(1'b1), .com1_tx_stb(), .com1_tx_byte(),
        .com1_rx_inj_stb(1'b0), .com1_rx_inj_byte(8'd0),
        .com2_txd(), .com2_rxd(1'b1), .com2_rts_n(), .com2_dtr_n(), .com2_cts_n(1'b1), .com2_dsr_n(1'b1),
        .com2_ri_n(1'b1), .com2_dcd_n(1'b1),
        .ps2_key(11'd0), .ps2_mouse(25'd0), .rtc(65'd0), .year_ovr_en(1'b0), .year_ovr(7'd0), .console_mode(2'd1), .srm_con_mode(2'd0), .cm_addr(7'd0), .cm_we(1'b0), .cm_wdata(8'd0), .cm_rdata(), .cm_dirty(),
        .fd_mounted(1'b0), .fd_readonly(1'b0), .fd_size(64'd0), .fd_lba(), .fd_blk_cnt(), .fd_rd(), .fd_wr(),
        .fd_ack(1'b0), .fd_buff_addr(14'd0), .fd_buff_dout(8'd0), .fd_buff_wr(1'b0), .fd_buff_din(), .fd_led(),
        .lpt_data()
    );

    as200_audio audio (
        .clk(clk), .rst(rst), .clk_audio(clk_audio),
        .xio_addr(xio_addr), .xio_rd(xio_rd), .xio_wr(xio_wr), .xio_wdata(xio_wdata),
        .xio_claim(xio_claim), .xio_rdata(xio_rdata), .xio_irq(xio_irq), .xio_dreq(xio_dreq),
        .xio_dack(xio_dack), .xio_dack_ch(xio_dack_ch), .xio_dack_data(xio_dack_data),
        .xio_dev_data(xio_dev_data), .xio_dma_ch(xio_dma_ch), .xio_tc(xio_tc),
        .speaker(spk | spk_force), .cd_audio_l(cd_l), .cd_audio_r(cd_r), .cd_audio_stb(cd_stb),
        .mute(mute), .aud_l(aud_l), .aud_r(aud_r), .aud_tgl(aud_tgl)
    );
    assign wss_l = audio.pcm_l;
    assign wss_r = audio.pcm_r;
    assign fm    = audio.fm_l;
    assign fm_r  = audio.fm_r;
    assign irq   = xio_irq;
    assign dreq  = xio_dreq;

    audio_mix mix (
        .clk(clk), .rst(rst),
        .wss_l(mx_a_l), .wss_r(mx_a_r), .opl_l(mx_b), .opl_r(mx_b_r), .cd_l(mx_c_l), .cd_r(mx_c_r), .cd_stb(mx_c_stb),
        .spk(mx_spk), .mute(4'd0), .out_l(mx_l), .out_r(mx_r), .out_tgl(mx_tgl)
    );
endmodule
