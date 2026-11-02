// The TGA trace on the MiSTer UART (OSD P5 "Serial port: TGA trace"; in place of COM1):
// one text line per TGA register write and, every 50 ms, the frame buffer writes since
// the last report, for watching what a guest's display driver does on the board
// (`stty -F /dev/ttyS1 <speed> raw; cat /dev/ttyS1` on the MiSTer). Lines:
//   Rooo dddddddd    a register write: byte offset ooo (0x1F0 = RAMDAC, value RS<<9 | data)
//   Fmm nnnnnnnn     nnnnnnnn frame buffer writes, the mode now mm
//   Dnnnnnnnn        nnnnnnnn events dropped (the UART could not keep up)
// 8N1 at the speed picked in the MiSTer's UART menu (uart_speed from hps_io).
module dbg_trace #(
    parameter CLK_HZ = 100000000
) (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] speed,           // bits/s (hps_io uart_speed)
    input  wire        rw,              // a TGA register write
    input  wire  [7:0] ri,              // its longword index
    input  wire [31:0] rd,
    input  wire        fw,              // a TGA frame buffer write
    input  wire  [7:0] mode,
    output reg         txd
);
    // ---------------------------------------------------------------- events
    // {type 2: 0 R, 1 F, 2 D; a 8; d 32}
    reg  [41:0] evq [0:255];
    reg   [7:0] ew, er;
    wire  [8:0] en_q = {1'b0, ew} - {1'b0, er};
    wire        ev_full = en_q[7:0] == 8'hFF;
    reg  [31:0] fcnt, drops;
    reg  [22:0] tick;
    wire        tick_now = tick == CLK_HZ / 20 - 1;
    always @(posedge clk) begin
        tick <= tick_now ? 23'd0 : tick + 23'd1;
        if (fw && en) fcnt <= fcnt + 32'd1;
        if (rw && en) begin
            if (!ev_full) begin evq[ew] <= {2'd0, ri, rd}; ew <= ew + 8'd1; end
            else drops <= drops + 32'd1;
        end else if (tick_now && en && fcnt != 32'd0 && !ev_full) begin
            evq[ew] <= {2'd1, mode, fcnt}; ew <= ew + 8'd1;
            fcnt <= fw ? 32'd1 : 32'd0;
        end else if (tick == 23'd1 && en && drops != 32'd0 && !ev_full) begin
            evq[ew] <= {2'd2, 8'd0, drops}; ew <= ew + 8'd1; drops <= 32'd0;
        end
        if (!en) begin ew <= 8'd0; fcnt <= 32'd0; drops <= 32'd0; end
    end

    // ---------------------------------------------------------------- lines -> bytes
    function [7:0] hx;
        input [3:0] v;
        hx = v < 4'd10 ? 8'h30 + {4'd0, v} : 8'h37 + {4'd0, v};
    endfunction
    reg  [41:0] cur;
    reg   [4:0] k;                      // the character of the line, 0 idle
    reg  [41:0] evq_q;
    reg         ld;
    always @(posedge clk) evq_q <= evq[er];
    reg   [7:0] bq [0:1023];            // bytes to send
    reg   [9:0] bw, br;
    wire [10:0] bn = {1'b0, bw} - {1'b0, br};
    reg   [7:0] ch;
    reg   [4:0] len;
    always @* begin
        len = cur[41:40] == 2'd0 ? 5'd15 : cur[41:40] == 2'd1 ? 5'd14 : 5'd11;
        ch = 8'h20;
        case (cur[41:40])
        2'd0: case (k)                  // Rooo dddddddd
            5'd1: ch = 8'h52;
            5'd2: ch = hx({2'b00, cur[39:38]}); 5'd3: ch = hx(cur[37:34]); 5'd4: ch = hx({cur[33:32], 2'b00});
            5'd5: ch = 8'h20;
            5'd14: ch = 8'h0D; 5'd15: ch = 8'h0A;
            default: ch = hx(cur[4 * (13 - k) +: 4]);
            endcase
        2'd1: case (k)                  // Fmm nnnnnnnn
            5'd1: ch = 8'h46; 5'd2: ch = hx(cur[39:36]); 5'd3: ch = hx(cur[35:32]); 5'd4: ch = 8'h20;
            5'd13: ch = 8'h0D; 5'd14: ch = 8'h0A;
            default: ch = hx(cur[4 * (12 - k) +: 4]);
            endcase
        default: case (k)               // Dnnnnnnnn
            5'd1: ch = 8'h44; 5'd10: ch = 8'h0D; 5'd11: ch = 8'h0A;
            default: ch = hx(cur[4 * (9 - k) +: 4]);
            endcase
        endcase
    end
    always @(posedge clk) begin
        ld <= 1'b0;
        if (!en) begin k <= 5'd0; er <= 8'd0; bw <= 10'd0; end
        else if (k == 5'd0) begin
            if (en_q != 9'd0 && bn < 11'd1000 && !ld) begin ld <= 1'b1; end
            if (ld) begin cur <= evq_q; er <= er + 8'd1; k <= 5'd1; end
        end else begin
            bq[bw] <= ch; bw <= bw + 10'd1;
            k <= k == len ? 5'd0 : k + 5'd1;
        end
    end

    // ---------------------------------------------------------------- UART
    reg  [31:0] div;                    // clocks a bit (speed from the MiSTer's menu)
    always @(posedge clk)
        case (speed)
        32'd9600:    div <= CLK_HZ / 9600;
        32'd19200:   div <= CLK_HZ / 19200;
        32'd38400:   div <= CLK_HZ / 38400;
        32'd57600:   div <= CLK_HZ / 57600;
        32'd230400:  div <= CLK_HZ / 230400;
        32'd460800:  div <= CLK_HZ / 460800;
        32'd921600:  div <= CLK_HZ / 921600;
        default:     div <= CLK_HZ / 115200;
        endcase
    reg  [31:0] bt;
    reg   [3:0] bi;                     // bit: 0 idle, 1 start, 2-9 data, 10 stop
    reg   [7:0] sh;
    reg   [7:0] bq_q;
    always @(posedge clk) bq_q <= bq[br];
    reg         bv;
    always @(posedge clk) begin
        bv <= 1'b0;
        if (!en) begin bi <= 4'd0; txd <= 1'b1; br <= 10'd0; end
        else if (bi == 4'd0) begin
            txd <= 1'b1;
            if (bn != 11'd0 && !bv) bv <= 1'b1;
            if (bv) begin sh <= bq_q; br <= br + 10'd1; bi <= 4'd1; bt <= 32'd0; txd <= 1'b0; end
        end else if (bt == div - 32'd1) begin
            bt <= 32'd0;
            if (bi == 4'd10) bi <= 4'd0;
            else begin
                bi <= bi + 4'd1;
                txd <= bi == 4'd9 ? 1'b1 : sh[bi - 4'd1];
            end
        end else bt <= bt + 32'd1;
    end
endmodule
