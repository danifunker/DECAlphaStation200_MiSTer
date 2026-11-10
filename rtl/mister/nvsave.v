// The flashbus NVRAM (8 KB: SRM's environment variables and ISA table, ARC's
// configuration) and the TOY clock's CMOS RAM kept in a file on the SD card
// through hps_io block device slot 4 (the OSD's "NVRAM image", SC4).
//   - blocks 0-15 (8 KB): the NVRAM, as before;
//   - block 16 (an 8,704-byte file only): the TOY CMOS, the battery-backed part
//     of the real clock chip. Bytes 0-3 "CMOS" mark it valid, bytes 128-255 are
//     CMOS 00h-7Fh (0Eh-7Fh used; 3Fh is the console the DROM's flash loader
//     starts: 1 ARC, else SRM), the rest is zero. An 8 KB file (the older
//     size) is read and written as 16 blocks and keeps no CMOS; a block 16
//     without the marker (e.g. zeros from padding the file) loads nothing.
// The file is created once (any content: SRM rebuilds a bad table).
//   - mount: all blocks are read in (the NVRAM through port B of the 21071
//     model's NVRAM, the CMOS through the TOY's cm_* port), whatever the
//     machine is doing;
//   - save: 2 s after the last CPU write to the NVRAM or the CMOS, all blocks
//     are written back (only while a file is mounted).
// The NVRAM's port B reads with one clock of latency; block 16's bytes are
// registered the same way, so sd_buff_din always follows sd_buff_addr by one.
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
    input  wire        nv_dirty,

    // the TOY CMOS's save port (rtl/sio/isa_rtc.v)
    output wire  [6:0] cm_addr,
    output wire        cm_we,
    output wire  [7:0] cm_wdata,
    input  wire  [7:0] cm_rdata,
    input  wire        cm_dirty,

    output reg         loaded           // the image has been read in once since rst (the machine waits for it)
);
    localparam [31:0] QUIET = CLK_HZ * 2;
    localparam [63:0] CMOS_SIZE = 64'd8704;     // 17 blocks: the NVRAM and the CMOS
    reg        mounted, cmos_file, sd_rd_phase, busy, ack_seen, dirty, marker_ok;
    reg [31:0] quiet;

    // block 16: the byte's offset, and whether it is one of the CMOS's 128
    wire       blk16   = sd_buff_addr[13];
    wire [8:0] off     = sd_buff_addr[8:0];
    wire       in_cmos = off[8:7] == 2'b01;     // 128-255
    function [7:0] marker;                      // "CMOS"
        input [1:0] i;
        begin marker = i == 2'd0 ? 8'h43 : i == 2'd1 ? 8'h4D : i == 2'd2 ? 8'h4F : 8'h53; end
    endfunction

    assign sd_blk_cnt = cmos_file ? 6'd16 : 6'd15;  // 17 or 16 x 512 bytes per request
    assign nvb_addr   = sd_buff_addr[12:0];
    assign nvb_we     = sd_ack && sd_buff_wr && sd_rd_phase && !blk16;
    assign nvb_wdata  = sd_buff_dout;

    assign cm_addr  = off[6:0];
    assign cm_wdata = sd_buff_dout;
    assign cm_we    = sd_ack && sd_buff_wr && sd_rd_phase && blk16 && in_cmos && marker_ok;

    // the save's data: the NVRAM's registered read, or block 16's byte registered alike
    reg       q_blk16;
    reg [7:0] q16;
    always @(posedge clk) begin
        q_blk16 <= blk16;
        q16 <= off < 9'd4 ? marker(off[1:0]) : in_cmos ? cm_rdata : 8'h00;
    end
    assign sd_buff_din = q_blk16 ? q16 : nvb_rdata;

    always @(posedge clk) begin
        if (rst) begin
            sd_rd <= 1'b0; sd_wr <= 1'b0; busy <= 1'b0; ack_seen <= 1'b0;
            dirty <= 1'b0; quiet <= 32'd0; loaded <= 1'b0;
        end else begin
            if (nv_dirty || cm_dirty) begin dirty <= 1'b1; quiet <= QUIET; end
            else if (quiet != 32'd0) quiet <= quiet - 32'd1;

            if (img_mounted) begin
                mounted   <= img_size != 64'd0;
                cmos_file <= img_size >= CMOS_SIZE;
                if (img_size != 64'd0 && !busy) begin
                    sd_lba <= 32'd0; sd_rd <= 1'b1; sd_rd_phase <= 1'b1; busy <= 1'b1;
                end
            end else if (!busy && mounted && dirty && quiet == 32'd0) begin
                sd_lba <= 32'd0; sd_wr <= 1'b1; sd_rd_phase <= 1'b0; busy <= 1'b1; dirty <= 1'b0;
            end

            // the marker, checked as block 16's first four bytes arrive (in order)
            if (sd_ack && sd_buff_wr && sd_rd_phase && blk16 && off < 9'd4)
                marker_ok <= sd_buff_dout == marker(off[1:0]) && (off == 9'd0 || marker_ok);

            if (busy) begin
                if (sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; ack_seen <= 1'b1; end
                else if (ack_seen) begin busy <= 1'b0; ack_seen <= 1'b0; if (sd_rd_phase) loaded <= 1'b1; end
            end
        end
    end

    initial begin mounted = 1'b0; cmos_file = 1'b0; marker_ok = 1'b0; end
endmodule
