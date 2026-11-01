// The flashbus NVRAM (8 KB: SRM's environment variables and ISA table, ARC's
// configuration) kept in a file on the SD card through hps_io block device
// slot 4 (the OSD's "NVRAM image", SC4). The file is 8 KB (16 blocks); the
// user creates it once (any content: SRM rebuilds a bad table).
//   - mount: the 16 blocks are read into the NVRAM (port B of the 21071
//     model's NVRAM), whatever the machine is doing;
//   - save: 2 s after the last CPU write to the NVRAM, all 16 blocks are
//     written back (only while a file is mounted).
module nvsave #(
    parameter CLK_HZ = 100000000
) (
    input  wire        clk,
    input  wire        rst,

    // hps_io slot 4
    input  wire        img_mounted,      // img_mounted[4]
    input  wire [63:0] img_size,
    output reg  [31:0] sd_lba,
    output wire  [5:0] sd_blk_cnt,
    output reg         sd_rd,
    output reg         sd_wr,
    input  wire        sd_ack,           // sd_ack[4]
    input  wire [13:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,
    input  wire        sd_buff_wr,

    // the NVRAM's port B
    output wire [12:0] nvb_addr,
    output wire        nvb_we,
    output wire  [7:0] nvb_wdata,
    input  wire  [7:0] nvb_rdata,
    input  wire        nv_dirty
);
    assign sd_blk_cnt  = 6'd15;                  // 16 x 512 = 8 KB per request
    assign nvb_addr    = sd_buff_addr[12:0];
    assign nvb_we      = sd_ack && sd_buff_wr && sd_rd_phase;
    assign nvb_wdata   = sd_buff_dout;
    assign sd_buff_din = nvb_rdata;

    localparam [31:0] QUIET = CLK_HZ * 2;
    reg        mounted, sd_rd_phase, busy, ack_seen, dirty;
    reg [31:0] quiet;

    always @(posedge clk) begin
        if (rst) begin
            sd_rd <= 1'b0; sd_wr <= 1'b0; busy <= 1'b0; ack_seen <= 1'b0;
            dirty <= 1'b0; quiet <= 32'd0;
        end else begin
            if (nv_dirty) begin dirty <= 1'b1; quiet <= QUIET; end
            else if (quiet != 32'd0) quiet <= quiet - 32'd1;

            if (img_mounted) begin
                mounted <= img_size != 64'd0;
                if (img_size != 64'd0 && !busy) begin
                    sd_lba <= 32'd0; sd_rd <= 1'b1; sd_rd_phase <= 1'b1; busy <= 1'b1;
                end
            end else if (!busy && mounted && dirty && quiet == 32'd0) begin
                sd_lba <= 32'd0; sd_wr <= 1'b1; sd_rd_phase <= 1'b0; busy <= 1'b1; dirty <= 1'b0;
            end

            if (busy) begin
                if (sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; ack_seen <= 1'b1; end
                else if (ack_seen) begin busy <= 1'b0; ack_seen <= 1'b0; end
            end
        end
    end
endmodule
