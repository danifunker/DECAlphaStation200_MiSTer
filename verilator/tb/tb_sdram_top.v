// the SDRAM controller with the chip model, for verilator/tb/tb_sdram.cpp
module tb_sdram_top (
    input  wire        clk,
    input  wire        init,
    output wire        ready,
    input  wire        req,
    input  wire        we,
    input  wire        line,
    input  wire [26:3] addr,
    input  wire [31:0] be,
    input  wire [255:0] wdata,
    output wire        ack,
    output wire [63:0] rdata
);
    wire [12:0] A; wire [1:0] BA; wire ncs, nras, ncas, nwe, dqml, dqmh, cke, oe;
    wire [15:0] dq_out, dq_in;
    sdram_ctl #(.CLK_MHZ(100)) ctl (.clk(clk), .init(init), .ready(ready),
        .req(req), .we(we), .line(line), .addr(addr), .be(be), .wdata(wdata), .ack(ack), .rdata(rdata),
        .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(ncs), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas),
        .SDRAM_nWE(nwe), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_CKE(cke),
        .dq_out(dq_out), .dq_oe(oe), .dq_in(dq_in));
    sdram_model chip (.clk(clk), .a(A), .ba(BA), .ncs(ncs), .nras(nras), .ncas(ncas), .nwe(nwe),
        .dqml(dqml), .dqmh(dqmh), .dq_w(dq_out), .dq_oe(oe), .dq_r(dq_in));
endmodule
