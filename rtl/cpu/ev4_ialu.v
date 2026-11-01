// 21064 integer execute unit: the operate instructions of opcodes 10 (INTA),
// 11 (INTL) and 12 (INTS); opcode 13 (multiply) is ev4_imul.v. Combinational:
// the pipeline registers around it belong to the core.
//
//   op      instruction<31:26>, func instruction<11:5>
//   a, b    Rav and Rbv (b is the zero-extended literal for the literal form)
//   res     the result
//   wr      0 when the instruction must not write Rc (a CMOV whose condition
//           is false); 1 otherwise
//   ovf     /V overflow (ADDL/V, SUBL/V, ADDQ/V, SUBQ/V): the core raises an
//           arithmetic trap (EXC_SUM IOV) when it is set
//   illegal the function code is not an EV4 instruction (OPCDEC)
//
// Semantics: Alpha Architecture Reference Manual, chapter 4.4-4.6; checked
// against tests/cpu/gen_int.py's model (make -C verilator tb_ialu).
module ev4_ialu (
    input  wire  [5:0] op,
    input  wire  [6:0] func,
    input  wire [63:0] a,
    input  wire [63:0] b,
    output reg  [63:0] res,
    output reg         wr,
    output reg         ovf,
    output reg         illegal
);
    // ------------------------------------------------------------ adder
    // scaled operand: func<1> with func<4> selects x4 / x8 (S4xxx: 02 22 0B 2B,
    // S8xxx: 12 32 1B 3B); subtract when func<3> (09 0B 1B 29 2B 3B 49 69)
    wire        scaled = op == 6'h10 && func[1] && !func[2] && func[6] == 1'b0;
    wire [63:0] as     = !scaled ? a : func[4] ? {a[60:0], 3'b000} : {a[61:0], 2'b00};
    wire        sub    = func[3];
    wire [64:0] sum    = {1'b0, as} + {1'b0, sub ? ~b : b} + {64'd0, sub};
    wire [63:0] s      = sum[63:0];
    wire [63:0] sl     = {{32{s[31]}}, s[31:0]};

    // signed overflow of the longword and quadword forms
    wire [31:0] bl     = sub ? ~b[31:0] : b[31:0];
    wire        ovf_l  = (a[31] == bl[31]) && (s[31] != a[31]);
    wire        ovf_q  = (a[63] == (sub ? ~b[63] : b[63])) && (s[63] != a[63]);

    // compares (from a - b)
    wire [64:0] diff   = {1'b0, a} + {1'b0, ~b} + 65'd1;
    wire        eq     = a == b;
    wire        ult    = !diff[64];
    wire        slt    = (a[63] != b[63]) ? a[63] : diff[63];

    // CMPBGE: byte i of a >= byte i of b, unsigned
    reg  [7:0] bge;
    integer i;
    always @* begin
        for (i = 0; i < 8; i = i + 1)
            bge[i] = a[8*i +: 8] >= b[8*i +: 8];
    end

    // ------------------------------------------------------------ byte unit
    // func<5:4> = size (B W L Q), func<6> = high half, func<3:0> = 2 MSK,
    // 6 EXTL, B INSL, A EXTH, 7 INSH; 30/31 ZAP/ZAPNOT; 34/39/3C SRL/SLL/SRA
    wire  [2:0] bo     = b[2:0];
    wire  [7:0] xmask  = func[5:4] == 2'd0 ? 8'h01 : func[5:4] == 2'd1 ? 8'h03 :
                         func[5:4] == 2'd2 ? 8'h0F : 8'hFF;
    wire [15:0] bm16   = {8'd0, xmask} << bo;
    wire  [5:0] bl8    = {bo, 3'b000};          // 8 * b<2:0>
    wire  [5:0] bh8    = 6'd0 - bl8;            // (64 - 8 * b<2:0>) mod 64

    function [63:0] zapnot;                     // keep the bytes whose mask bit is set
        input [63:0] v; input [7:0] m;
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) zapnot[8*k +: 8] = m[k] ? v[8*k +: 8] : 8'h00;
        end
    endfunction

    // one left and one right shifter serve the shifts and the byte ops
    reg  [5:0] lsh, rsh;
    always @* begin
        lsh = b[5:0];
        rsh = b[5:0];
        case (func[3:0])
        4'h6: rsh = bl8;            // EXTxL
        4'hB: lsh = bl8;            // INSxL
        4'hA: lsh = bh8;            // EXTxH
        4'h7: rsh = bh8;            // INSxH
        default: ;
        endcase
    end
    wire        arith  = func == 7'h3C;
    wire [63:0] shl    = a << lsh;
    wire [64:0] shr65  = $signed({arith & a[63], a}) >>> rsh;
    wire [63:0] shr    = shr65[63:0];

    // ------------------------------------------------------------ results
    always @* begin
        res = 64'd0; wr = 1'b1; ovf = 1'b0; illegal = 1'b0;
        case (op)
        6'h10: case (func)
            7'h00, 7'h02, 7'h09, 7'h0B, 7'h12, 7'h1B: res = sl;
            7'h20, 7'h22, 7'h29, 7'h2B, 7'h32, 7'h3B: res = s;
            7'h40, 7'h49: begin res = sl; ovf = ovf_l; end
            7'h60, 7'h69: begin res = s;  ovf = ovf_q; end
            7'h0F: res = {56'd0, bge};
            7'h1D: res = {63'd0, ult};
            7'h3D: res = {63'd0, ult | eq};
            7'h2D: res = {63'd0, eq};
            7'h4D: res = {63'd0, slt};
            7'h6D: res = {63'd0, slt | eq};
            default: illegal = 1'b1;
            endcase
        6'h11: case (func)
            7'h00: res = a & b;
            7'h08: res = a & ~b;
            7'h20: res = a | b;
            7'h28: res = a | ~b;
            7'h40: res = a ^ b;
            7'h48: res = a ^ ~b;
            7'h14: begin res = b; wr =  a[0]; end
            7'h16: begin res = b; wr = !a[0]; end
            7'h24: begin res = b; wr = a == 64'd0; end
            7'h26: begin res = b; wr = a != 64'd0; end
            7'h44: begin res = b; wr =  a[63]; end
            7'h46: begin res = b; wr = !a[63]; end
            7'h64: begin res = b; wr =  a[63] || a == 64'd0; end
            7'h66: begin res = b; wr = !a[63] && a != 64'd0; end
            default: illegal = 1'b1;   // AMASK (61) and IMPLVER (6C) are post-EV4
            endcase
        6'h12: case (func)
            7'h02, 7'h12, 7'h22, 7'h32: res = zapnot(a, ~bm16[7:0]);    // MSKxL
            7'h52, 7'h62, 7'h72:        res = zapnot(a, ~bm16[15:8]);   // MSKxH
            7'h06, 7'h16, 7'h26, 7'h36: res = zapnot(shr, xmask);       // EXTxL
            7'h5A, 7'h6A, 7'h7A:        res = zapnot(shl, xmask);       // EXTxH
            7'h0B, 7'h1B, 7'h2B, 7'h3B: res = zapnot(shl, bm16[7:0]);   // INSxL
            7'h57, 7'h67, 7'h77:        res = zapnot(shr, bm16[15:8]);  // INSxH
            7'h30: res = zapnot(a, ~b[7:0]);                            // ZAP
            7'h31: res = zapnot(a, b[7:0]);                             // ZAPNOT
            7'h34, 7'h3C: res = shr;                                    // SRL, SRA
            7'h39: res = shl;                                           // SLL
            default: illegal = 1'b1;
            endcase
        default: illegal = 1'b1;
        endcase
    end
endmodule
