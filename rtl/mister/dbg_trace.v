// Debug traces on the MiSTer UART in place of COM1 (OSD P5 "Serial port"), 8N1 at 892857 baud
// (`stty -F /dev/ttyS1 921600 raw; cat /dev/ttyS1` on the MiSTer; tools/tgatrace.sh): the HPS UART
// runs from 100 MHz, so its "921600" is 6.25 MHz / 7 = 892857, which this sends exactly (100 MHz / 112).
//
// sel = 1, the TGA trace: a line per TGA register write and per frame buffer write:
//   Qooo 00000000            a read of the copy buffer registers 000-01C / 100-11C (it ends a copy's drain-next state)
//   Rooo dddddddd            a register write: byte offset ooo (0x1F0 = RAMDAC, value RS<<9 | data;
//                            the cursor position writes, RS 12-15, are left out)
//   Wmm b oooooo dddddddd    a frame buffer write in mode mm: byte enables b, offset, data
// sel = 2, the CPU trace: a line per PAL entry (exception, interrupt, CALL_PAL):
//   Eoooo aaaaaaaa vvvvvvvv   PAL offset oooo, EXC_ADDR<31:0>, VA<31:0> (an arithmetic trap, 0060: the
//                            trapping instruction instead of VA)
// sel = 3, the CPU exceptions: the same lines without the frequent entries (ITB/DTB misses,
//   interrupts, and the CALL_PALs NT makes thousands of times a second: 06 08 09 0E 0F 1C 1E 3F,
//   86 83 AB), so arithmetic, unaligned, opcode and access faults, gentrap, bugcheck and reboot
//   all get through the UART; and a line per instruction retired outside PAL mode in the PC windows
//   RT_LO0..RT_HI0 and RT_LO1..RT_HI1 (default SRM's cb_open and fopen):
//   E3Cnn pppppppp vvvvvvvv   PC, the result's low half; nn = 20 + register if it wrote one
// Events go into a 4096-entry ring that overwrites the oldest: when the UART falls behind,
// the oldest are lost (a line "Dnnnnnnnn" counts them), so after a hang or a halt the last
// 4096 events before it are still sent.
module dbg_trace #(
    parameter CLK_HZ = 100000000,
    parameter [31:0] RT_LO0 = 32'h0003F430, RT_HI0 = 32'h0003FB48,
    parameter [31:0] RT_LO1 = 32'h0004A708, RT_HI1 = 32'h0004AC58
) (
    input  wire        clk,
    input  wire  [1:0] sel,             // 0 off, 1 TGA, 2 CPU, 3 CPU exceptions
    input  wire        rw,              // a TGA register write
    input  wire        rq,              // a read of the TGA's copy buffer registers (a Q line: Qooo)
    input  wire  [7:0] ri,              // its longword index
    input  wire [31:0] rd,
    input  wire        fw,              // a TGA frame buffer write
    input  wire [20:0] fa,              // its offset, data and byte enables
    input  wire [31:0] fd,
    input  wire  [3:0] fbe,
    input  wire  [7:0] mode,
    input  wire        ent,             // a PAL entry
    input  wire [13:0] ent_off,
    input  wire [31:0] ent_pc,          // EXC_ADDR<31:0>
    input  wire [31:0] ent_va,          // VA<31:0>
    input  wire        rt,              // a retired instruction
    input  wire        rt_pal,
    input  wire [63:0] rt_pc,
    input  wire        rt_wr,
    input  wire  [4:0] rt_num,
    input  wire [31:0] rt_val,
    input  wire        ne,              // a SCRIPTS trace event (with sel = 1: E3F0t lines, ncr53c810.v)
    input  wire  [3:0] ne_tag,
    input  wire [31:0] ne_a,
    input  wire [31:0] ne_b,
    output reg         txd,
    output reg         full             // the ring holds 3800+ events (the TGA throttle; the reader skips ahead at 4000)
);
    wire en = sel != 2'd0;

    // ---------------------------------------------------------------- events
    // {type 2: 0 R, 1 W, 3 E; a 14; d 32; e 32}; W: {1, 0, be 4, mode 8, 12 zero, offset 21, data 32}
    reg  [79:0] evq [0:4095];
    reg  [11:0] ew, er;                 // write, read (er chases ew; lapped -> skip ahead)
    reg  [31:0] lost;
    reg         push;
    reg  [79:0] pv;
    wire        hot = ent_off == 14'h03E0 || ent_off == 14'h08E0 || ent_off == 14'h09E0 || ent_off == 14'h00E0 ||
                      ent_off == 14'h2180 || ent_off == 14'h2200 || ent_off == 14'h2240 || ent_off == 14'h2380 ||
                      ent_off == 14'h23C0 || ent_off == 14'h2700 || ent_off == 14'h2780 || ent_off == 14'h2FC0 ||
                      ent_off == 14'h3180 || ent_off == 14'h30C0 || ent_off == 14'h3AC0;
    wire        rt_in = rt && !rt_pal && rt_pc[63:32] == 32'd0 &&
                        ((rt_pc[31:0] >= RT_LO0 && rt_pc[31:0] < RT_HI0) || (rt_pc[31:0] >= RT_LO1 && rt_pc[31:0] < RT_HI1));
    always @* begin
        push = 1'b0; pv = 80'd0;
        if (sel == 2'd1 && (rw || rq) && !(rw && ri == 8'h7C && rd[12:11] == 2'b11)) begin push = 1'b1; pv = {2'd0, rq, 5'd0, ri, rd, 32'd0}; end
        else if (sel == 2'd1 && fw) begin push = 1'b1; pv = {2'd1, 1'b0, fbe, mode, 12'd0, fa, fd}; end
        else if (sel == 2'd1 && ne) begin push = 1'b1; pv = {2'd3, 10'h3F0, ne_tag, ne_a, ne_b}; end
        else if ((sel == 2'd2 || (sel == 2'd3 && !hot)) && ent) begin push = 1'b1; pv = {2'd3, ent_off, ent_pc, ent_va}; end
        else if (sel == 2'd3 && rt_in) begin push = 1'b1; pv = {2'd3, 8'hF0, rt_wr, rt_num, rt_pc[31:0], rt_val}; end
    end
    always @(posedge clk) begin
        if (push) begin evq[ew] <= pv; ew <= ew + 12'd1; end
        if (!en) ew <= 12'd0;
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
    wire [11:0] behind = ew - er;
    always @(posedge clk) full <= en && behind >= 12'd3800;   // below the skip-ahead at 4000, with room for the TGA's queue
    always @* begin
        len = 6'd2;
        ch = 8'h20;
        case (cur[79:78])
        2'd0: begin                     // Rooo dddddddd
            len = 6'd15;
            case (k)
            6'd1: ch = cur[77] ? 8'h51 : 8'h52;       // Q: a copy buffer read
            6'd2: ch = hx({2'b00, cur[71:70]}); 6'd3: ch = hx(cur[69:66]); 6'd4: ch = hx({cur[65:64], 2'b00});
            6'd5: ch = 8'h20; 6'd14: ch = 8'h0D; 6'd15: ch = 8'h0A;
            default: ch = hx(cur[32 + 4 * (13 - k) +: 4]);
            endcase
        end
        2'd1: begin                     // Wmm b oooooo dddddddd
            len = 6'd23;
            case (k)
            6'd1: ch = 8'h57; 6'd2: ch = hx(cur[72:69]); 6'd3: ch = hx(cur[68:65]); 6'd4: ch = 8'h20;
            6'd5: ch = hx(cur[76:73]); 6'd6: ch = 8'h20;
            6'd7: ch = hx({3'b000, cur[52]}); 6'd8: ch = hx(cur[51:48]); 6'd9: ch = hx(cur[47:44]);
            6'd10: ch = hx(cur[43:40]); 6'd11: ch = hx(cur[39:36]); 6'd12: ch = hx(cur[35:32]);
            6'd13: ch = 8'h20; 6'd22: ch = 8'h0D; 6'd23: ch = 8'h0A;
            default: ch = hx(cur[4 * (21 - k) +: 4]);
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
        if (!en) begin k <= 6'd0; er <= 12'd0; bw <= 8'd0; ld <= 2'd0; lost <= 32'd0; end
        else if (k == 6'd0) begin
            if (lost != 32'd0 && bn < 9'd200) begin cur <= {2'd2, 46'd0, lost}; lost <= 32'd0; k <= 6'd1; end
            else if (behind > 12'd4000) begin             // lapped: skip to the newest 3600
                lost <= lost + {20'd0, behind} - 32'd3600; er <= ew - 12'd3600; ld <= 2'd0;
            end else if (behind != 12'd0 && bn < 9'd200) begin
                if (ld == 2'd2) begin cur <= evq_q; er <= er + 12'd1; k <= 6'd1; ld <= 2'd0; end
                else ld <= ld + 2'd1;
            end else ld <= 2'd0;
        end else begin
            bq[bw] <= ch; bw <= bw + 8'd1;
            k <= k == len ? 6'd0 : k + 6'd1;
        end
    end

    // ---------------------------------------------------------------- UART, 892857 8N1
    localparam [15:0] DIV = CLK_HZ / 892857;
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
