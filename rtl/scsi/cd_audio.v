//============================================================================
//
//  DEC AlphaStation 200 - the CD-ROM's audio player (rtl/scsi/scsi_targets.v
//  drives it; docs/design/cdrom.md)
//
//  Ported to Verilog-2001 from the user's HP 9000/715 core
//  (rtl/scsi/cd_audio.sv). Changes for this machine:
//    - hps_io is 8 bits wide here: the frame arrives as bytes (fb_addr is the
//      byte in the 5-block transfer) and is packed into halfwords;
//    - MODE page 0x0E's channel selection is applied (port 0 = left output,
//      port 1 = right; bit 0 of a port's selection = audio channel 0, bit 1 =
//      channel 1, both = their average, none = muted);
//    - an output strobe at the sample rate (out_stb, every 1/44100 s whether
//      playing or not) for the mixer.
//
//  What an RRD45's PLAY AUDIO commands do, on the image Main_MiSTer serves
//  (support/decalpha), from two windows above the data on the CD slot:
//    block 0xC0000000, 2 blocks: the track table -- byte 0 first track, 1 the
//      number of tracks n, 4 the last session's first track, 5 the number of
//      sessions, then from byte 8 n + 1 entries of 8 bytes {ADR/control,
//      track, M, S, F (absolute, 150 frames ahead of LBA 0), LBA[23:0]}, the
//      lead-out (track 0xAA) last;
//    block 0x80000000 + 5f: disc frame f, 2352 bytes of 44.1 kHz 16-bit
//      stereo samples (little-endian, left first) then 208 zero bytes.
//  The engine copies the table into toc (port A), and READ TOC reads it back
//  there. The player fetches one frame at a time into one of two banks (fr_*:
//  the engine's sd port, a 5-block transfer whose bytes arrive on fb_*), plays
//  its 588 samples at 44.1 kHz while the other bank fills, and keeps the
//  sub-channel position (track, absolute and track-relative M:S:F and LBA).
//  Output: the samples times page 0x0E's port volume (0-255), held between
//  samples, zero unless playing. Frame numbers are 19 bits (524,288 frames =
//  116:30, past the 99:59:74 a disc can hold).
//
//============================================================================

