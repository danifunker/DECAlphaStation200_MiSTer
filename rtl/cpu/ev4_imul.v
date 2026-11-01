// 21064 integer multiplier: opcode 13 (MULL, MULQ, UMULH, MULL/V, MULQ/V).
// Multi-cycle like the real Ebox multiplier (19-23 cycles there, ~10 here),
// pipelined for 100 MHz (docs/design/cpu-timing.md): each 32x32 partial
// product goes operand flops -> DSP multiply -> product flop -> accumulate,
// and the signed corrections get their own cycles. start is taken when
// !busy; done pulses for one cycle with res/ovf valid (they hold until the
// next start).
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
    reg         run;
    reg   [2:0] iss;                   // partial products issued (0..4)
    reg   [2:0] acn;                   // partial products accumulated (0..4)
    reg   [1:0] fin;                   // 1: corrections, 2: result

    // stage 1: operand halves; 0: lo x lo, 1: lo x hi, 2: hi x lo, 3: hi x hi
    reg  [31:0] opa, opb;
    reg   [1:0] osel;
    reg         ov;
    // stage 2: product
    reg  [63:0] pp;
    reg   [1:0] psel;
    reg         pv;
    // stage 3: accumulator
    reg [127:0] acc;
    reg  [63:0] lprod;                 // lo x lo, for MULL/V
    // corrections
    reg  [63:0] shi, lsig;

    assign busy = run;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            run <= 1'b0; ov <= 1'b0; pv <= 1'b0; fin <= 2'd0;
        end else if (!run) begin
            ov <= 1'b0; pv <= 1'b0;
            if (start && !illegal) begin
                ra <= a; rb <= b; fn <= func;
                acc <= 128'd0;
                iss <= 3'd0; acn <= 3'd0; fin <= 2'd0;
                run <= 1'b1;
            end
        end else begin
            // issue
            ov <= iss != 3'd4;
            if (iss != 3'd4) begin
                opa  <= iss[1] ? ra[63:32] : ra[31:0];
                opb  <= iss[0] ? rb[63:32] : rb[31:0];
                osel <= iss[1:0];
                iss  <= iss + 3'd1;
            end
            // multiply
            pp <= opa * opb; psel <= osel; pv <= ov;
            // accumulate
            if (pv) begin
                case (psel)
                2'd0: begin acc <= acc + {64'd0, pp}; lprod <= pp; end
                2'd3: acc <= acc + {pp, 64'd0};
                default: acc <= acc + {32'd0, pp, 32'd0};
                endcase
                acn <= acn + 3'd1;
            end
            // signed corrections, then the result
            if (acn == 3'd4 && fin == 2'd0) begin
                shi  <= acc[127:64] - (ra[63] ? rb : 64'd0) - (rb[63] ? ra : 64'd0);
                lsig <= lprod - (ra[31] ? {rb[31:0], 32'd0} : 64'd0)
                              - (rb[31] ? {ra[31:0], 32'd0} : 64'd0);
                fin  <= 2'd1;
            end
            if (fin == 2'd1) begin
                fin  <= 2'd2;
                run  <= 1'b0;
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
    end
endmodule
