// The floppy drive's medium (docs/design/floppy.md 3): the OSD's "Floppy
// (A:)" image on hps_io block device slot 3, seen by the controller
// (rtl/sio/isa_fdc.v) as a geometry and a track cache.
//
// Geometry, from the image size at each mount (512-byte sectors, two heads):
//   1440 blocks and up  720 KB   9 sectors a track, 250 kbps
//   2400                1.2 MB  15 sectors, 500 kbps
//   2880                1.44 MB 18 sectors, 500 kbps
//   3360                1.68 MB 21 sectors (DMF), 500 kbps
//   5760                2.88 MB 36 sectors, 1 Mbps
// the largest row whose size the image reaches, its tracks the image's whole
// cylinders (at most 84). An empty slot (size 0) is no medium; a smaller image
// is an unformatted medium (no cylinders). The read-only flag of the mount
// is the write-protect tab.
//
// The track cache (12 KB of block RAM): the group of sectors the controller
// wants (want_lba, want_cnt: a whole track, or half of a 36-sector track),
// read from the image in one hps_io request (blk_cnt = want_cnt - 1);
// trk_rdy while it holds that group. The controller reads and writes the
// cache's bytes at buf_a = {slot, byte}; written sectors are marked dirty
// (dirty_stb with the slot) and go back to the image in the background, the
// dirty slots' span in one request, before any other group is loaded. A
// mount drops the cache and anything dirty (the old image's).
//
// One clock: hps_io runs on the machine's 100 MHz here. Nothing here is reset
// by the machine's reset (a mount is seen once, and a write-back in flight
// must finish): the registers start at their power-up values.
module isa_fdc_img (
    input  wire        clk,

    // hps_io block device (slot 3): 512-byte blocks, 8-bit buffer
    input  wire        img_mounted,     // a pulse; img_readonly and img_size are valid with it
    input  wire        img_readonly,
    input  wire [63:0] img_size,
    output reg  [31:0] sd_lba = 32'd0,
    output reg   [5:0] sd_blk_cnt = 6'd0,
    output reg         sd_rd = 1'b0,
    output reg         sd_wr = 1'b0,
    input  wire        sd_ack,
    input  wire [13:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    input  wire        sd_buff_wr,
    output reg   [7:0] sd_buff_din,

    // the controller's side
    output reg         med_in = 1'b0,          // a medium is in the drive
    output reg         med_ro = 1'b0,          // ... write-protected
    output reg   [5:0] spt = 6'd18,             // its sectors a track (9, 15, 18, 21, 36)
    output reg   [1:0] mrate = 2'd0,           // its data rate (the CCR/DSR code: 0 500k, 2 250k, 3 1M)
    output reg   [6:0] ntrk = 7'd0,            // its cylinders
    output reg         changed = 1'b0,         // a pulse: a mount (the disk change line)
    input  wire        want,            // the controller wants a group
    input  wire [12:0] want_lba,        // its first sector
    input  wire  [5:0] want_cnt,        // its sectors
    output reg         trk_rdy = 1'b0,         // the cache holds it
    input  wire [13:0] buf_a,
    input  wire        buf_we,
    input  wire  [7:0] buf_wd,
    output reg   [7:0] buf_q,           // the byte at buf_a, a clock later
    input  wire        dirty_stb,
    input  wire  [4:0] dirty_slot
);
    // ---------------------------------------------------------------- the cache RAM (true dual port)
    (* ramstyle = "no_rw_check, M10K" *) reg [7:0] mem [0:12287];   // no port relies on read-during-write
    reg [13:0] a_base = 14'd0;          // port A: the request's first byte in the cache
    reg        a_load = 1'b0;                // the request in flight is a load (hps_io writes the cache)
    wire [13:0] a_addr = a_base + sd_buff_addr;
    wire        a_we   = sd_ack && sd_buff_wr && a_load && a_addr < 14'd12288;
    always @(posedge clk) begin
        if (a_we) mem[a_addr] <= sd_buff_dout;
        sd_buff_din <= mem[a_addr];
    end
    always @(posedge clk) begin
        if (buf_we) mem[buf_a] <= buf_wd;
        buf_q <= mem[buf_a];
    end

    // ---------------------------------------------------------------- the medium
    reg [31:0] blocks = 32'd0;          // the image's size in blocks (saturated)
    reg  [2:0] g_st = 3'd0;             // the geometry's computation after a mount
    reg [31:0] g_rem = 32'd0;
    reg  [6:0] g_trk = 7'd0;
    wire [6:0] cyl_blk = {spt, 1'b0};   // blocks a cylinder (2 x spt; at most 72)
    always @(posedge clk) begin
        changed <= 1'b0;
        case (g_st)
        3'd1: begin                     // sectors a track, rate
            if      (blocks >= 32'd5760) begin spt <= 6'd36; mrate <= 2'd3; end
            else if (blocks >= 32'd3360) begin spt <= 6'd21; mrate <= 2'd0; end
            else if (blocks >= 32'd2880) begin spt <= 6'd18; mrate <= 2'd0; end
            else if (blocks >= 32'd2400) begin spt <= 6'd15; mrate <= 2'd0; end
            else                         begin spt <= 6'd9;  mrate <= 2'd2; end
            g_rem <= blocks; g_trk <= 7'd0; g_st <= 3'd2;
        end
        3'd2: begin                     // whole cylinders, by subtraction (84 at most)
            if (g_rem >= {25'd0, cyl_blk} && g_trk != 7'd84) begin
                g_rem <= g_rem - {25'd0, cyl_blk}; g_trk <= g_trk + 7'd1;
            end else begin
                ntrk <= g_trk; changed <= 1'b1; g_st <= 3'd0;
            end
        end
        default: ;
        endcase
        if (img_mounted) begin
            med_in <= img_size != 64'd0;
            med_ro <= img_readonly;
            blocks <= img_size[63:41] != 23'd0 ? 32'hFFFFFFFF : img_size[40:9];
            g_st   <= 3'd1;
        end
    end

    // ---------------------------------------------------------------- the cache
    localparam S_IDLE = 3'd0, S_RREQ = 3'd1, S_RX = 3'd2, S_WREQ = 3'd3, S_WX = 3'd4;
    reg  [2:0] st = S_IDLE;
    reg        valid = 1'b0;            // the cache holds the group at base
    reg [12:0] base = 13'd0;
    reg        stale = 1'b0;            // a mount came while a request was in flight
    reg        d_any = 1'b0;            // dirty slots d_lo .. d_hi
    reg  [4:0] d_lo = 5'd0, d_hi = 5'd0;
    wire       wb_go = st == S_IDLE && d_any && valid && !img_mounted;

    always @(posedge clk) begin
        trk_rdy <= valid && base == want_lba && st != S_RREQ && st != S_RX;

        // the dirty span (a new mark in the cycle the span is taken starts the next one)
        if (wb_go) begin
            d_any <= dirty_stb;
            d_lo  <= dirty_slot;
            d_hi  <= dirty_slot;
        end else if (dirty_stb) begin
            d_any <= 1'b1;
            if (!d_any || dirty_slot < d_lo) d_lo <= dirty_slot;
            if (!d_any || dirty_slot > d_hi) d_hi <= dirty_slot;
        end

        case (st)
        S_IDLE: begin
            if (wb_go) begin                                            // write back first
                sd_lba     <= {19'd0, base} + {27'd0, d_lo};
                sd_blk_cnt <= {1'b0, d_hi - d_lo};
                a_base     <= {d_lo, 9'd0};
                a_load     <= 1'b0;
                st         <= S_WREQ;
            end else if (want && !d_any && !(valid && base == want_lba) && med_in && !img_mounted && g_st == 3'd0) begin
                valid      <= 1'b0;
                base       <= want_lba;
                sd_lba     <= {19'd0, want_lba};
                sd_blk_cnt <= want_cnt - 6'd1;
                a_base     <= 14'd0;
                a_load     <= 1'b1;
                stale      <= 1'b0;
                st         <= S_RREQ;
            end
        end
        S_RREQ: begin
            sd_rd <= 1'b1;
            if (sd_ack) begin sd_rd <= 1'b0; st <= S_RX; end
        end
        S_RX: if (!sd_ack) begin valid <= !stale; st <= S_IDLE; end
        S_WREQ: begin
            sd_wr <= 1'b1;
            if (sd_ack) begin sd_wr <= 1'b0; st <= S_WX; end
        end
        S_WX: if (!sd_ack) st <= S_IDLE;
        default: st <= S_IDLE;
        endcase

        if (img_mounted) begin
            valid <= 1'b0; d_any <= 1'b0; stale <= 1'b1;
            // a request not yet taken is withdrawn; one in flight finishes (and is dropped)
            if ((st == S_RREQ || st == S_WREQ) && !sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; st <= S_IDLE; end
        end
    end
endmodule
