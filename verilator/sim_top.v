// Testbench top for the Verilator run: the machine (rtl/as200.v) with the MiSTer-side
// (rtl/mister/vterm.v), wired as DECAlphaStation200.sv wires them.
// serial terminal. sim_main.cpp drives the clocks and the console.
module sim_top (
    input  wire       clk_sys,
    input  wire       clk_pix,
    input  wire       reset,
    input  wire [1:0] cfg_mem,

    input  wire       uart_rxd,
    output wire       uart_txd,
    input  wire       kbd_stb,
    input  wire [7:0] kbd_byte,
    output wire       com1_tx_stb,
    output wire [7:0] com1_tx_byte,

    output wire       vga_hs,
    output wire       vga_vs,
    output wire       vga_de,
    output wire [7:0] vga_r,
    output wire [7:0] vga_g,
    output wire [7:0] vga_b
);
    as200 machine (
        .clk(clk_sys), .rst(reset), .cfg_mem(cfg_mem),
        .com1_txd(uart_txd), .com1_rxd(uart_rxd),
        .com1_rts_n(), .com1_dtr_n(),
        .com1_cts_n(1'b0), .com1_dsr_n(1'b0), .com1_dcd_n(1'b0),
        .com1_tx_stb(com1_tx_stb), .com1_tx_byte(com1_tx_byte),
        .com1_kbd_stb(kbd_stb), .com1_kbd_byte(kbd_byte)
    );

    vterm #(.FONT("../rtl/mister/font8x16.hex")) vterm (
        .clk(clk_sys), .rst(reset),
        .in_stb(com1_tx_stb), .in_byte(com1_tx_byte),
        .clk_pix(clk_pix),
        .hs(vga_hs), .vs(vga_vs), .de(vga_de), .hblank(), .vblank(),
        .r(vga_r), .g(vga_g), .b(vga_b)
    );
endmodule
