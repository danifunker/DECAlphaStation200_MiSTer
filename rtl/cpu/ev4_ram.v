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
    reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    always @(posedge clk) begin
        rdata <= mem[raddr];
        if (we) begin
            if (BE > 1) begin
                for (i = 0; i < BE; i = i + 1)
                    if (wbe[i]) mem[waddr][8*i +: 8] <= wdata[8*i +: 8];
            end else
                mem[waddr] <= wdata;
        end
    end
endmodule
