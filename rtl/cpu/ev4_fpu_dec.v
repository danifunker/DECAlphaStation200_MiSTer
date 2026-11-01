// 21064 FP arithmetic decode (opcodes 0x15 VAX, 0x16 IEEE), for the core's D stage.
// docs/design/fpu.md; the function-code table is docs/design/cpu.md 8.1.
//
//   fen      opcode 16 with source field 01 (the HRM's "IEEE with datatype other
//            than S, T, Q"): FEN whatever ICCSR[FPE] says; the core checks it first
//   legal    an instruction ev4_fpu executes; otherwise OPCDEC (FEN first when FPE = 0)
//   div      DIVx: iterative, ev4_fpu is busy until it is done
//   rd_fa    reads Fa (two-operand ops); conversions read Fb only
//   rd_fb    reads Fb (every legal op)
module ev4_fpu_dec (
    input  wire [31:0] ir,
    output wire        fen,
    output reg         legal,
    output wire        div,
    output wire        rd_fa,
    output wire        rd_fb
);
    wire  [5:0] opc = ir[31:26];
    wire [10:0] fn  = ir[15:5];
    wire  [3:0] op  = fn[3:0];
    wire  [1:0] src = fn[5:4];
    wire  [1:0] rnd = fn[7:6];
    wire  [2:0] trp = fn[10:8];
    wire vax  = opc == 6'h15;
    wire ieee = opc == 6'h16;

    assign fen = ieee && src == 2'b01;

    // IEEE trap fields: 000, 001 /U, 101 /SU, 111 /SUI; VAX: 000, 001 /U, 100 /S, 101 /SU
    wire it4 = trp == 3'b000 || trp == 3'b001 || trp == 3'b101 || trp == 3'b111;
    wire vt4 = trp == 3'b000 || trp == 3'b001 || trp == 3'b100 || trp == 3'b101;
    always @* begin
        legal = 1'b0;
        if (ieee) begin
            if (op[3:2] == 2'b00 && (src == 2'b00 || src == 2'b10)) legal = it4;           // ADD SUB MUL DIV S/T
            else if (op[3:2] == 2'b01 && src == 2'b10) legal = (trp == 3'b000 || trp == 3'b101) && rnd == 2'b10;  // CMPTxx
            else if (op == 4'hC && src == 2'b10) legal = it4 || ((trp == 3'b010 || trp == 3'b110) && rnd == 2'b10); // CVTTS, CVTST
            else if ((op == 4'hC || op == 4'hE) && src == 2'b11) legal = trp == 3'b000 || trp == 3'b111;  // CVTQS CVTQT
            else if (op == 4'hF && src == 2'b10) legal = it4;                              // CVTTQ
        end else if (vax && !rnd[0]) begin                                                  // /C or normal only
            if (op[3:2] == 2'b00 && (src == 2'b00 || src == 2'b10)) legal = vt4;           // ADD SUB MUL DIV F/G
            else if ((op == 4'h5 || op == 4'h6 || op == 4'h7) && src == 2'b10)
                legal = (trp == 3'b000 || trp == 3'b100) && rnd == 2'b10;                  // CMPGxx
            else if ((op == 4'hC || op == 4'hD) && src == 2'b10) legal = vt4;              // CVTGF CVTGD
            else if (op == 4'hE && src == 2'b01) legal = vt4;                              // CVTDG
            else if ((op == 4'hC || op == 4'hE) && src == 2'b11) legal = trp == 3'b000;    // CVTQF CVTQG
            else if (op == 4'hF && src == 2'b10) legal = vt4;                              // CVTGQ
        end
    end
    assign div   = op == 4'h3;
    assign rd_fa = op[3] == 1'b0;
    assign rd_fb = 1'b1;
endmodule
