// Debug traces on the MiSTer UART in place of COM1 (OSD P5 "Serial port"), 8N1 at 115200
// (`stty -F /dev/ttyS1 115200 raw; cat /dev/ttyS1` on the MiSTer; tools/tgatrace.sh).
//
// sel = 1, the TGA trace: a line per TGA register write and, every 50 ms, the frame buffer
// writes since the last report:
//   Rooo dddddddd    a register write: byte offset ooo (0x1F0 = RAMDAC, value RS<<9 | data)
//   Fmm nnnnnnnn     nnnnnnnn frame buffer writes, the mode now mm
// sel = 2, the CPU trace: a line per PAL entry (exception, interrupt, CALL_PAL):
//   Eoooo aaaaaaaa vvvvvvvv   PAL offset oooo, EXC_ADDR<31:0>, VA<31:0>
// sel = 3, the CPU exceptions: the same lines without the frequent entries (ITB/DTB misses,
//   interrupts, and the CALL_PALs NT makes thousands of times a second: 06 08 09 0E 0F 1C 1E 3F,
//   86 83 AB), so arithmetic, unaligned, opcode and access faults, gentrap, bugcheck and reboot
//   all get through the UART
// Events go into a 1024-entry ring that overwrites the oldest: when the UART falls behind,
// the oldest are lost (a line "Dnnnnnnnn" counts them), so after a hang or a halt the last
// 1024 events before it are still sent.
module dbg_trace #(
    parameter CLK_HZ = 100000000
) (
    input  wire        clk,
    input  wire  [1:0] sel,             // 0 off, 1 TGA, 2 CPU, 3 CPU exceptions
    input  wire        rw,              // a TGA register write
    input  wire  [7:0] ri,              // its longword index
    input  wire [31:0] rd,
    input  wire        fw,              // a TGA frame buffer write
    input  wire  [7:0] mode,
    input  wire        ent,             // a PAL entry
    input  wire [13:0] ent_off,
    input  wire [31:0] ent_pc,          // EXC_ADDR<31:0>
    input  wire [31:0] ent_va,          // VA<31:0>
    output reg         txd
);
    wire en = sel != 2'd0;

    // ---------------------------------------------------------------- events
    // {type 2: 0 R, 1 F, 3 E; a 14; d 32; e 32}
    reg  [79:0] evq [0:1023];
    reg   [9:0] ew, er;                 // write, read (er chases ew; lapped -> skip ahead)
    reg  [31:0] fcnt, lost;
    reg  [22:0] tick;
    wire        tick_now = {9'd0, tick} == CLK_HZ / 20 - 1;
    reg         push;
    reg  [79:0] pv;
    wire        hot = ent_off == 14'h03E0 || ent_off == 14'h08E0 || ent_off == 14'h09E0 || ent_off == 14'h00E0 ||
                      ent_off == 14'h2180 || ent_off == 14'h2200 || ent_off == 14'h2240 || ent_off == 14'h2380 ||
                      ent_off == 14'h23C0 || ent_off == 14'h2700 || ent_off == 14'h2780 || ent_off == 14'h2FC0 ||
                      ent_off == 14'h3180 || ent_off == 14'h30C0 || ent_off == 14'h3AC0;
    always @* begin
        push = 1'b0; pv = 80'd0;
        if (sel == 2'd1 && rw) begin push = 1'b1; pv = {2'd0, 6'd0, ri, rd, 32'd0}; end
        else if (sel == 2'd1 && tick_now && fcnt != 32'd0) begin push = 1'b1; pv = {2'd1, 6'd0, mode, fcnt, 32'd0}; end
        else if ((sel == 2'd2 || (sel == 2'd3 && !hot)) && ent) begin push = 1'b1; pv = {2'd3, ent_off, ent_pc, ent_va}; end
    end
    always @(posedge clk) begin
        tick <= tick_now ? 23'd0 : tick + 23'd1;
        if (sel == 2'd1 && fw) fcnt <= (tick_now && fcnt != 32'd0) ? 32'd1 : fcnt + 32'd1;
        else if (tick_now && fcnt != 32'd0) fcnt <= 32'd0;
        if (push) begin evq[ew] <= pv; ew <= ew + 10'd1; end
        if (!en) begin ew <= 10'd0; fcnt <= 32'd0; end
    end

    // ---------------------------------------------------------------- lines -> bytes
    function [7:0] hx;
        input [3:0] v;
        hx = v < 4'd10 ? 8'h30 + {4'd0, v} : 8'h37 + {4'd0, v};
    endfunction
    reg  [79:0] cur;
    reg   [5:0] k;                      // the character of the line, 0 idle
    reg  [79:0] evq_q;
    reg   [1:0] ld;
    always @(posedge clk) evq_q <= evq[er];
    reg   [7:0] ch;
    reg   [5:0] len;
    wire  [9:0] behind = ew - er;
    always @* begin
        len = 6'd2;
        ch = 8'h20;
        case (cur[79:78])
        2'd0: begin                     // Rooo dddddddd
            len = 6'd15;
            case (k)
            6'd1: ch = 8'h52;
            6'd2: ch = hx({2'b00, cur[71:70]}); 6'd3: ch = hx(cur[69:66]); 6'd4: ch = hx({cur[65:64], 2'b00});
            6'd5: ch = 8'h20; 6'd14: ch = 8'h0D; 6'd15: ch = 8'h0A;
            default: ch = hx(cur[32 + 4 * (13 - k) +: 4]);
            endcase
        end
        2'd1: begin                     // Fmm nnnnnnnn
            len = 6'd14;
            case (k)
            6'd1: ch = 8'h46; 6'd2: ch = hx(cur[71:68]); 6'd3: ch = hx(cur[67:64]); 6'd4: ch = 8'h20;
            6'd13: ch = 8'h0D; 6'd14: ch = 8'h0A;
            default: ch = hx(cur[32 + 4 * (12 - k) +: 4]);
            endcase
        end
        2'd2: begin                     // Dnnnnnnnn (lost events)
            len = 6'd11;
            case (k)
            6'd1: ch = 8'h44; 6'd10: ch = 8'h0D; 6'd11: ch = 8'h0A;
            default: ch = hx(cur[4 * (9 - k) +: 4]);
            endcase
        end
        default: begin                  // Eoooo aaaaaaaa vvvvvvvv
            len = 6'd25;
            case (k)
            6'd1: ch = 8'h45;
            6'd2: ch = hx({2'b00, cur[77:76]}); 6'd3: ch = hx(cur[75:72]); 6'd4: ch = hx(cur[71:68]); 6'd5: ch = hx(cur[67:64]);
            6'd6, 6'd15: ch = 8'h20;
            6'd24: ch = 8'h0D; 6'd25: ch = 8'h0A;
            default: ch = k < 6'd15 ? hx(cur[32 + 4 * (14 - k) +: 4]) : hx(cur[4 * (23 - k) +: 4]);
            endcase
        end
        endcase
    end
    reg   [7:0] bq [0:255];             // bytes to send
    reg   [7:0] bw, br;
    wire  [8:0] bn = {1'b0, bw} - {1'b0, br};
    always @(posedge clk) begin
        if (!en) begin k <= 6'd0; er <= 10'd0; bw <= 8'd0; ld <= 2'd0; lost <= 32'd0; end
        else if (k == 6'd0) begin
            if (lost != 32'd0 && bn < 9'd200) begin cur <= {2'd2, 46'd0, lost}; lost <= 32'd0; k <= 6'd1; end
            else if (behind > 10'd1000) begin             // lapped: skip to the newest 900
                lost <= lost + {22'd0, behind} - 32'd900; er <= ew - 10'd900; ld <= 2'd0;
            end else if (behind != 10'd0 && bn < 9'd200) begin
                if (ld == 2'd2) begin cur <= evq_q; er <= er + 10'd1; k <= 6'd1; ld <= 2'd0; end
                else ld <= ld + 2'd1;
            end else ld <= 2'd0;
        end else begin
            bq[bw] <= ch; bw <= bw + 8'd1;
            k <= k == len ? 6'd0 : k + 6'd1;
        end
    end

    // ---------------------------------------------------------------- UART, 115200 8N1
    localparam [15:0] DIV = CLK_HZ / 115200;
    reg  [15:0] bt;
    reg   [3:0] bi;                     // bit: 0 idle, 1 start, 2-9 data, 10 stop
    reg   [7:0] sh;
    reg   [7:0] bq_q;
    reg         bv;
    always @(posedge clk) bq_q <= bq[br];
    always @(posedge clk) begin
        bv <= 1'b0;
        if (!en) begin bi <= 4'd0; txd <= 1'b1; br <= 8'd0; end
        else if (bi == 4'd0) begin
            txd <= 1'b1;
            if (bn != 9'd0 && !bv) bv <= 1'b1;
            if (bv) begin sh <= bq_q; br <= br + 8'd1; bi <= 4'd1; bt <= 16'd0; txd <= 1'b0; end
        end else if (bt == DIV - 16'd1) begin
            bt <= 16'd0;
            if (bi == 4'd10) bi <= 4'd0;
            else begin
                bi <= bi + 4'd1;
                txd <= bi == 4'd9 ? 1'b1 : sh[bi[2:0] - 3'd1];
            end
        end else bt <= bt + 16'd1;
    end
endmodule
