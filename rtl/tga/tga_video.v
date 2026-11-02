// The TGA's display path (docs/design/tga.md 6): the line fetch from VRAM
// (system clock, through rtl/mister/ddr3_arb.v sc_*) into a double line
// buffer, and the beam (pixel clock) with the Bt485's palette and hardware
// cursor.
//
// Mode: the 21030's video timing registers. Horizontal (VHCR): active/4
// <8:0> (+ <29:28> as bits 10:9), front porch/4 <13:9>, sync/4 <20:14>, back
// porch/4 <27:21>, odd <31> (4 more pixels of front porch); vertical (VVCR):
// lines <10:0>, front porch <15:11>, sync <21:16>, back porch <27:22>. The
// ICS1562 is not modelled: the pixel clock is clk_pix and ce_pix runs at
// htotal x vtotal x 60 Hz (every clk_pix cycle when that is more than clk_pix,
// e.g. 1024x768: 1344 x 810 x 60 = 65.3 MHz on 65 MHz).
//
// Line n starts at VRAM byte base + n x active (8 bits a pixel, linear);
// lines need not be quadword aligned (SRM's 1028-pixel lines are not). The
// beam asks for line n+1 at the start of line n (and line 0 at the start of
// the last line of the frame), so a fetch has a whole line time; up to 2040
// pixels a line are fetched.
//
// Sync pulses are active high (the MiSTer video path takes either polarity).
module tga_video (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] vhcr,
    input  wire [31:0] vvcr,
    input  wire [20:0] base,            // VRAM byte of line 0
    input  wire        vvalid,          // VVVR<0>
    input  wire        vblnk,           // VVVR<1>
    output reg         eof,             // a pulse at the end of each frame's active lines

    // display fetch (ddr3_arb sc_*)
    output reg         sc_req,
    output reg  [17:0] sc_addr,
    output reg   [5:0] sc_len,
    input  wire        sc_ack,
    input  wire        sc_rvalid,
    input  wire [63:0] sc_rdata,

    // the pixel side
    input  wire        clk_pix,
    output reg         pix_en,          // the pixel pipeline's clock enable (the RAMs' read enable)
    output reg   [7:0] pal_a,
    input  wire [23:0] pal_q,
    output reg   [8:0] cur_a,
    input  wire  [7:0] cur_q0,
    input  wire  [7:0] cur_q1,
    input  wire  [7:0] cr0,
    input  wire  [7:0] cr2,
    input  wire  [7:0] cr3,             // <2>: 64 x 64 cursor, else 32 x 32
    input  wire  [7:0] pixmask,
    input  wire [95:0] curcol,
    input  wire [11:0] cur_x,
    input  wire [11:0] cur_y,

    output reg         ce_pix,
    output reg         hs,
    output reg         vs,
    output reg         de,
    output reg         hblank,
    output reg         vblank,
    output reg   [7:0] r,
    output reg   [7:0] g,
    output reg   [7:0] b
);
    // ------------------------------------------------------------ the mode (system clock)
    reg [12:0] t_hact, t_hss, t_hse, t_htot;
    reg [10:0] t_vact, t_vss, t_vse, t_vtot;
    reg [10:0] t_hfetch;                // pixels fetched a line (<= 2040)
    reg [23:0] t_area;                  // htotal x vtotal
    reg [35:0] t_prod;
    reg [16:0] t_inc;                   // ce_pix rate, 1/65536ths of clk_pix
    wire [12:0] hact_w = {vhcr[29:28], vhcr[8:0], 2'b00};
    always @(posedge clk) begin
        t_hact <= hact_w;
        t_hss  <= hact_w + {6'd0, vhcr[13:9], 2'b00} + {10'd0, vhcr[31], 2'b00};
        t_hse  <= t_hss + {4'd0, vhcr[20:14], 2'b00};
        t_htot <= t_hse + {4'd0, vhcr[27:21], 2'b00};
        t_vact <= vvcr[10:0];
        t_vss  <= vvcr[10:0] + {6'd0, vvcr[15:11]};
        t_vse  <= t_vss + {5'd0, vvcr[21:16]};
        t_vtot <= t_vse + {5'd0, vvcr[27:22]};
        t_hfetch <= hact_w > 13'd2040 ? 11'd2040 : hact_w[10:0];
        t_area <= t_htot * {2'd0, t_vtot};
        t_prod <= {12'd0, t_area} * 36'd3965;       // 60 x 65536 / 65e6 = 3964.9 / 65536
        t_inc  <= t_prod[35:32] != 4'd0 ? 17'h10000 : t_prod[32:16];
    end
    wire mode_ok = vvalid && t_hact != 13'd0 && t_vact != 11'd0 && t_htot > t_hact && t_vtot > t_vact;

    // ------------------------------------------------------------ line buffer (2 x 256 quadwords)
    reg [63:0] lbuf [0:511];
    reg        lb_we;
    reg  [8:0] lb_wa;
    reg [63:0] lb_wd;
    reg  [8:0] lb_ra;
    reg [63:0] lb_q;
    always @(posedge clk) if (lb_we) lbuf[lb_wa] <= lb_wd;
    always @(posedge clk_pix) if (pix_en) lb_q <= lbuf[lb_ra];
    reg  [2:0] off_h0, off_h1;          // each half's first pixel within its first quadword

    // ------------------------------------------------------------ fetch (system clock)
    reg        px_req_t;                // pixel side: toggles for each line wanted
    reg [10:0] px_req_line;
    reg  [2:0] rq_s;
    reg        px_eof_t;
    reg  [2:0] eof_s;
    reg [20:0] la;                      // the line's first byte
    reg        f_half;
    reg  [8:0] f_left;                  // quadwords still to ask for
    reg  [7:0] f_wi;                    // next line buffer word
    reg  [5:0] f_pend;                  // beats of the burst in flight
    reg        f_busy;
    wire [10:0] f_end;                  // the line's last byte from its first quadword
    wire [20:0] la_next = px_req_line == 11'd0 ? base : la + {8'd0, t_hact};
    assign f_end = {8'd0, la_next[2:0]} + t_hfetch - 11'd1;

    always @(posedge clk) begin
        rq_s <= {rq_s[1:0], px_req_t};
        eof_s <= {eof_s[1:0], px_eof_t};
        eof <= eof_s[2] ^ eof_s[1];
        lb_we <= 1'b0;
        if (rst) begin
            sc_req <= 1'b0; f_busy <= 1'b0; f_pend <= 6'd0; la <= 21'd0;
        end else begin
            if (rq_s[2] ^ rq_s[1]) begin
                // a new line (the previous fetch is long done)
                la <= la_next; f_half <= px_req_line[0];
                if (px_req_line[0]) off_h1 <= la_next[2:0]; else off_h0 <= la_next[2:0];
                f_left <= {1'b0, f_end[10:3]} + 9'd1;
                f_wi <= 8'd0; f_busy <= mode_ok; sc_addr <= la_next[20:3];
            end else if (f_busy) begin
                if (!sc_req && f_pend == 6'd0) begin
                    if (f_left == 9'd0) f_busy <= 1'b0;
                    else begin
                        sc_req <= 1'b1;
                        sc_len <= f_left > 9'd32 ? 6'd32 : f_left[5:0];
                    end
                end
                if (sc_ack) begin
                    sc_req <= 1'b0; f_pend <= sc_len;
                    f_left <= f_left - {3'd0, sc_len}; sc_addr <= sc_addr + {12'd0, sc_len};
                end
            end
            if (sc_rvalid) begin
                lb_we <= 1'b1; lb_wa <= {f_half, f_wi}; lb_wd <= sc_rdata;
                f_wi <= f_wi + 8'd1; f_pend <= f_pend - 6'd1;
            end
        end
    end

    // ------------------------------------------------------------ the beam (pixel clock)
    // the mode, sampled (changes rarely)
    reg [12:0] p_hact, p_hss, p_hse, p_htot;
    reg [10:0] p_vact, p_vss, p_vse, p_vtot;
    reg [16:0] p_inc;
    reg  [1:0] p_ok, p_blnk;
    always @(posedge clk_pix) begin
        p_hact <= t_hact; p_hss <= t_hss; p_hse <= t_hse; p_htot <= t_htot;
        p_vact <= t_vact; p_vss <= t_vss; p_vse <= t_vse; p_vtot <= t_vtot;
        p_inc <= t_inc;
        p_ok <= {p_ok[0], mode_ok}; p_blnk <= {p_blnk[0], vblnk};
    end

    reg [16:0] acc;
    always @(posedge clk_pix) begin
        if (p_inc[16]) begin pix_en <= 1'b1; acc <= 17'd0; end
        else {pix_en, acc[15:0]} <= {1'b0, acc[15:0]} + {1'b0, p_inc[15:0]};
    end

    reg [12:0] hc;
    reg [10:0] vc;
    // the pipeline, one stage a pix_en: A addresses, B line buffer and cursor
    // RAM, C pixel and cursor bits, D palette RAM, E output
    reg  [4:0] sa, sb, sc, sd;          // {act, hblank, vblank, hsync, vsync}
    reg  [2:0] sa_byte, sb_byte, sa_cx, sb_cx;
    reg        sa_cin, sb_cin;
    reg  [1:0] sc_cur, sd_cur;

    // the cursor's top-left: the Bt485 position less its size (64 or 32)
    wire [12:0] csz = cr3[2] ? 13'd64 : 13'd32;
    wire [12:0] cxo = {1'b0, cur_x} - csz;
    wire [12:0] cyo = {1'b0, cur_y} - csz;
    wire [12:0] cdx = hc - cxo;
    wire [12:0] cdy = {2'd0, vc} - cyo;
    wire        cin = cr2[1:0] != 2'd0 && cdx < csz && cdy < csz;
    wire [11:0] bi  = {9'd0, vc[0] ? off_h1 : off_h0} + hc[11:0];
    wire  [1:0] cbits = {cur_q1[3'd7 - sb_cx], cur_q0[3'd7 - sb_cx]};

    function [7:0] dac;                 // 6-bit DAC values when CR0<1> = 0
        input [7:0] v; input eight;
        dac = eight ? v : {v[5:0], v[5:4]};
    endfunction

    always @(posedge clk_pix) begin
        ce_pix <= pix_en;
        if (pix_en) begin
            // counters
            if (!p_ok[1]) begin hc <= 13'd0; vc <= 11'd0; end
            else if (hc + 13'd1 >= p_htot) begin
                hc <= 13'd0;
                vc <= (vc + 11'd1 >= p_vtot) ? 11'd0 : vc + 11'd1;
            end else hc <= hc + 13'd1;
            // ask for the next line at the start of each line
            if (p_ok[1] && hc == 13'd0) begin
                if (vc + 11'd1 >= p_vtot) begin px_req_line <= 11'd0; px_req_t <= ~px_req_t; end
                else if (vc + 11'd1 < p_vact) begin px_req_line <= vc + 11'd1; px_req_t <= ~px_req_t; end
                if (vc == p_vact) px_eof_t <= ~px_eof_t;
            end

            // A
            sa <= {p_ok[1] && hc < p_hact && vc < p_vact && hc < 13'd2040,
                   !p_ok[1] || hc >= p_hact, !p_ok[1] || vc >= p_vact,
                   p_ok[1] && hc >= p_hss && hc < p_hse, p_ok[1] && vc >= p_vss && vc < p_vse};
            lb_ra   <= {vc[0], bi[10:3]};
            sa_byte <= bi[2:0];
            sa_cin  <= cin;
            sa_cx   <= cdx[2:0];
            cur_a   <= {cdy[5:0], cdx[5:3]};
            // B (the RAMs)
            sb <= sa; sb_byte <= sa_byte; sb_cin <= sa_cin; sb_cx <= sa_cx;
            // C
            sc <= sb;
            pal_a <= lb_q[8*sb_byte +: 8] & pixmask;
            // the cursor's colour index (0: show the pixel) by CR2<1:0>
            if (!sb_cin) sc_cur <= 2'd0;
            else case (cr2[1:0])
            2'd1:    sc_cur <= cbits;                                       // three-colour
            2'd2:    sc_cur <= cbits == 2'd2 ? 2'd0 : cbits + 2'd1;        // XGA (3, complement, shows colour 3)
            2'd3:    sc_cur <= cbits[1] ? 2'd1 + {1'b0, cbits[0]} : 2'd0;  // X11
            default: sc_cur <= 2'd0;
            endcase
            // D (the palette)
            sd <= sc; sd_cur <= sc_cur;
            // E
            hs <= sd[1]; vs <= sd[0]; hblank <= sd[3]; vblank <= sd[2]; de <= !sd[3] && !sd[2];
            if (!sd[4] || p_blnk[1]) begin r <= 8'd0; g <= 8'd0; b <= 8'd0; end
            else if (sd_cur != 2'd0) begin
                r <= dac(curcol[24*sd_cur + 16 +: 8], cr0[1]);
                g <= dac(curcol[24*sd_cur + 8 +: 8], cr0[1]);
                b <= dac(curcol[24*sd_cur +: 8], cr0[1]);
            end else begin
                r <= dac(pal_q[23:16], cr0[1]); g <= dac(pal_q[15:8], cr0[1]); b <= dac(pal_q[7:0], cr0[1]);
            end
        end
    end
endmodule
