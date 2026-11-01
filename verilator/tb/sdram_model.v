// Behavioural SDRAM for simulation (two ranks of 4 banks x 8192 rows x 1024
// columns x 16 bits = 128 MB): the commands of rtl/mister/sdram_ctl.v,
// taken at the clock edge after the controller registers them; a READ's
// beat k is on the bus in the cycle 1 + k after that (so the controller's
// input register holds beat 0 four clocks after it issued the READ, its CAP);
// bursts of 8, sequential within the aligned 8; single-location writes with
// DQMH/DQML. Timing violations are not checked.
module sdram_model (
    input  wire        clk,
    input  wire [12:0] a,
    input  wire  [1:0] ba,
    input  wire        ncs, nras, ncas, nwe, dqml, dqmh,
    input  wire [15:0] dq_w,
    input  wire        dq_oe,
    output reg  [15:0] dq_r
);
    reg [15:0] mem [0:(1<<26)-1];
    reg [12:0] row [0:7];
    wire [2:0] cmd = {nras, ncas, nwe};
    wire [12:0] a_s = a; wire [1:0] ba_s = ba; wire cs_s = ncs, ml_s = dqml, mh_s = dqmh;
    wire [15:0] d_s = dq_w;
    reg  [3:0] rd_left;
    reg [25:0] rd_base;
    reg  [2:0] rd_col;
    always @(posedge clk) begin
        dq_r <= 16'hxxxx;
        if (rd_left != 4'd0) begin
            dq_r <= mem[{rd_base[25:3], rd_col}];
            rd_col <= rd_col + 3'd1;
            rd_left <= rd_left - 4'd1;
        end
        // (READ below: the first beat goes out at the next edge, one clock
        // after the command was taken)
        case (cmd)
        3'b011: row[{cs_s, ba_s}] <= a_s;                                    // ACTIVE
        3'b101: begin                                                         // READ
            rd_base <= {cs_s, ba_s, row[{cs_s, ba_s}], a_s[9:0]};
            rd_col  <= a_s[2:0]; rd_left <= 4'd8;
        end
        3'b100: begin : w                                                     // WRITE
            reg [25:0] ad;
            ad = {cs_s, ba_s, row[{cs_s, ba_s}], a_s[9:0]};
            if (!ml_s) mem[ad][7:0]  <= d_s[7:0];
            if (!mh_s) mem[ad][15:8] <= d_s[15:8];
        end
        default: ;
        endcase
    end
endmodule
