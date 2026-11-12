// A small register file with an asynchronous read (Cyclone V: an MLAB in place of
// registers and their read multiplexers). One write port, one read port: a second
// reader is a second instance written alike. It behaves as an array of registers
// does: a read in the cycle of a write to the same address gives the old value.
// Its contents start at zero and no reset clears them.
module isa_lutram #(
    parameter AW = 3,
    parameter DW = 8
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [DW-1:0] wd,
    input  wire [AW-1:0] ra,
    output wire [DW-1:0] rd
);
    (* ramstyle = "MLAB" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) if (we) mem[wa] <= wd;
    assign rd = mem[ra];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
    end
endmodule
