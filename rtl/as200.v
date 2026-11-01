// The AlphaStation 200 4/166 machine (docs/CORE_SPEC.md), board-independent:
// the MiSTer top (DECAlphaStation200.sv) and the Verilator testbench
// (verilator/sim_top.v) both instantiate it.
//
// Bring-up state: COM1 (the PC87332's first 16550) driven by bringup_stub in
// place of the 21064. The CPU, the 21071 chipset, PCI, the SIO and the rest
// replace the stub as they are built.
module as200 (
    input  wire       clk,          // system clock (50 MHz)
    input  wire       rst,
    input  wire [1:0] cfg_mem,      // Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB

    // COM1, to the MiSTer UART
    output wire       com1_txd,
    input  wire       com1_rxd,
    output wire       com1_rts_n,
    output wire       com1_dtr_n,
    input  wire       com1_cts_n,
    input  wire       com1_dsr_n,
    input  wire       com1_dcd_n,
    // COM1's characters for the on-screen terminal, and keys typed into it
    output wire       com1_tx_stb,
    output wire [7:0] com1_tx_byte,
    input  wire       com1_kbd_stb,
    input  wire [7:0] com1_kbd_byte
);
    // 1.8432 MHz from the system clock: a phase accumulator, 18432/500000
    // of the 50 MHz cycles (exact on average; the jitter is 20 ns)
    reg [19:0] baud_acc;
    reg        ce_1m8;
    always @(posedge clk) begin
        if (baud_acc >= 20'd500000 - 20'd18432) begin
            baud_acc <= baud_acc + 20'd18432 - 20'd500000;
            ce_1m8   <= 1'b1;
        end else begin
            baud_acc <= baud_acc + 20'd18432;
            ce_1m8   <= 1'b0;
        end
    end

    wire [2:0] io_addr;
    wire       io_rd, io_wr;
    wire [7:0] io_wdata, com1_rdata;
    wire       com1_irq;

    bringup_stub stub (
        .clk(clk), .rst(rst), .mem_sel(cfg_mem),
        .io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr),
        .io_dout(io_wdata), .io_din(com1_rdata)
    );

    ns16550 com1 (
        .clk(clk), .rst(rst), .ce_1m8(ce_1m8),
        .io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr),
        .io_din(io_wdata), .io_dout(com1_rdata), .irq(com1_irq),
        .txd(com1_txd), .rxd(com1_rxd),
        .rts_n(com1_rts_n), .dtr_n(com1_dtr_n), .out1_n(), .out2_n(),
        .cts_n(com1_cts_n), .dsr_n(com1_dsr_n), .ri_n(1'b1), .dcd_n(com1_dcd_n),
        .tx_stb(com1_tx_stb), .tx_byte(com1_tx_byte),
        .rx_inj_stb(com1_kbd_stb), .rx_inj_byte(com1_kbd_byte)
    );
endmodule
