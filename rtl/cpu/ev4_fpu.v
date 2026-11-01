// 21064 (EV4) floating-point arithmetic unit: opcode 0x16 (IEEE S/T) and
// opcode 0x15 (VAX F/G, D as a conversion format). docs/design/fpu.md is the
// design; docs/design/cpu.md 8 the architecture (8.1 function codes, 8.3
// register formats, 8.4 the EV4 exception rules).
//
// Operands and results are in register format. ir only needs [31:26] and
// [15:5]; ev4_fpu_dec decides legality (an illegal code gives an undefined
// result here). start, ir, fa, fb, fpcr_dyn and tag must come straight from
// flops (the first stage is one 64-bit carry chain deep).
//
// Every operation except DIVx takes 5 cycles (start in cycle t, done in t+5)
// and may be issued every cycle. DIVx is iterative: start in t, done in t+29
// (S, F) or t+58 (T, G); busy is high from t+1 until the cycle before done,
// and start must be low while busy. Results come out in issue order; tag is
// returned with done. kill drops everything in flight (no done follows).
//
// Pipeline (flops after each stage):
//   A  unpack, classify, exponent difference, |a| >= |b|, compare result,
//      integer magnitude, input exceptions
//   B  far path: align shift and sticky | close path: subtract with a 0/1-bit
//      shift | multiply: four 27x27 products | CVTxQ: shift into a 64.64 fixed point
//   C  far: add/subtract | close: leading-zero count | multiply: 3-input sum
//      | CVTxQ: round and negate
//   D  normalise: far 1 bit, close by the count, multiply 1 bit, divide 1 bit
//   E  round to the format, exponent range (the ARM's underflow rule),
//      pack, FPCR/EXC_SUM bits
module ev4_fpu #(parameter TAG_W = 6) (
    input  wire             clk,
    input  wire             rst,
    input  wire             kill,
    input  wire             start,
    input  wire      [31:0] ir,
    input  wire      [63:0] fa,
    input  wire      [63:0] fb,
    input  wire       [1:0] fpcr_dyn,
    input  wire [TAG_W-1:0] tag,
    output wire             busy,
    output reg              done,
    output reg  [TAG_W-1:0] done_tag,
    output reg       [63:0] result,
    output reg        [5:0] fpcr_set,   // FPCR[57:52] to OR in: IOV INE UNF OVF DZE INV (bit 0 = INV)
    output reg        [6:0] exc_sum,    // EXC_SUM[8:2]: IOV INE UNF FOV DZE INV SWC (bit 0 = SWC)
    output reg              trap        // ARITH trap (= |exc_sum[6:1])
);
    // paths
    localparam P_FAR = 3'd0, P_CLOSE = 3'd1, P_MUL = 3'd2, P_DIV = 3'd3, P_TOINT = 3'd4, P_CMP = 3'd5;
    // result formats
    localparam F_T = 3'd0, F_S = 3'd1, F_G = 3'd2, F_F = 3'd3, F_D = 3'd4;
    // rounding: nearest even, chopped, minus, plus, VAX nearest (ties away from zero)
    localparam R_NE = 3'd0, R_Z = 3'd1, R_M = 3'd2, R_P = 3'd3, R_NA = 3'd4;

    // =====================================================================
    // A: unpack (combinational on the inputs)
    // =====================================================================
    wire        vax  = ir[31:26] == 6'h15;
    wire [10:0] fn   = ir[15:5];
    wire  [3:0] op   = fn[3:0];
    wire  [1:0] src  = fn[5:4];
    wire        en_u = fn[8];                     // /U (/V for CVTxQ)
    wire        en_i = fn[9] && !vax;             // /I
    wire        q_s  = fn[10];                    // /S
    wire        dsrc = vax && src == 2'b01;       // CVTDG
    wire        cvtst = !vax && op == 4'hC && fn[9] && !fn[8];

    wire is_arith   = op[3:2] == 2'b00;
    wire is_add     = is_arith && !op[1];
    wire is_mul     = op == 4'h2;
    wire is_div     = op == 4'h3;
    wire is_cmp     = op[3:2] == 2'b01;
    wire is_toint   = op == 4'hF;
    wire is_fromint = src == 2'b11;               // CVTQS CVTQT CVTQF CVTQG

    reg [2:0] fmt_c;
    always @* begin
        if (!vax) fmt_c = (is_arith ? src == 2'b00 : (op == 4'hC && !cvtst)) ? F_S : F_T;
        else if (is_arith) fmt_c = src == 2'b00 ? F_F : F_G;
        else if (op == 4'hC) fmt_c = F_F;
        else if (op == 4'hD) fmt_c = F_D;
        else fmt_c = F_G;
    end
    reg [2:0] mode_c;
    always @* begin
        if (vax) mode_c = fn[7] ? R_NA : R_Z;
        else case (fn[7:6] == 2'b11 ? fpcr_dyn : fn[7:6])
            2'b00: mode_c = R_Z;
            2'b01: mode_c = R_M;
            2'b10: mode_c = R_NE;
            default: mode_c = R_P;
        endcase
    end

    wire        sa = fa[63], sb = fb[63];
    wire [10:0] ea = fa[62:52], eb = fb[62:52];
    wire        a_e0 = ea == 11'd0, b_e0 = eb == 11'd0;
    wire        a_f0 = fa[51:0] == 52'd0, b_f0 = fb[51:0] == 52'd0;
    wire        bd_e0 = fb[62:55] == 8'd0, bd_f0 = fb[54:0] == 55'd0;
    wire        a_zero = a_e0 && a_f0;
    wire        b_zero = dsrc ? bd_e0 && bd_f0 : b_e0 && b_f0;
    // non-finite: IEEE NaN/Inf/denormal; VAX reserved operand or dirty zero
    wire bad_a = vax ? a_e0 && (sa || !a_f0) : (&ea) || (a_e0 && !a_f0);
    wire bad_b = dsrc ? bd_e0 && (sb || !bd_f0) :
                 vax  ? b_e0 && (sb || !b_f0) : (&eb) || (b_e0 && !b_f0);

    wire [63:0] wa = {!a_e0, fa[51:0], 11'd0};
    wire [63:0] wb = dsrc ? {!bd_e0, fb[54:0], 8'd0} : {!b_e0, fb[51:0], 11'd0};
    wire signed [12:0] Ea = $signed({2'b00, ea}) - (vax ? 13'sd1025 : 13'sd1023);
    wire signed [12:0] Eb = dsrc ? $signed({5'd0, fb[62:55]}) - 13'sd129 :
                                   $signed({2'b00, eb}) - (vax ? 13'sd1025 : 13'sd1023);

    wire mag_ge = fa[62:0] >= fb[62:0];
    wire mag_eq = fa[62:0] == fb[62:0];

    // add/subtract: the larger magnitude is "big"
    wire        sbe     = sb ^ op[0];
    wire        eff_sub = sa ^ sbe;
    wire [10:0] diff_c  = mag_ge ? ea - eb : eb - ea;

    // compare (finite operands)
    wire both_zero = a_zero && b_zero;
    wire c_eq = (mag_eq && sa == sb) || both_zero;
    wire c_lt = sa != sb ? sa && !both_zero : (sa ? mag_ge && !mag_eq : !mag_ge);
    wire cmp_c = op == 4'h5 ? c_eq : op == 4'h6 ? c_lt : op == 4'h7 ? (c_lt || c_eq) : 1'b0;

    // integer source magnitude
    wire [63:0] imag = sb ? -fb : fb;

    // exceptions on the inputs (cpu.md 8.4): input ones take priority
    wire inv_c = (op[3] ? (!is_fromint && bad_b) : (bad_a || bad_b)) ||
                 (!vax && is_div && a_zero && b_zero);
    wire dze_c = !inv_c && is_div && b_zero;
    wire signed [12:0] L_c = Eb + 13'sd12;        // CVTxQ: shift of the 53-bit significand into 64.64
    wire iov_c = Eb >= 13'sd63 && !(sb && Eb == 13'sd63 && b_f0);

    // A flops
    reg        a_v;
    reg  [2:0] a_path, a_fmt, a_mode;
    reg        a_sign, a_zsign, a_vax, a_enu, a_eni, a_qs, a_div, a_inv, a_dze, a_iov, a_cmp;
    reg        a_effsub;
    reg signed [12:0] a_E;
    reg [63:0] a_big, a_small;
    reg [10:0] a_diff;
    reg [52:0] a_ma, a_mb;
    reg [TAG_W-1:0] a_tag;

    always @(posedge clk) begin
        a_v <= start && !kill && !rst;
        a_vax <= vax; a_fmt <= fmt_c; a_mode <= mode_c; a_tag <= tag;
        a_enu <= en_u; a_eni <= en_i; a_qs <= q_s; a_div <= is_div;
        a_inv <= inv_c; a_dze <= dze_c; a_iov <= iov_c; a_cmp <= cmp_c;
        a_ma <= wa[63:11]; a_mb <= wb[63:11];
        a_effsub <= eff_sub;
        a_diff <= diff_c;
        a_big <= mag_ge ? wa : wb; a_small <= mag_ge ? wb : wa;
        a_E <= mag_ge ? Ea : Eb;
        a_sign <= mag_ge ? sa : sbe;
        a_zsign <= vax ? 1'b0 : (eff_sub ? mode_c == R_M : sa);
        if (is_add) begin
            a_path <= (eff_sub && diff_c <= 11'd1) ? P_CLOSE : P_FAR;
        end else if (is_mul || is_div) begin
            a_path <= is_mul ? P_MUL : P_DIV;
            a_E <= is_mul ? Ea + Eb : Ea - Eb;
            a_sign <= sa ^ sb; a_zsign <= !vax && (sa ^ sb);
        end else if (is_cmp) begin
            a_path <= P_CMP;
        end else if (is_toint) begin
            a_path <= P_TOINT;
            a_E <= L_c; a_sign <= sb;
        end else begin                            // conversions to floating: close path, nothing subtracted
            a_path <= P_CLOSE;
            a_diff <= 11'd0; a_small <= 64'd0;
            if (is_fromint) begin
                a_big <= imag; a_E <= 13'sd63; a_sign <= sb; a_zsign <= 1'b0;
            end else begin
                a_big <= wb; a_E <= Eb; a_sign <= sb; a_zsign <= !vax && sb;
            end
        end
    end

    // =====================================================================
    // divider (radix 2, restoring), loaded straight from the inputs
    // =====================================================================
    reg        dv_act, dv_fin, dv_ld;
    reg  [5:0] dv_cnt;
    reg [55:0] dv_r;
    reg [52:0] dv_d;
    reg [54:0] dv_q;
    reg  [2:0] dv_fmt, dv_mode;
    reg        dv_sign, dv_zsign, dv_vax, dv_enu, dv_eni, dv_qs, dv_inv, dv_dze;
    reg signed [12:0] dv_E;
    reg [TAG_W-1:0] dv_tag;
    wire [55:0] dv_t = dv_r - {3'd0, dv_d};
    wire        dv_qb = !dv_t[55];
    wire [55:0] dv_rn = dv_qb ? dv_t : dv_r;

    assign busy = dv_act;

    always @(posedge clk) begin
        dv_ld <= 1'b0;
        if (rst || kill) begin
            dv_act <= 1'b0; dv_fin <= 1'b0;
        end else if (start && is_div) begin
            dv_act <= 1'b1; dv_fin <= 1'b0; dv_ld <= 1'b1;
            dv_r <= {3'd0, wa[63:11]}; dv_d <= wb[63:11]; dv_q <= 55'd0;
            dv_cnt <= (fmt_c == F_S || fmt_c == F_F) ? 6'd26 : 6'd55;
        end else if (dv_act) begin
            if (dv_cnt != 6'd0) begin
                dv_r <= {dv_rn[54:0], 1'b0};
                dv_q <= {dv_q[53:0], dv_qb};
                dv_cnt <= dv_cnt - 6'd1;
                if (dv_cnt == 6'd1) dv_fin <= 1'b1;
            end else if (dv_fin) begin
                dv_fin <= 1'b0; dv_act <= 1'b0;
            end
        end
        if (dv_ld) begin                          // the context, from the A flops
            dv_fmt <= a_fmt; dv_mode <= a_mode; dv_sign <= a_sign; dv_zsign <= a_zsign;
            dv_vax <= a_vax; dv_enu <= a_enu; dv_eni <= a_eni; dv_qs <= a_qs;
            dv_inv <= a_inv; dv_dze <= a_dze; dv_E <= a_E; dv_tag <= a_tag;
        end
    end

    // =====================================================================
    // B
    // =====================================================================
    // far: align
    wire        far_big_sh = a_diff[10:6] != 5'd0;
    wire [63:0] far_sh  = far_big_sh ? 64'd0 : a_small >> a_diff[5:0];
    wire [63:0] far_msk = far_big_sh ? {64{1'b1}} : ~({64{1'b1}} << a_diff[5:0]);
    wire        far_st  = |(a_small & far_msk);
    // close: exact subtract (shift 0 or 1)
    wire [63:0] close_x = a_big - (a_diff[0] ? {1'b0, a_small[63:1]} : a_small);
    // CVTxQ: the significand m at 2^L in a 64.64 fixed point (L = E + 12)
    wire        ti_neg  = a_E < 13'sd0;
    wire        ti_huge = a_E > 13'sd127;
    wire [127:0] ti_v   = (ti_neg || ti_huge) ? 128'd0 : ({75'd0, a_mb} << a_E[6:0]);
    wire        ti_st   = ti_neg ? a_mb != 53'd0 : |ti_v[62:0];

    reg        b_v;
    reg  [2:0] b_path, b_fmt, b_mode;
    reg        b_sign, b_zsign, b_vax, b_enu, b_eni, b_qs, b_div, b_inv, b_dze, b_iov, b_cmp, b_effsub;
    reg signed [12:0] b_E;
    reg [63:0] b_big, b_sh, b_cx, b_int;
    reg        b_st, b_g, b_ist;
    reg [53:0] b_p00;
    reg [52:0] b_p01, b_p10;
    reg [51:0] b_p11;
    reg [TAG_W-1:0] b_tag;

    always @(posedge clk) begin
        b_v <= a_v && a_path != P_DIV && !kill && !rst;
        b_path <= a_path; b_fmt <= a_fmt; b_mode <= a_mode; b_sign <= a_sign; b_zsign <= a_zsign;
        b_vax <= a_vax; b_enu <= a_enu; b_eni <= a_eni; b_qs <= a_qs; b_div <= a_div;
        b_inv <= a_inv; b_dze <= a_dze; b_iov <= a_iov; b_cmp <= a_cmp; b_effsub <= a_effsub;
        b_E <= a_E; b_tag <= a_tag;
        b_big <= a_big; b_sh <= far_sh; b_st <= far_st;
        b_cx <= close_x;
        b_p00 <= a_ma[26:0]  * a_mb[26:0];
        b_p01 <= a_ma[26:0]  * a_mb[52:27];
        b_p10 <= a_ma[52:27] * a_mb[26:0];
        b_p11 <= a_ma[52:27] * a_mb[52:27];
        b_int <= ti_v[127:64]; b_g <= ti_v[63]; b_ist <= ti_st;
    end

    // =====================================================================
    // C
    // =====================================================================
    function rinc;                                // round up?
        input [2:0] m; input s, l, g, t;          // mode, sign, lsb, guard, sticky
        case (m)
        R_NE: rinc = g && (t || l);
        R_M:  rinc = s && (g || t);
        R_P:  rinc = !s && (g || t);
        R_NA: rinc = g;
        default: rinc = 1'b0;
        endcase
    endfunction

    wire [65:0] far_b   = {1'b0, b_sh, b_st};
    wire [65:0] far_sum = {1'b0, b_big, 1'b0} + (b_effsub ? ~far_b : far_b) + {65'd0, b_effsub};
    // leading zeros of the close result: per nibble, then the first non-zero nibble
    reg [6:0] lzc;
    integer k;
    reg [1:0] nz [0:15];
    reg [15:0] nzn;
    always @* begin
        for (k = 0; k < 16; k = k + 1) begin
            nzn[k] = b_cx[4*k +: 4] != 4'd0;
            nz[k]  = b_cx[4*k+3] ? 2'd0 : b_cx[4*k+2] ? 2'd1 : b_cx[4*k+1] ? 2'd2 : 2'd3;
        end
        lzc = 7'd64;
        for (k = 0; k < 16; k = k + 1)
            if (nzn[k]) lzc = {1'b0, 4'd15 - k[3:0], nz[k]};
    end
    wire [78:0] mul_s  = {b_p11, b_p00[53:27]} + {26'd0, b_p01} + {26'd0, b_p10};
    wire        mul_lo = b_p00[26:0] != 27'd0;
    wire        ti_inc = rinc(b_mode, b_sign, b_int[0], b_g, b_ist);
    wire [63:0] ti_res = (b_sign ? ~b_int : b_int) + {63'd0, b_sign ? !ti_inc : ti_inc};

    reg        c_v;
    reg  [2:0] c_path, c_fmt, c_mode;
    reg        c_sign, c_zsign, c_vax, c_enu, c_eni, c_qs, c_div, c_inv, c_dze, c_iov, c_cmp, c_tine;
    reg signed [12:0] c_E;
    reg [65:0] c_sum;
    reg [63:0] c_cx, c_ires;
    reg  [6:0] c_lzc;
    reg [78:0] c_prod;
    reg        c_plo;
    reg [TAG_W-1:0] c_tag;

    always @(posedge clk) begin
        c_v <= b_v && !kill && !rst;
        c_path <= b_path; c_fmt <= b_fmt; c_mode <= b_mode; c_sign <= b_sign; c_zsign <= b_zsign;
        c_vax <= b_vax; c_enu <= b_enu; c_eni <= b_eni; c_qs <= b_qs; c_div <= b_div;
        c_inv <= b_inv; c_dze <= b_dze; c_iov <= b_iov; c_cmp <= b_cmp;
        c_E <= b_E; c_tag <= b_tag;
        c_sum <= far_sum; c_cx <= b_cx; c_lzc <= lzc;
        c_prod <= mul_s; c_plo <= mul_lo;
        c_ires <= ti_res; c_tine <= b_g || b_ist;
    end

    // =====================================================================
    // D: normalise (from C, or from the divider)
    // =====================================================================
    reg [63:0] n_w;
    reg        n_st;
    reg signed [12:0] n_adj;
    wire [63:0] dv_w0 = (dv_fmt == F_S || dv_fmt == F_F) ? {dv_q[25:0], 38'd0} : {dv_q[54:0], 9'd0};
    always @* begin
        n_w = c_cx << c_lzc; n_st = 1'b0; n_adj = -$signed({6'd0, c_lzc});
        case (c_path)
        P_FAR:
            if (c_sum[65])      begin n_w = c_sum[65:2]; n_st = |c_sum[1:0]; n_adj = 13'sd1; end
            else if (c_sum[64]) begin n_w = c_sum[64:1]; n_st = c_sum[0];    n_adj = 13'sd0; end
            else                begin n_w = c_sum[63:0]; n_st = 1'b0;        n_adj = -13'sd1; end
        P_MUL:
            if (c_prod[78]) begin n_w = c_prod[78:15]; n_st = c_plo || (|c_prod[14:0]); n_adj = 13'sd1; end
            else            begin n_w = c_prod[77:14]; n_st = c_plo || (|c_prod[13:0]); n_adj = 13'sd0; end
        default: ;
        endcase
        if (dv_fin) begin
            n_st = dv_r != 56'd0;
            if (dv_w0[63]) begin n_w = dv_w0; n_adj = 13'sd0; end
            else begin n_w = {dv_w0[62:0], 1'b0}; n_adj = -13'sd1; end
        end
    end

    reg        d_v;
    reg  [2:0] d_path, d_fmt, d_mode;
    reg        d_sign, d_zsign, d_vax, d_enu, d_eni, d_qs, d_div, d_inv, d_dze, d_iov, d_cmp, d_tine;
    reg signed [12:0] d_E;
    reg [63:0] d_w, d_ires;
    reg        d_st;
    reg [TAG_W-1:0] d_tag;

    always @(posedge clk) begin
        d_w <= n_w; d_st <= n_st;
        d_ires <= c_ires; d_tine <= c_tine; d_iov <= c_iov; d_cmp <= c_cmp;
        if (dv_fin) begin
            d_v <= !kill && !rst;
            d_path <= P_DIV; d_fmt <= dv_fmt; d_mode <= dv_mode; d_sign <= dv_sign; d_zsign <= dv_zsign;
            d_vax <= dv_vax; d_enu <= dv_enu; d_eni <= dv_eni; d_qs <= dv_qs; d_div <= 1'b1;
            d_inv <= dv_inv; d_dze <= dv_dze; d_tag <= dv_tag;
            d_E <= dv_E + n_adj;
        end else begin
            d_v <= c_v && !kill && !rst;
            d_path <= c_path; d_fmt <= c_fmt; d_mode <= c_mode; d_sign <= c_sign; d_zsign <= c_zsign;
            d_vax <= c_vax; d_enu <= c_enu; d_eni <= c_eni; d_qs <= c_qs; d_div <= c_div;
            d_inv <= c_inv; d_dze <= c_dze; d_tag <= c_tag;
            d_E <= c_E + n_adj;
        end
    end

    // =====================================================================
    // E: round, range, pack, exceptions
    // =====================================================================
    wire p24 = d_fmt == F_S || d_fmt == F_F;
    wire p56 = d_fmt == F_D;
    wire r_g    = p24 ? d_w[39] : p56 ? d_w[7]  : d_w[10];
    wire r_l    = p24 ? d_w[40] : p56 ? d_w[8]  : d_w[11];
    wire r_l1   = p24 ? d_w[41] : p56 ? d_w[9]  : d_w[12];
    wire r_t    = d_st || (p24 ? |d_w[38:0] : p56 ? |d_w[6:0] : |d_w[9:0]);
    wire r_co   = p24 ? &d_w[63:40] : p56 ? &d_w[63:8] : &d_w[63:11];
    wire r_co1  = p24 ? &d_w[63:41] : p56 ? &d_w[63:9] : &d_w[63:12];
    wire r_inc  = rinc(d_mode, d_sign, r_l, r_g, r_t);
    wire r_inc1 = rinc(d_mode, d_sign, r_l1, r_l, r_g || r_t);   // rounded one bit shorter: the denormal grid at Emin-1
    wire [63:0] r_up = d_w + (p24 ? 64'h0000_0100_0000_0000 : p56 ? 64'h100 : 64'h800);
    wire [63:0] r_w  = r_inc ? r_up : d_w;
    wire        r_cy = r_inc && r_co;
    wire        r_zero = !d_w[63];

    reg signed [12:0] emin, emax, bias;
    always @* begin
        case (d_fmt)
        F_S:     begin emin = -13'sd126;  emax = 13'sd127;  bias = 13'sd1023; end
        F_G:     begin emin = -13'sd1024; emax = 13'sd1022; bias = 13'sd1025; end
        F_F:     begin emin = -13'sd128;  emax = 13'sd126;  bias = 13'sd1025; end
        F_D:     begin emin = -13'sd128;  emax = 13'sd126;  bias = 13'sd129;  end
        default: begin emin = -13'sd1022; emax = 13'sd1023; bias = 13'sd1023; end
        endcase
    end
    wire        r_edge = d_E == emin - 13'sd1;
    wire        r_tiny = d_E < emin - 13'sd1;
    wire        r_min  = r_edge && r_inc1 && r_co1;          // rounds up to the smallest normal
    wire        r_unf  = !r_zero && (r_tiny || (r_edge && !r_min));
    wire        r_ovf  = !r_zero && (d_E > emax || (d_E == emax && r_cy));
    wire        r_ine  = !r_zero && (r_g || r_t || r_unf || r_ovf || r_min);
    wire signed [12:0] r_eb = r_min ? emin + bias : d_E + bias + (r_cy ? 13'sd1 : 13'sd0);
    wire [54:0] r_fr = r_min ? 55'd0 : p56 ? r_w[62:8] : {r_w[62:11], 3'd0};
    reg  [63:0] r_pack;
    always @* begin
        if (p56)      r_pack = {d_sign, r_eb[7:0], r_fr};
        else if (p24) r_pack = {d_sign, r_eb[10:0], r_fr[54:32], 29'd0};
        else          r_pack = {d_sign, r_eb[10:0], r_fr[54:3]};
    end

    // flags (cpu.md 8.4): FPCR bits always (no INE from a divide), EXC_SUM by the qualifiers
    reg [63:0] e_res;
    reg  [5:0] e_fpcr;                   // IOV INE UNF OVF DZE INV
    reg  [5:0] e_exc;                    // IOV INE UNF FOV DZE INV
    always @* begin
        e_res = 64'd0; e_fpcr = 6'd0; e_exc = 6'd0;
        if (d_inv || d_dze) begin
            e_fpcr = {4'd0, d_dze, d_inv}; e_exc = {4'd0, d_dze, d_inv};
        end else if (d_path == P_CMP) begin
            e_res = {1'b0, d_cmp, 62'd0};
        end else if (d_path == P_TOINT) begin
            e_res = d_ires;
            e_fpcr = {d_iov, d_iov || d_tine, 4'd0};
            e_exc  = {d_iov && d_enu, d_eni && (d_iov || d_tine), 4'd0};
        end else begin
            if (r_zero) e_res = {d_zsign, 63'd0};
            else if (!r_unf && !r_ovf) e_res = r_pack;
            e_fpcr = {1'b0, r_ine && !d_div, r_unf, r_ovf, 2'd0};
            e_exc  = {1'b0, d_eni && (d_div || r_ine), r_unf && d_enu, r_ovf, 2'd0};
        end
    end

    always @(posedge clk) begin
        done <= d_v && !kill && !rst;
        done_tag <= d_tag;
        result <= e_res;
        fpcr_set <= e_fpcr;
        exc_sum <= {e_exc, d_qs && (|e_exc)};
        trap <= |e_exc;
    end
endmodule
