// Bench top for the 53C810 (rtl/scsi/ncr53c810.v) and its SCSI targets
// (rtl/scsi/scsi_targets.v): the PCI target bus, the DMA port and the
// hps_io block-device side go out to tb_ncr810.cpp.
module tb_ncr810_top (
    input  wire        clk,
    input  wire        reset,
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
    input  wire  [2:0] img_present,
    input  wire [95:0] img_blocks,
    output wire [95:0] sd_lba,
    output wire [17:0] sd_blk_cnt,
    output wire  [2:0] sd_rd,
    output wire  [2:0] sd_wr,
    input  wire  [2:0] sd_ack,
    input  wire [13:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,
    input  wire        sd_buff_wr,
    input  wire        cd_change,
    output wire signed [15:0] cd_audio_l,
    output wire signed [15:0] cd_audio_r,
    output wire        cd_audio_stb,
    output wire        activity
);
    wire       sel, sel_atn, sel_done, sel_fail, bsy, req, ack, ackhold, atn, brst;
    wire [2:0] sel_id, phase;
    wire [7:0] tdata, idata;
    wire       resel, resel_ok, resel_ack;
    wire [2:0] resel_id;

    ncr53c810 #(.DEVNUM(6), .STO_UNIT(16)) ncr (
        .clk(clk), .reset(reset),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_claim(pt_claim), .pt_ack(pt_ack), .pt_rdata(pt_rdata),
        .dm_req(dm_req), .dm_we(dm_we), .dm_addr(dm_addr), .dm_be(dm_be), .dm_wdata(dm_wdata),
        .dm_ack(dm_ack), .dm_rdata(dm_rdata),
        .inta_n(inta_n),
        .sb_sel(sel), .sb_sel_id(sel_id), .sb_sel_atn(sel_atn), .sb_sel_done(sel_done), .sb_sel_fail(sel_fail),
        .sb_bsy(bsy), .sb_req(req), .sb_phase(phase), .sb_tdata(tdata),
        .sb_ack(ack), .sb_idata(idata), .sb_ackhold(ackhold), .sb_atn(atn), .sb_rst(brst),
        .sb_resel(resel), .sb_resel_id(resel_id), .sb_resel_ok(resel_ok), .sb_resel_ack(resel_ack)
    );

    // CLK_HZ: the bench's sample clock runs 44100 / 441000 = 10x faster than real time
    // DISC_CYCLES: a data phase stalled 5000 clocks on hps_io disconnects (1 s on the board)
    scsi_targets #(.CLK_HZ(441000), .DISC_CYCLES(27'd5000)) tgt (
        .clk(clk), .rst(reset),
        .sel(sel), .sel_id(sel_id), .sel_atn(sel_atn), .sel_done(sel_done), .sel_fail(sel_fail),
        .bsy(bsy), .req(req), .phase(phase), .tdata(tdata),
        .ack(ack), .idata(idata), .ackhold(ackhold), .atn(atn), .brst(brst),
        .resel(resel), .resel_id(resel_id), .resel_ok(resel_ok), .resel_ack(resel_ack),
        .img_present(img_present), .img_blocks(img_blocks),
        .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr), .cd_change(cd_change),
        .cd_audio_l(cd_audio_l), .cd_audio_r(cd_audio_r), .cd_audio_stb(cd_audio_stb), .activity(activity)
    );
endmodule
