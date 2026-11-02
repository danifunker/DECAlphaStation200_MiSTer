// The picture the MiSTer shows (clk_pix): the TGA when Display = Graphics
// and the TGA drives a picture (its VVVR<0> and a mode, tga_on from the
// system clock), the serial console terminal (rtl/mister/vterm.v, a pixel
// every clock) otherwise. Registered outputs.
module tga_vsel (
    input  wire       clk_pix,
    input  wire       gfx,              // OSD Display = Graphics
    input  wire       tga_on,           // (system clock) tga.v video_on

    input  wire       t_ce, t_hs, t_vs, t_de, t_hb, t_vb,
    input  wire [7:0] t_r, t_g, t_b,
    input  wire       v_hs, v_vs, v_de, v_hb, v_vb,
    input  wire [7:0] v_r, v_g, v_b,

    output reg        ce, hs, vs, de, hblank, vblank,
    output reg  [7:0] r, g, b,
    output wire       showing_tga
);
    reg [2:0] on_s;
    reg       sel;
    always @(posedge clk_pix) begin
        on_s <= {on_s[1:0], tga_on};
        // switch sources only during the vertical blank of the one shown
        if (sel ? (t_vb && t_ce) : v_vb) sel <= gfx && on_s[2];
        if (sel) begin
            ce <= t_ce; hs <= t_hs; vs <= t_vs; de <= t_de; hblank <= t_hb; vblank <= t_vb;
            r <= t_r; g <= t_g; b <= t_b;
        end else begin
            ce <= 1'b1; hs <= v_hs; vs <= v_vs; de <= v_de; hblank <= v_hb; vblank <= v_vb;
            r <= v_r; g <= v_g; b <= v_b;
        end
    end
    assign showing_tga = sel;
endmodule
