// Simple dual-port RAM for the CPU's caches and register file, written so
// Quartus infers M10K blocks: one write port with byte enables, one read
// port with a registered address. Reading the address being written in the
// same cycle returns the old data (M10K mixed-port behaviour, OLD_DATA), and
// the code models exactly that: the read happens before the write.
module ev4_ram #(
    parameter AW = 10,                  // address bits
    parameter DW = 64,                  // data bits, a multiple of 8 when byte enables are used
    parameter BE = 1                    // byte enables: DW/8 lanes (1 = whole word only)
) (
    input  wire               clk,
    input  wire  [AW-1:0]     raddr,
    output reg   [DW-1:0]     rdata,
    input  wire               we,
    input  wire  [AW-1:0]     waddr,
    input  wire  [DW-1:0]     wdata,
    input  wire  [(BE>1?BE:1)-1:0] wbe
);
    // with byte enables: one 8-bit RAM per lane (Quartus does not infer a
    // byte-enabled M10K from a Verilog-2001 loop over lanes; the 2026-11-01
    // core fit built the D-cache from 65k registers)
    genvar g;
    generate
        if (BE > 1) begin : lanes
            for (g = 0; g < BE; g = g + 1) begin : lane
                reg [7:0] mem [0:(1<<AW)-1];
                always @(posedge clk) begin
                    rdata[8*g +: 8] <= mem[raddr];
                    if (we && wbe[g]) mem[waddr] <= wdata[8*g +: 8];
                end
            end
        end else begin : word
            reg [DW-1:0] mem [0:(1<<AW)-1];
            always @(posedge clk) begin
                rdata <= mem[raddr];
                if (we) mem[waddr] <= wdata;
            end
        end
    endgenerate
endmodule
