// The ZLXp-E1's RAMDAC: a Brooktree Bt485 behind the 21030's RAMDAC port
// (docs/design/tga.md 5). The 21030 side (rtl/tga/tga.v) hands over one
// register access at a time:
//   wr: RS (rs[3:0]) and the byte; rd: RS, the byte is in rdata the next cycle.
// Read side effects (the palette and cursor colour RGB counters, the cursor
// RAM address) happen on the rd strobe.
//
// Registers (RS): 0 address (palette write / cursor RAM low address),
// 1 palette data, 2 pixel read mask, 3 palette read address, 4 cursor colour
// write address, 5 cursor colour data, 6 CR0, 7 cursor colour read address,
// 8 CR1, 9 CR2, 10 status, or CR3 when CR0<7> = 1 and the address is 1,
// 11 cursor RAM data, 12-15 cursor X low/high, Y low/high.
//
// The cursor RAM address is {CR3<1:0>, address}, a 10-bit counter that steps
// on each cursor RAM access (plane 0 at 0-511, plane 1 at 512-1023, 8 bytes a
// row, bit 7 the leftmost pixel). The palette address steps after the blue
// byte. Palette and cursor RAM have a second copy read in the pixel clock
// domain (pal_a/pal_q, cur_a/cur_q0/cur_q1, one cycle).
module tga_bt485 (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr,
    input  wire        rd,
    input  wire  [3:0] rs,
    input  wire  [7:0] wdata,
    output reg   [7:0] rdata,

    // the pixel side (clk_pix)
    input  wire        clk_pix,
    input  wire        pix_en,          // read enable (the pixel pipeline's clock enable)
    input  wire  [7:0] pal_a,
    output reg  [23:0] pal_q,           // {R, G, B} as written
    input  wire  [8:0] cur_a,           // {row, byte}
    output reg   [7:0] cur_q0,          // plane 0
    output reg   [7:0] cur_q1,          // plane 1

    // static settings for the pixel side (change rarely; sampled there)
    output reg   [7:0] cr0,             // <1>: 8-bit DAC (else 6-bit values)
    output reg   [7:0] cr2,             // <1:0>: cursor mode (0 off, 1 three-colour, 2 XGA, 3 X11)
    output reg   [7:0] cr3,             // <2>: 64 x 64 cursor
    output reg   [7:0] pixmask,
    output reg  [95:0] curcol,          // cursor colours {3, 2, 1, 0 (overscan)}, {R, G, B} each
    output reg  [11:0] cur_x,
    output reg  [11:0] cur_y
);
    reg  [7:0] cr1;
    reg  [7:0] addr;                    // palette write address / cursor RAM low
    reg  [7:0] raddr;                   // palette read address
    reg  [1:0] wph, rph;                // RGB phases
    reg  [7:0] wr_r, wr_g;
    reg  [1:0] cc_wa, cc_ra;
    reg  [1:0] cc_wph, cc_rph;
    reg  [7:0] cc_r, cc_g;

    // palette: the pixel copy and the readback copy
    reg [23:0] pal_px [0:255];
    reg [23:0] pal_sy [0:255];
    reg [23:0] pal_rd;
    reg        pal_we;
    reg  [7:0] pal_wa;
    reg [23:0] pal_wd;
    always @(posedge clk) begin
        if (pal_we) pal_sy[pal_wa] <= pal_wd;
        pal_rd <= pal_sy[raddr];
    end
    always @(posedge clk) if (pal_we) pal_px[pal_wa] <= pal_wd;
    always @(posedge clk_pix) if (pix_en) pal_q <= pal_px[pal_a];

    // cursor RAM
    reg  [7:0] cram_p0 [0:511];
    reg  [7:0] cram_p1 [0:511];
    reg  [7:0] cram_sy [0:1023];
    reg  [7:0] cram_rd;
    wire [9:0] ca = {cr3[1:0], addr};
    reg        cram_we;
    reg  [9:0] cram_wa;
    reg  [7:0] cram_wd;
    always @(posedge clk) begin
        if (cram_we) cram_sy[cram_wa] <= cram_wd;
        cram_rd <= cram_sy[ca];
    end
    always @(posedge clk) if (cram_we && !cram_wa[9]) cram_p0[cram_wa[8:0]] <= cram_wd;
    always @(posedge clk) if (cram_we &&  cram_wa[9]) cram_p1[cram_wa[8:0]] <= cram_wd;
    always @(posedge clk_pix) if (pix_en) begin cur_q0 <= cram_p0[cur_a]; cur_q1 <= cram_p1[cur_a]; end

    wire ind3 = cr0[7] && addr == 8'h01;       // RS 10 is CR3

    always @(posedge clk) begin
        pal_we <= 1'b0; cram_we <= 1'b0;
        if (rst) begin
            cr0 <= 8'h00; cr1 <= 8'h00; cr2 <= 8'h00; cr3 <= 8'h00; pixmask <= 8'hFF;
            addr <= 8'h00; raddr <= 8'h00; wph <= 2'd0; rph <= 2'd0;
            cc_wa <= 2'd0; cc_ra <= 2'd0; cc_wph <= 2'd0; cc_rph <= 2'd0;
            cur_x <= 12'd0; cur_y <= 12'd0; curcol <= 96'd0; rdata <= 8'd0;
        end else if (wr) begin
            case (rs)
            4'd0: begin addr <= wdata; wph <= 2'd0; end
            4'd1: begin
                if (wph == 2'd0) begin wr_r <= wdata; wph <= 2'd1; end
                else if (wph == 2'd1) begin wr_g <= wdata; wph <= 2'd2; end
                else begin
                    pal_we <= 1'b1; pal_wa <= addr; pal_wd <= {wr_r, wr_g, wdata};
                    addr <= addr + 8'd1; wph <= 2'd0;
                end
            end
            4'd2: pixmask <= wdata;
            4'd3: begin raddr <= wdata; rph <= 2'd0; end
            4'd4: begin cc_wa <= wdata[1:0]; cc_wph <= 2'd0; end
            4'd5: begin
                if (cc_wph == 2'd0) begin cc_r <= wdata; cc_wph <= 2'd1; end
                else if (cc_wph == 2'd1) begin cc_g <= wdata; cc_wph <= 2'd2; end
                else begin
                    curcol[24*cc_wa +: 24] <= {cc_r, cc_g, wdata};
                    cc_wa <= cc_wa + 2'd1; cc_wph <= 2'd0;
                end
            end
            4'd6: cr0 <= wdata;
            4'd7: begin cc_ra <= wdata[1:0]; cc_rph <= 2'd0; end
            4'd8: cr1 <= wdata;
            4'd9: cr2 <= wdata;
            4'd10: if (ind3) cr3 <= wdata;
            4'd11: begin
                cram_we <= 1'b1; cram_wa <= ca; cram_wd <= wdata;
                {cr3[1:0], addr} <= ca + 10'd1;
            end
            4'd12: cur_x[7:0]  <= wdata;
            4'd13: cur_x[11:8] <= wdata[3:0];
            4'd14: cur_y[7:0]  <= wdata;
            4'd15: cur_y[11:8] <= wdata[3:0];
            endcase
        end else if (rd) begin
            case (rs)
            4'd0: rdata <= addr;
            4'd1: begin
                rdata <= rph == 2'd0 ? pal_rd[23:16] : rph == 2'd1 ? pal_rd[15:8] : pal_rd[7:0];
                if (rph == 2'd2) begin rph <= 2'd0; raddr <= raddr + 8'd1; end
                else rph <= rph + 2'd1;
            end
            4'd2: rdata <= pixmask;
            4'd3: rdata <= raddr;
            4'd4: rdata <= {6'd0, cc_wa};
            4'd5: begin
                rdata <= curcol[24*cc_ra + 8*(32'd2 - {30'd0, cc_rph}) +: 8];
                if (cc_rph == 2'd2) begin cc_rph <= 2'd0; cc_ra <= cc_ra + 2'd1; end
                else cc_rph <= cc_rph + 2'd1;
            end
            4'd6: rdata <= cr0;
            4'd7: rdata <= {6'd0, cc_ra};
            4'd8: rdata <= cr1;
            4'd9: rdata <= cr2;
            4'd10: rdata <= ind3 ? cr3 : 8'h00;  // status: no sense trip, ID 0
            4'd11: begin rdata <= cram_rd; {cr3[1:0], addr} <= ca + 10'd1; end
            4'd12: rdata <= cur_x[7:0];
            4'd13: rdata <= {4'd0, cur_x[11:8]};
            4'd14: rdata <= cur_y[7:0];
            4'd15: rdata <= {4'd0, cur_y[11:8]};
            endcase
        end
    end
endmodule
