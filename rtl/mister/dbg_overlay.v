// The video debug overlay (OSD P5 "Video debug"): a 6 x 42 character panel at the top left
// of the picture with the TGA's drawing state and the CPU's state, read live while a guest
// drives the card. Three fields a row, "LABL hhhhhhhh":
//   MODE mode         ROP  {pshift, rop}  DEEP deep
//   PMSK plane mask   PXM  pixel mask     PXOS 1 = it was written one-shot
//   FG   foreground   BG   background     VVBR video base
//   BT03 {CR0, CR2, CR3, pixel mask}       CURS {X, Y}       FBWR frame buffer writes
//   PCHI / PCLO the last retired PC        PALI {PAL mode, irq_h}
//   LREG the last register written (byte offset), LDAT its value, RCNT register writes
// The values come from the system clock domain and are shown as they are (quasi-static).
// The picture is delayed 3 pixels through the panel's pipeline (character, font row, pixel).
module dbg_overlay #(
    parameter FONT = "rtl/mister/font8x16.hex"
) (
    input  wire        clk,             // the pixel clock
    input  wire        ce,
    input  wire        en,
    input  wire [575:0] fields,         // 18 x 32 bits, field 0 in the low bits
    input  wire        hs_i, vs_i, de_i, hb_i, vb_i,
    input  wire  [7:0] r_i, g_i, b_i,
    output reg         hs, vs, de, hblank, vblank,
    output reg   [7:0] r, g, b
);
    localparam X0 = 16, Y0 = 16;        // the panel's top left (pixels)
    localparam [8*90-1:0] LABELS = "MODE ROP  DEEP PMSK PXM  PXOS FG   BG   VVBR BT03 CURS FBWR PCHI PCLO PALI LREG LDAT RCNT ";

    reg  [7:0] font [0:2047];
    initial $readmemh(FONT, font);

    // the beam
    reg [11:0] x, y;
    reg        de_q, vs_q;
    always @(posedge clk) if (ce) begin
        de_q <= de_i; vs_q <= vs_i;
        if (de_i) x <= x + 12'd1; else x <= 12'd0;
        if (!de_i && de_q) y <= y + 12'd1;
        if (vs_i && !vs_q) y <= 12'd0;
    end

    // stage 1: the character under the beam
    wire [11:0] px = x - X0, py = y - Y0;
    wire        inp = en && x >= X0 && x < X0 + 42 * 8 && y >= Y0 && y < Y0 + 6 * 16;
    reg   [5:0] col;
    reg   [3:0] pos;                    // the position in the field (0-13)
    reg   [1:0] fc;                     // the field in the row (0-2)
    always @* begin
        col = px[8:3];
        fc  = col >= 6'd28 ? 2'd2 : col >= 6'd14 ? 2'd1 : 2'd0;
        pos = col - (fc == 2'd2 ? 6'd28 : fc == 2'd1 ? 6'd14 : 6'd0);
    end
    wire  [4:0] fi = py[6:4] * 3 + fc;  // the field (0-17)
    wire [31:0] fv = fields[32 * fi +: 32];
    function [7:0] hx;
        input [3:0] v;
        hx = v < 4'd10 ? 8'h30 + {4'd0, v} : 8'h37 + {4'd0, v};
    endfunction
    reg  [7:0] ch;
    always @* begin
        if (pos < 4'd4) ch = LABELS[8 * (89 - (fi * 5 + pos)) +: 8];
        else if (pos >= 4'd5 && pos <= 4'd12) ch = hx(fv[4 * (12 - pos) +: 4]);
        else ch = 8'h20;
    end
    reg  [7:0] ch1;
    reg  [3:0] fy1;
    reg  [2:0] fx1, fx2;
    reg        in1, in2;
    reg  [7:0] bits;
    // the picture, delayed to line up with the panel
    reg  [28:0] v1, v2, v3;
    always @(posedge clk) if (ce) begin
        ch1 <= ch; fy1 <= py[3:0]; fx1 <= px[2:0]; in1 <= inp;
        bits <= font[{ch1[6:0], fy1}]; fx2 <= fx1; in2 <= in1;
        v1 <= {hs_i, vs_i, de_i, hb_i, vb_i, r_i, g_i, b_i};
        v2 <= v1; v3 <= v2;
        {hs, vs, de, hblank, vblank} <= v2[28:24];
        if (in2) {r, g, b} <= bits[3'd7 - fx2] ? 24'hFFFF00 : 24'h000040;
        else {r, g, b} <= v2[23:0];
    end
endmodule
