// 21064 integer multiplier: opcode 13 (MULL, MULQ, UMULH, MULL/V, MULQ/V).
// Multi-cycle like the real Ebox multiplier (which takes 19-23 cycles):
// one 32x32 partial product per cycle into a 128-bit accumulator, so the
// unit needs a single DSP-sized multiplier. start is taken when !busy; done
// pulses for one cycle with res/ovf valid (they hold until the next start).
//
//   func 00 MULL    SEXT((a * b)<31:0>)
//        20 MULQ    (a * b)<63:0>
//        30 UMULH   (a * b)<127:64>, unsigned
//        40 MULL/V  as MULL; ovf when the product of the sign-extended
//                   longwords does not fit in a longword
//        60 MULQ/V  as MULQ; ovf when the signed 128-bit product does not
//                   fit in a quadword
//   illegal: any other function code (OPCDEC), decided at start
module ev4_imul (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire  [6:0] func,
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire        busy,
    output reg         done,
    output reg  [63:0] res,
    output reg         ovf,
    output wire        illegal
);
    assign illegal = !(func == 7'h00 || func == 7'h20 || func == 7'h30 ||
                       func == 7'h40 || func == 7'h60);

    reg  [63:0] ra, rb;
    reg   [6:0] fn;
    reg [127:0] acc;
    reg   [2:0] step;                  // 1..4 partial products, 5 finish
    assign busy = step != 3'd0;

    // the partial product of this step: {a half} x {b half}
    // step 1: a lo x b lo, 2: a lo x b hi, 3: a hi x b lo, 4: a hi x b hi
    wire [31:0] pa = (step == 3'd3 || step == 3'd4) ? ra[63:32] : ra[31:0];
    wire [31:0] pb = (step == 3'd2 || step == 3'd4) ? rb[63:32] : rb[31:0];
    wire [63:0] pp = pa * pb;
    // shifted into place: << 0, << 32, << 32, << 64
    wire [127:0] pps = step == 3'd1 ? {64'd0, pp} :
                       step == 3'd4 ? {pp, 64'd0} : {32'd0, pp, 32'd0};

    // signed corrections of the unsigned product
    wire [63:0] shi  = acc[127:64] - (ra[63] ? rb : 64'd0) - (rb[63] ? ra : 64'd0);
    // the longword product: lo*lo (bits 63:0 of step 1's product), corrected
    // for the longword signs
    reg  [63:0] lprod;
    wire [63:0] lsig = lprod - (ra[31] ? {rb[31:0], 32'd0} : 64'd0)
                             - (rb[31] ? {ra[31:0], 32'd0} : 64'd0);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            step <= 3'd0;
        end else if (step == 3'd0) begin
            if (start && !illegal) begin
                ra <= a; rb <= b; fn <= func;
                acc <= 128'd0;
                step <= 3'd1;
            end
        end else if (step != 3'd5) begin
            acc <= acc + pps;
            if (step == 3'd1) lprod <= pp;
            step <= step + 3'd1;
        end else begin
            step <= 3'd0;
            done <= 1'b1;
            case (fn)
            7'h00, 7'h40: res <= {{32{acc[31]}}, acc[31:0]};
            7'h30:        res <= acc[127:64];
            default:      res <= acc[63:0];
            endcase
            ovf <= fn == 7'h40 ? !(&lsig[63:31] || ~|lsig[63:31]) :
                   fn == 7'h60 ? (shi != {64{acc[63]}}) : 1'b0;
        end
    end
endmodule
