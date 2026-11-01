// The serial console on the MiSTer's screen: a 128x48 text terminal on a
// 1024x768 @ 60 Hz raster (VESA, 65 MHz pixel clock, both syncs negative).
// It shows what COM1 transmits while the machine has no graphics console
// (bring-up, OSD Display = Serial console).
//
// Write side (clk): one character per in_stb. CR, LF, BS, TAB, BEL and a
// small VT100 subset (ESC [ n;m H / f, ESC [ n J, ESC [ n K, ESC [ ... m and
// other CSI sequences ignored); characters past column 127 wrap. Bytes are
// queued in a 32-entry FIFO, so a screen clear (6144 writes) never loses
// input at serial rates.
//
// Video side (clk_pix): the text RAM is a dual-clock BRAM of 64 rows x 128
// columns; the screen shows 48 of them starting at row `top`, so a scroll is
// one register change plus clearing the new bottom row.
module vterm #(
    parameter FONT = "rtl/mister/font8x16.hex"    // relative to the Quartus project
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       in_stb,
    input  wire [7:0] in_byte,

    input  wire       clk_pix,
    output reg        hs,
    output reg        vs,
    output reg        de,
    output reg        hblank,
    output reg        vblank,
    output reg  [7:0] r,
    output reg  [7:0] g,
    output reg  [7:0] b
);
    localparam COLS = 128, ROWS = 48;

    // ------------------------------------------------------------ input FIFO
    reg [7:0] fifo [0:31];
    reg [4:0] f_wr, f_rd;
    wire      f_any = f_wr != f_rd;
    always @(posedge clk) begin
        if (rst) f_wr <= 5'd0;
        else if (in_stb && (f_wr + 5'd1) != f_rd) begin
            fifo[f_wr] <= in_byte;
            f_wr <= f_wr + 5'd1;
        end
    end

    // ------------------------------------------------------------ text RAM
    reg  [7:0] text [0:8191];          // {row[5:0], col[6:0]}
    reg        t_we;
    reg [12:0] t_wa;
    reg  [7:0] t_wd;
    always @(posedge clk) if (t_we) text[t_wa] <= t_wd;

    // ------------------------------------------------------------ writer
    reg  [6:0] cx;                     // cursor column
    reg  [5:0] cy;                     // cursor row on the screen, 0..47
    reg  [5:0] top;                    // RAM row shown on screen row 0
    reg  [1:0] esc;                    // 0 normal, 1 after ESC, 2 in CSI
    reg  [7:0] p0, p1;                 // CSI parameters
    reg        p_second;

    // clearing: from screen position (cl_y, cl_x) up to and including (cl_ey, 127)
    reg        clr;
    reg  [5:0] cl_y, cl_ey;
    reg  [6:0] cl_x;

    wire [5:0] ram_row = top + cy;     // 6-bit wrap = modulo 64

    always @(posedge clk) begin
        t_we <= 1'b0;
        if (rst) begin
            f_rd <= 5'd0; cx <= 7'd0; cy <= 6'd0; top <= 6'd0; esc <= 2'd0;
            // clear the whole RAM-visible screen at start
            clr <= 1'b1; cl_y <= 6'd0; cl_x <= 7'd0; cl_ey <= ROWS - 1;
        end else if (clr) begin
            t_we <= 1'b1;
            t_wa <= {top + cl_y, cl_x};
            t_wd <= 8'h20;
            cl_x <= cl_x + 7'd1;
            if (cl_x == COLS - 1) begin
                cl_y <= cl_y + 6'd1;
                if (cl_y == cl_ey) clr <= 1'b0;
            end
        end else if (f_any) begin : put
            reg [7:0] c;
            c = fifo[f_rd[4:0]];
            f_rd <= f_rd + 5'd1;
            case (esc)
            2'd1: begin
                if (c == 8'h5B) begin esc <= 2'd2; p0 <= 8'd0; p1 <= 8'd0; p_second <= 1'b0; end
                else esc <= 2'd0;
            end
            2'd2: begin
                if (c >= 8'h30 && c <= 8'h39) begin
                    if (p_second) p1 <= p1 * 8'd10 + (c - 8'h30);
                    else          p0 <= p0 * 8'd10 + (c - 8'h30);
                end else if (c == 8'h3B) p_second <= 1'b1;
                else if (c == 8'h3F) ;                            // DEC private marker
                else begin
                    esc <= 2'd0;
                    case (c)
                    8'h48, 8'h66: begin                           // CUP: row;col, 1-based
                        cy <= (p0 == 8'd0) ? 6'd0 : (p0 > ROWS) ? ROWS - 1 : p0 - 8'd1;
                        cx <= (p1 == 8'd0) ? 7'd0 : (p1 > COLS) ? COLS - 1 : p1 - 8'd1;
                    end
                    8'h4A: begin                                  // ED
                        clr <= 1'b1; cl_ey <= ROWS - 1;
                        if (p0 == 8'd2) begin cl_y <= 6'd0; cl_x <= 7'd0; end
                        else begin cl_y <= cy; cl_x <= cx; end
                    end
                    8'h4B: begin                                  // EL (to end of line)
                        clr <= 1'b1; cl_y <= cy; cl_ey <= cy;
                        cl_x <= (p0 == 8'd2) ? 7'd0 : cx;
                    end
                    default: ;                                    // SGR and the rest: ignored
                    endcase
                end
            end
            default: begin
                case (c)
                8'h1B: esc <= 2'd1;
                8'h0D: cx <= 7'd0;
                8'h0A: begin
                    if (cy == ROWS - 1) begin
                        // scroll: the RAM row after the screen becomes the bottom row
                        top  <= top + 6'd1;
                        clr  <= 1'b1; cl_y <= ROWS - 1; cl_ey <= ROWS - 1; cl_x <= 7'd0;
                    end else cy <= cy + 6'd1;
                end
                8'h08: if (cx != 7'd0) cx <= cx - 7'd1;
                8'h09: cx <= (cx >= COLS - 8) ? COLS - 1 : {cx[6:3] + 4'd1, 3'b000};
                default: if (c >= 8'h20 && c != 8'h7F) begin
                    t_we <= 1'b1;
                    t_wa <= {ram_row, cx};
                    t_wd <= c;
                    if (cx == COLS - 1) begin
                        cx <= 7'd0;
                        if (cy == ROWS - 1) begin
                            top <= top + 6'd1;
                            clr <= 1'b1; cl_y <= ROWS - 1; cl_ey <= ROWS - 1; cl_x <= 7'd0;
                        end else cy <= cy + 6'd1;
                    end else cx <= cx + 7'd1;
                end
                endcase
            end
            endcase
        end
    end

    // ------------------------------------------------------------ raster
    // 1024x768 @ 60: H 1024 + 24 + 136 + 160 = 1344, V 768 + 3 + 6 + 29 = 806
    reg [10:0] hc;
    reg  [9:0] vc;
    always @(posedge clk_pix) begin
        if (hc == 11'd1343) begin
            hc <= 11'd0;
            vc <= (vc == 10'd805) ? 10'd0 : vc + 10'd1;
        end else hc <= hc + 11'd1;
    end

    // the cursor and `top` cross from clk: quasi-static, two flops
    reg [5:0] top_s0, top_s1, cy_s0, cy_s1;
    reg [6:0] cx_s0, cx_s1;
    always @(posedge clk_pix) begin
        top_s0 <= top; top_s1 <= top_s0;
        cy_s0  <= cy;  cy_s1  <= cy_s0;
        cx_s0  <= cx;  cx_s1  <= cx_s0;
    end

    reg [5:0] blink;                   // frames; the cursor blinks at ~1 Hz
    always @(posedge clk_pix) if (hc == 11'd0 && vc == 10'd0) blink <= blink + 6'd1;

    reg  [7:0] font [0:2047];          // 128 glyphs x 16 rows
    initial $readmemh(FONT, font);

    // three stages: character, font row, pixel
    wire [5:0] srow = vc[9:4];
    reg  [7:0] ch;
    reg  [7:0] bits;
    reg  [3:0] fy1;
    reg  [2:0] px1, px2;
    reg        act1, act2, cur1, cur2;
    reg        hs1, hs2, vs1, vs2, hb1, hb2, vb1, vb2;
    always @(posedge clk_pix) begin
        // stage 1
        ch   <= text[{top_s1 + srow, hc[9:3]}];
        fy1  <= vc[3:0];
        px1  <= hc[2:0];
        act1 <= hc < 11'd1024 && vc < 10'd768;
        cur1 <= blink[5] && srow == cy_s1 && hc[9:3] == cx_s1 && vc[3:0] >= 4'd14;
        hs1  <= !(hc >= 11'd1048 && hc < 11'd1184);
        vs1  <= !(vc >= 10'd771 && vc < 10'd777);
        hb1  <= hc >= 11'd1024;
        vb1  <= vc >= 10'd768;
        // stage 2
        bits <= font[{ch[6:0], fy1}];
        px2 <= px1; act2 <= act1; cur2 <= cur1;
        hs2 <= hs1; vs2 <= vs1; hb2 <= hb1; vb2 <= vb1;
        // stage 3
        hs <= hs2; vs <= vs2; hblank <= hb2; vblank <= vb2; de <= act2;
        if (act2 && (bits[3'd7 - px2] || cur2)) begin
            r <= 8'hC0; g <= 8'hC0; b <= 8'hC0;
        end else begin
            r <= 8'h00; g <= 8'h00; b <= 8'h00;
        end
    end
endmodule