module cd_audio #(
    parameter CLK_HZ = 100000000
) (
    input  wire        clk,
    input  wire        rst,
    // the track table: port A (written while copying, read for READ TOC)
    input  wire        toc_we,
    input  wire  [6:0] toc_a,
    input  wire [63:0] toc_wd,
    output reg  [63:0] toc_q,               // entry toc_a, a clock later
    input  wire  [7:0] toc_first,           // first track, number of tracks
    input  wire  [7:0] toc_n,
    // commands (pulses): play [p_start, p_end) (absolute LBAs), pause, resume, stop
    input  wire        play,
    input  wire [18:0] p_start,
    input  wire [18:0] p_end,
    input  wire        pause,
    input  wire        resume,
    input  wire        stop,
    // READ SUB-CHANNEL: audio status (0x11 playing, 0x12 paused, 0x13
    // completed, 0x15 none) and the position
    output reg   [7:0] a_status,
    input  wire        status_read,         // reported: 0x13 becomes 0x15
    output reg   [7:0] q_ctl,
    output reg   [7:0] q_track,
    output wire [23:0] q_abs_lba,
    output wire [23:0] q_rel_lba,
    output reg  [23:0] q_abs_msf,           // {M, S, F}
    output reg  [23:0] q_rel_msf,
    output wire        playing,             // a play is under way (or paused)
    // frame fetch
    output reg         fr_req,              // held until fr_go
    output reg  [31:0] fr_lba,              // 0x80000000 + 5 * frame
    input  wire        fr_go,               // the engine started it
    input  wire        fr_done,             // ... and it finished
    input  wire        fb_we,
    input  wire [11:0] fb_addr,             // byte in the transfer
    input  wire  [7:0] fb_data,
    // MODE page 0x0E: port 0 (left) and 1 (right) channel selection and volume
    input  wire  [3:0] sel_l,
    input  wire  [3:0] sel_r,
    input  wire  [7:0] vol_l,
    input  wire  [7:0] vol_r,
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r,
    output reg         out_stb               // out_l/out_r took a new sample (44.1 kHz)
);
    // ------------------------------------------------------------ the track table
    // whole-entry writes (byte-enabled writes with the second read port crash
    // Quartus 17's RAM inference: the HP core, 2026-10-18)
    reg  [63:0] toc [0:127];
    reg   [6:0] tb_a;
    reg  [63:0] tb_q;
    always @(posedge clk) begin
        if (toc_we) toc[toc_a] <= toc_wd;
        toc_q <= toc[toc_a];
    end
    always @(posedge clk) tb_q <= toc[tb_a];

    // ------------------------------------------------------------ the frame banks
    // bank b, halfword h at {b, h[10:0]}; a frame's 588 samples are halfwords
    // 0..1175; the bytes arrive in order, so the low one waits in fb_lo
    reg  [15:0] fbuf [0:4095];
    reg         fill_bank;
    reg  [11:0] rd_a;
    reg  [15:0] rd_q;
    reg   [7:0] fb_lo;
    always @(posedge clk) begin
        if (fb_we && !fb_addr[0]) fb_lo <= fb_data;
        if (fb_we && fb_addr[0]) fbuf[{fill_bank, fb_addr[11:1]}] <= {fb_data, fb_lo};
        rd_q <= fbuf[rd_a];
    end

    // ------------------------------------------------------------ the player
    localparam [63:0] STEP64 = (64'd44100 << 32) / CLK_HZ;
    localparam [31:0] STEP   = STEP64[31:0];
    localparam [1:0] P_IDLE = 2'd0, P_FIND = 2'd1, P_SCAN = 2'd2, P_PLAY = 2'd3;
    reg   [1:0] pst;
    reg         paused;
    reg  [18:0] cur, last;                  // the frame playing, the end (exclusive)
    reg  [18:0] next_start;                 // where the next track starts
    reg  [18:0] rel;                        // cur from the track's start
    reg   [1:0] bank_v;                     // bank b holds frame bank_f[b]
    reg  [18:0] bank_f0, bank_f1;
    reg         pbank;                      // the bank playing
    reg   [9:0] k;                          // sample in the frame
    reg  [32:0] acc;
    reg         tick, rd_l, rd_r, rd_r2;
    reg  signed [15:0] s_l, s_r;
    reg         fetching;
    reg   [7:0] scan_i;                     // entry in tb_q (+ 1)

    // M:S:F one frame on
    function [23:0] msf_inc;
        input [23:0] m;
        reg [7:0] mm, ss, ff;
        begin
            mm = m[23:16]; ss = m[15:8]; ff = m[7:0];
            if (ff == 8'd74) begin
                ff = 8'd0;
                if (ss == 8'd59) begin ss = 8'd0; mm = mm + 8'd1; end else ss = ss + 8'd1;
            end else ff = ff + 8'd1;
            msf_inc = {mm, ss, ff};
        end
    endfunction
    // frames to M:S:F by subtraction (at most 116 + 59 clocks), absolute and relative
    reg  [19:0] ca_x;                       // cur + 150
    reg  [18:0] cr_x;
    reg   [7:0] ca_m, ca_s, cr_m, cr_s;
    reg         ca_go, cr_go;

    // the next frame wanted: the one after cur in the other bank once cur is in its bank
    wire [18:0] pb_f   = pbank ? bank_f1 : bank_f0;
    wire        cur_in = bank_v[pbank] && pb_f == cur;
    wire [19:0] want_f = cur_in ? {1'b0, cur} + 20'd1 : {1'b0, cur};
    wire        want_b = cur_in ? ~pbank : pbank;
    wire [18:0] wb_f   = want_b ? bank_f1 : bank_f0;
    wire        need   = pst == P_PLAY && !paused && want_f < {1'b0, last} &&
                         !(bank_v[want_b] && wb_f == want_f[18:0]);
    wire [21:0] want5  = {1'b0, want_f[18:0], 2'b00} + {3'd0, want_f[18:0]};   // 5 * want_f < 2^22
    assign q_abs_lba = {5'd0, cur};
    assign q_rel_lba = {5'd0, rel};
    assign playing   = pst != P_IDLE;

    always @(posedge clk) begin
        tick <= 1'b0; rd_l <= 1'b0; rd_r <= rd_l; rd_r2 <= rd_r;
        if (rst) begin
            pst <= P_IDLE; paused <= 1'b0; a_status <= 8'h15;
            bank_v <= 2'b00; fr_req <= 1'b0; fetching <= 1'b0; acc <= 33'd0;
            s_l <= 16'sd0; s_r <= 16'sd0; q_track <= 8'd0; q_ctl <= 8'h10;
            cur <= 19'd0; last <= 19'd0; rel <= 19'd0; q_abs_msf <= 24'h000200; q_rel_msf <= 24'd0;
            ca_go <= 1'b0; cr_go <= 1'b0; k <= 10'd0; pbank <= 1'b0; fill_bank <= 1'b0;
            fr_lba <= 32'd0; tb_a <= 7'd0; scan_i <= 8'd0; next_start <= 19'd0;
            bank_f0 <= 19'd0; bank_f1 <= 19'd0; rd_a <= 12'd0;
        end else begin
            if (status_read && a_status == 8'h13) a_status <= 8'h15;

            // the sample clock
            acc <= {1'b0, acc[31:0]} + {1'b0, STEP};
            if (acc[32]) tick <= 1'b1;

            // frame transfers
            if (fr_go) begin fr_req <= 1'b0; fetching <= 1'b1; end
            if (fetching && fr_done) begin fetching <= 1'b0; bank_v[fill_bank] <= 1'b1; end
            if (!fr_req && !fetching && need) begin
                fr_req <= 1'b1; fr_lba <= {10'b10_0000_0000, want5};
                fill_bank <= want_b; bank_v[want_b] <= 1'b0;
                if (want_b) bank_f1 <= want_f[18:0]; else bank_f0 <= want_f[18:0];
            end

            // the conversions
            if (ca_go) begin
                if (ca_x >= 20'd4500) begin ca_x <= ca_x - 20'd4500; ca_m <= ca_m + 8'd1; end
                else if (ca_x >= 20'd75) begin ca_x <= ca_x - 20'd75; ca_s <= ca_s + 8'd1; end
                else begin q_abs_msf <= {ca_m, ca_s, ca_x[7:0]}; ca_go <= 1'b0; end
            end
            if (cr_go) begin
                if (cr_x >= 19'd4500) begin cr_x <= cr_x - 19'd4500; cr_m <= cr_m + 8'd1; end
                else if (cr_x >= 19'd75) begin cr_x <= cr_x - 19'd75; cr_s <= cr_s + 8'd1; end
                else begin q_rel_msf <= {cr_m, cr_s, cr_x[7:0]}; cr_go <= 1'b0; end
            end

            case (pst)
                P_IDLE: ;
                // the track holding cur: the last entry (not the lead-out) starting at or before it
                P_FIND: begin
                    tb_a <= 7'd0; scan_i <= 8'd0; pst <= P_SCAN;
                    q_track <= toc_first; q_ctl <= 8'h10; next_start <= last;
                end
                P_SCAN: begin
                    tb_a <= tb_a + 7'd1; scan_i <= scan_i + 8'd1;
                    if (scan_i != 8'd0) begin                       // tb_q = entry scan_i - 1
                        if (scan_i > toc_n || tb_q[23:0] > {5'd0, cur}) begin
                            if (scan_i <= toc_n + 8'd1 && tb_q[23:0] > {5'd0, cur} && tb_q[23:0] < {5'd0, last})
                                next_start <= tb_q[18:0];
                            pst <= P_PLAY;
                        end else begin
                            q_track <= tb_q[55:48]; q_ctl <= tb_q[63:56];
                            rel <= cur - tb_q[18:0];
                            cr_x <= cur - tb_q[18:0]; cr_m <= 8'd0; cr_s <= 8'd0; cr_go <= 1'b1;
                        end
                    end
                end
                P_PLAY: if (tick && !paused && cur == last) begin
                    pst <= P_IDLE; a_status <= 8'h13;               // the sample after the last one
                end else if (tick && !paused && cur_in) begin
                    // the next sample: halfwords 2k (left) and 2k + 1 (right)
                    rd_a <= {pbank, k, 1'b0}; rd_l <= 1'b1;
                    if (k == 10'd587) begin
                        k <= 10'd0; bank_v[pbank] <= 1'b0; pbank <= ~pbank;
                        cur <= cur + 19'd1;                         // < last: no wrap
                        q_abs_msf <= msf_inc(q_abs_msf);
                        rel <= rel + 19'd1; q_rel_msf <= msf_inc(q_rel_msf);
                        if (cur + 19'd1 != last && cur + 19'd1 == next_start) pst <= P_FIND;   // the next track
                    end else k <= k + 10'd1;
                end
                default: pst <= P_IDLE;
            endcase
            // the sample's two halfwords
            if (rd_l) rd_a <= rd_a + 12'd1;
            if (rd_r) s_l <= rd_q;
            if (rd_r2) s_r <= rd_q;

            // commands
            if (stop) begin pst <= P_IDLE; paused <= 1'b0; a_status <= 8'h15; s_l <= 16'sd0; s_r <= 16'sd0; end
            if (pause && pst != P_IDLE) begin paused <= 1'b1; a_status <= 8'h12; end
            if (resume && pst != P_IDLE && paused) begin paused <= 1'b0; a_status <= 8'h11; end
            if (play) begin
                cur <= p_start; last <= p_end; k <= 10'd0; pbank <= 1'b0; bank_v <= 2'b00;
                s_l <= 16'sd0; s_r <= 16'sd0;
                paused <= 1'b0;
                a_status <= p_end > p_start ? 8'h11 : 8'h13;
                pst <= p_end > p_start ? P_FIND : P_IDLE;
                rel <= 19'd0; q_rel_msf <= 24'd0;
                ca_x <= {1'b0, p_start} + 20'd150; ca_m <= 8'd0; ca_s <= 8'd0; ca_go <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ the output
    // the port's channel selection (a register stage), then its volume
    wire on = pst == P_PLAY && !paused;
    wire signed [16:0] mono = {s_l[15], s_l} + {s_r[15], s_r};
    function signed [15:0] chsel;
        input [3:0] sel;
        input signed [15:0] l, r;
        input signed [16:0] m;
        case (sel[1:0])
            2'b01: chsel = l;
            2'b10: chsel = r;
            2'b11: chsel = m[16:1];
            default: chsel = 16'sd0;
        endcase
    endfunction
    reg  signed [15:0] c_l, c_r;
    reg   [4:0] stb_d;                    // the tick down the pipe
    reg   [3:0] rd_d;                     // ... and whether it read a sample (rd_l, a clock after it)
    always @(posedge clk) begin
        c_l <= chsel(sel_l, s_l, s_r, mono);
        c_r <= chsel(sel_r, s_l, s_r, mono);
    end
    // 0..256 (255 = unity)
    wire signed [9:0]  g_l = {2'b00, vol_l} + {9'd0, vol_l[7]};
    wire signed [9:0]  g_r = {2'b00, vol_r} + {9'd0, vol_r[7]};
    wire signed [25:0] m_l = c_l * g_l;
    wire signed [25:0] m_r = c_r * g_r;
    always @(posedge clk) begin
        // the sample read at a tick reaches s_r 3 clocks later, c_* 4, out_* 5
        // a tick that read a sample outputs it; one that did not holds the last
        // sample while a play waits for its frame, else gives silence (paused,
        // stopped, completed): a PAUSE neither drops nor repeats a sample
        stb_d <= {stb_d[3:0], tick};
        rd_d  <= {rd_d[2:0], rd_l};
        out_stb <= stb_d[4];
        if (rst) begin out_l <= 16'sd0; out_r <= 16'sd0; stb_d <= 5'd0; rd_d <= 4'd0; out_stb <= 1'b0; end
        else if (stb_d[4]) begin
            if (rd_d[3]) begin out_l <= m_l[23:8]; out_r <= m_r[23:8]; end
            else if (!on) begin out_l <= 16'sd0; out_r <= 16'sd0; end
        end
    end
endmodule
