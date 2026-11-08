// 21064 (EV4) sequential reference core: one instruction at a time,
// written for correctness and readability, not speed. It is the model the
// pipelined core (docs/design/cpu.md 11) is co-simulated against, and the
// first core to run the T0 tests (tests/cpu, make -C verilator cputest).
//
// Implemented (cpu.md section numbers):
//   2.3/2.4  every integer operate (ev4_ialu, ev4_imul), LDA/LDAH, LDL/LDQ/
//            LDQ_U/LDx_L, STL/STQ/STQ_U/STx_C, branches, JMP/JSR/RET/
//            JSR_COROUTINE, MB/TRAPB/FETCH (no-ops here), RPCC, RC/RS
//   2.5      OPCDEC for BWX/FIX/CIX/MVI and the reserved opcodes; FP opcodes
//            take FEN while ICCSR.FPE = 0, OPCDEC otherwise (no FPU yet)
//   3        HW_MFPR/HW_MTPR (multi-select writes), HW_LD/HW_ST (PHY, ALT,
//            QW; low address bits cleared), HW_REI; allowed in PALmode or
//            kernel mode with ICCSR.HWE
//   4        ICCSR (FPE, MAP, HWE), EXC_ADDR, PS, PAL_BASE, ABOX_CTL (SPE_1,
//            SPE_2), ALT_MODE, MM_CSR/VA with lock, PAL_TEMP[0..31]; other
//            IPRs read 0 and ignore writes (STUB: TBs, interrupts, BIU, caches)
//   5        PAL entries for OPCDEC, FEN, UNALIGN, ARITH (precise: EXC_ADDR =
//            PC + 4 with bit 1 set), DTB_MISS native/PAL, ITB_MISS, CALL_PAL
//   6        translation by the superpages only: I-stream ICCSR.MAP, D-stream
//            SPE_1/SPE_2 (kernel); anything else misses (no ITB/DTB yet)
//   9.1      LDx_L/STx_C: a lock flag and address here (STUB until the
//            21071-CA holds the lock on the bus)
//
// Bus: one quadword-aligned access at a time. mem_addr = PA[33:3], mem_be =
// the byte lanes, mem_istream marks instruction fetches. The access is held
// until mem_ack; read data comes with it.
//
// Retire trace (simulation): dbg_retire pulses once per completed
// instruction with the alphaemu -T fields.
module ev4_seq (
    input  wire        clk,
    input  wire        rst,

    output reg         mem_req,
    output reg         mem_we,
    output reg         mem_istream,
    output reg  [33:3] mem_addr,
    output reg   [7:0] mem_be,
    output reg  [63:0] mem_wdata,
    input  wire        mem_ack,
    input  wire [63:0] mem_rdata,

    output reg         dbg_retire,
    output reg  [63:0] dbg_pc,
    output reg  [31:0] dbg_insn,
    output reg         dbg_rwr,
    output reg   [4:0] dbg_rnum,
    output reg  [63:0] dbg_rval,
    output reg         dbg_mwr,
    output reg  [63:0] dbg_maddr,
    output reg  [63:0] dbg_mval,
    output reg   [3:0] dbg_msize
);
    // ------------------------------------------------------------ state
    reg  [63:0] R [0:31];
    reg  [63:0] pc;
    reg         pal;                    // PALmode
    reg  [31:0] ir;

    // IPRs
    reg         iccsr_fpe, iccsr_map, iccsr_hwe;
    reg  [63:0] exc_addr;
    reg   [1:0] ps_cm;                  // 0 kernel, 1 executive, 2 supervisor, 3 user
    reg  [33:14] pal_base;
    reg  [15:0] abox_ctl;
    reg   [1:0] alt_cm;
    reg  [63:0] va;
    reg  [14:0] mm_csr;                 // [14:9] opcode, [8:4] ra, [3] FOW, [2] FOR, [1] ACV, [0] WR
    reg         mm_lock;
    reg  [63:0] pal_temp [0:31];
    reg  [31:0] cc;                     // cycle counter (RPCC low half)
    reg         intr_flag;              // RC/RS
    reg         lock_flag;
    reg  [33:4] lock_addr;

    wire spe1 = abox_ctl[4];
    wire spe2 = abox_ctl[5];

    // ------------------------------------------------------------ decode
    wire  [5:0] op    = ir[31:26];
    wire  [4:0] ra    = ir[25:21];
    wire  [4:0] rb    = ir[20:16];
    wire  [4:0] rc    = ir[4:0];
    wire  [6:0] func  = ir[11:5];
    wire        islit = ir[12];
    wire [63:0] av    = R[ra];
    wire [63:0] bv    = islit ? {56'd0, ir[20:13]} : R[rb];
    wire [63:0] disp16 = {{48{ir[15]}}, ir[15:0]};
    wire [63:0] disp12 = {{52{ir[11]}}, ir[11:0]};
    wire [63:0] bdisp = {{41{ir[20]}}, ir[20:0], 2'b00};
    wire [63:0] pc4   = pc + 64'd4;
    wire        kern  = ps_cm == 2'd0;
    wire        hw_ok = pal || (kern && iccsr_hwe);

    // ------------------------------------------------------------ execute units
    wire [63:0] alu_res;
    wire        alu_wr, alu_ovf, alu_ill;
    ev4_ialu alu (.op(op), .func(func), .a(av), .b(bv),
                  .res(alu_res), .wr(alu_wr), .ovf(alu_ovf), .illegal(alu_ill));

    reg         mul_start;
    wire        mul_busy, mul_done, mul_ovf, mul_ill;
    wire [63:0] mul_res;
    ev4_imul mul (.clk(clk), .rst(rst), .start(mul_start), .func(func), .a(av), .b(bv),
                  .busy(mul_busy), .done(mul_done), .res(mul_res), .ovf(mul_ovf), .illegal(mul_ill));

    // ------------------------------------------------------------ translation
    // D-stream: returns {miss, pa}
    function [34:0] dxlate;
        input [63:0] v; input [1:0] cm;
        if (spe2 && cm == 2'd0 && v[42:41] == 2'b10)            dxlate = {1'b0, v[33:0]};
        else if (spe1 && cm == 2'd0 && v[42:30] == 13'h1FFE)    dxlate = {1'b0, 4'd0, v[29:0]};
        else                                                    dxlate = {1'b1, v[33:0]};
    endfunction

    // ------------------------------------------------------------ IPR read
    reg [63:0] ipr_rd;
    always @* begin
        ipr_rd = 64'd0;
        if (ir[7])      ipr_rd = pal_temp[ir[4:0]];
        else if (ir[6]) case (ir[4:0])
            5'd4:  ipr_rd = {49'd0, mm_csr};
            5'd5:  ipr_rd = va;
            default: ipr_rd = 64'd0;
            endcase
        else if (ir[5]) case (ir[4:0])
            5'd2:  ipr_rd = {40'd0, iccsr_fpe, iccsr_map, iccsr_hwe, 21'd0};   // read bits 23, 22, 21
            5'd4:  ipr_rd = exc_addr;
            5'd9:  ipr_rd = {29'd0, ps_cm[1], 32'd0, ps_cm[0], 1'b0};         // CM1 bit 34, CM0 bit 1
            5'd11: ipr_rd = {30'd0, pal_base, 14'd0};
            default: ipr_rd = 64'd0;
            endcase
    end

    // ------------------------------------------------------------ sequencer
    localparam S_FETCH = 3'd0, S_IWAIT = 3'd1, S_EXEC = 3'd2, S_DWAIT = 3'd3, S_MUL = 3'd4;
    reg  [2:0] st;

    // memory operation in flight
    reg        d_load, d_quad, d_sext32, d_stc;
    reg  [4:0] d_reg;
    reg  [2:0] d_lane;                  // byte offset of the longword (0 or 4)
    reg [63:0] d_va;

    integer i;

    // take a PAL entry: off = offset from PAL_BASE, ea = EXC_ADDR to save
    task enter_pal;
        input [13:0] off; input [63:0] ea;
        begin
            exc_addr <= ea;
            pal      <= 1'b1;
            pc       <= {30'd0, pal_base, off};
            st       <= S_FETCH;
        end
    endtask

    // D-stream fault bookkeeping (cpu.md 5.3)
    task dfault;
        input [13:0] off; input [63:0] v; input wr;
        begin
            if (!mm_lock) begin
                va      <= v;
                mm_csr  <= {op, ra, 3'b000, wr};       // opcode, Ra, FOW FOR ACV = 0, WR
                mm_lock <= 1'b1;
            end
            enter_pal(off, pc | {63'd0, pal});
        end
    endtask

    task retire_reg;
        input [4:0] n; input [63:0] v;
        begin
            if (n != 5'd31) R[n] <= v;
            dbg_rwr  <= n != 5'd31;
            dbg_rnum <= n;
            dbg_rval <= v;
        end
    endtask

    always @(posedge clk) begin
        dbg_retire <= 1'b0;
        mul_start  <= 1'b0;
        cc <= cc + 32'd1;
        if (rst) begin
            for (i = 0; i < 32; i = i + 1) R[i] <= 64'd0;
            pc <= 64'd0; pal <= 1'b1; st <= S_FETCH;
            mem_req <= 1'b0;
            iccsr_fpe <= 1'b0; iccsr_map <= 1'b0; iccsr_hwe <= 1'b0;
            pal_base <= 20'd0; abox_ctl <= 16'd0; ps_cm <= 2'd0; alt_cm <= 2'd0;
            mm_lock <= 1'b0; lock_flag <= 1'b0; intr_flag <= 1'b0; cc <= 32'd0;
        end else case (st)
        // -------------------------------------------------------- fetch
        S_FETCH: begin
            dbg_rwr <= 1'b0; dbg_mwr <= 1'b0;
            if (pc[1:0] != 2'b00) begin
                // only HW_REI/JMP mask the low bits, so this cannot happen
                enter_pal(14'h03E0, pc);
            end else if (pal || (iccsr_map && kern && pc[42:41] == 2'b10)) begin
                mem_req     <= 1'b1;
                mem_we      <= 1'b0;
                mem_istream <= 1'b1;
                mem_addr    <= pc[33:3];
                mem_be      <= pc[2] ? 8'hF0 : 8'h0F;
                st          <= S_IWAIT;
            end else
                enter_pal(14'h03E0, pc);            // ITB_MISS (no ITB yet)
        end
        S_IWAIT: if (mem_ack) begin
            mem_req <= 1'b0;
            ir      <= pc[2] ? mem_rdata[63:32] : mem_rdata[31:0];
            st      <= S_EXEC;
        end
        // -------------------------------------------------------- execute
        S_EXEC: begin : exec
            reg [63:0] ea;
            reg [34:0] xl;
            reg        ok, lq, ll, lstc;
            dbg_pc   <= pc;
            dbg_insn <= ir;
            st <= S_FETCH;
            case (op)
            // ---------------------------------------------- CALL_PAL
            6'h00: begin
                if (ir[25:8] != 18'd0 || ir[6] || (!ir[7] && !kern && !pal))
                    enter_pal(14'h13E0, pc | {63'd0, pal});                 // OPCDEC
                else
                    enter_pal({1'b1, ir[7], ir[5:0], 6'd0}, pc4 | {63'd0, pal});
            end
            // ---------------------------------------------- LDA, LDAH
            6'h08: begin retire_reg(ra, R[rb] + disp16); pc <= pc4; dbg_retire <= 1'b1; end
            6'h09: begin retire_reg(ra, R[rb] + {disp16[47:0], 16'd0}); pc <= pc4; dbg_retire <= 1'b1; end
            // ---------------------------------------------- integer loads/stores
            6'h0B, 6'h0F, 6'h28, 6'h29, 6'h2A, 6'h2B, 6'h2C, 6'h2D, 6'h2E, 6'h2F: begin
                ea = R[rb] + disp16;
                if (op == 6'h0B || op == 6'h0F) ea = {ea[63:3], 3'b000};
                lq   = op == 6'h0B || op == 6'h0F || op == 6'h29 || op == 6'h2B ||
                       op == 6'h2D || op == 6'h2F;
                ll   = op == 6'h0B || op[5:2] == 4'hA;
                lstc = op == 6'h2E || op == 6'h2F;
                xl = dxlate(ea, ps_cm);
                if (ll && ra == 5'd31 && op != 6'h2A && op != 6'h2B) begin
                    // a load to R31 (UNOP is LDQ_U R31): no access, no
                    // exceptions (ARM 4.2; prefetch hint on later chips)
                    pc <= pc4; dbg_retire <= 1'b1;
                end else if (lq ? ea[2:0] != 3'd0 : ea[1:0] != 2'd0)
                    dfault(14'h11E0, ea, !ll);                              // UNALIGN
                else if (xl[34])
                    dfault(pal ? 14'h09E0 : 14'h08E0, ea, !ll);             // DTB_MISS
                else if (lstc && !(lock_flag && lock_addr == xl[33:4])) begin
                    // STx_C fails: no store, Ra = 0
                    lock_flag <= 1'b0;
                    retire_reg(ra, 64'd0); pc <= pc4; dbg_retire <= 1'b1;
                end else begin
                    if (op == 6'h2A || op == 6'h2B) begin lock_flag <= 1'b1; lock_addr <= xl[33:4]; end
                    if (lstc) lock_flag <= 1'b0;
                    start_d(xl[33:0], ea, ll, lq, op == 6'h28 || op == 6'h2A, ra, av, lstc);
                end
            end
            // ---------------------------------------------- operate
            6'h10, 6'h11, 6'h12: begin
                if (alu_ill) enter_pal(14'h13E0, pc | {63'd0, pal});
                else begin
                    if (alu_wr) retire_reg(rc, alu_res);
                    dbg_retire <= 1'b1;
                    pc <= pc4;
                    if (alu_ovf) begin
                        // precise ARITH: the result is written, then the trap
                        // (EXC_SUM is a STUB until the FPU brings its bits)
                        enter_pal(14'h0060, pc4 | 64'd2 | {63'd0, pal});
                    end
                end
            end
            6'h13: begin
                if (mul_ill) enter_pal(14'h13E0, pc | {63'd0, pal});
                else begin mul_start <= 1'b1; st <= S_MUL; end
            end
            // ---------------------------------------------- FP (no FPU yet)
            6'h14, 6'h15, 6'h16, 6'h17, 6'h20, 6'h21, 6'h22, 6'h23, 6'h24, 6'h25, 6'h26, 6'h27,
            6'h31, 6'h32, 6'h33, 6'h35, 6'h36, 6'h37: begin
                if (op == 6'h14) enter_pal(14'h13E0, pc | {63'd0, pal});    // FIX: OPCDEC
                else if (op[5:2] == 4'h8 && ra == 5'd31) begin              // LDx F31: a prefetch hint, no-op
                    pc <= pc4; dbg_retire <= 1'b1;
                end
                else if (!iccsr_fpe) enter_pal(14'h17E0, pc | {63'd0, pal});// FEN
                else enter_pal(14'h13E0, pc | {63'd0, pal});                // STUB: FPU
            end
            // ---------------------------------------------- misc (opcode 18)
            6'h18: begin
                case (ir[15:0])
                16'hC000: retire_reg(ra, {32'd0, cc});                      // RPCC
                16'hE000: begin retire_reg(ra, {63'd0, intr_flag}); intr_flag <= 1'b0; end   // RC
                16'hF000: begin retire_reg(ra, {63'd0, intr_flag}); intr_flag <= 1'b1; end   // RS
                default: ;                                                  // TRAPB, MB, FETCH ...
                endcase
                pc <= pc4; dbg_retire <= 1'b1;
            end
            // ---------------------------------------------- jumps
            6'h1A: begin
                retire_reg(ra, pc4);
                pc <= {R[rb][63:2], 2'b00};
                dbg_retire <= 1'b1;
            end
            // ---------------------------------------------- PAL instructions
            6'h19: if (!hw_ok) enter_pal(14'h13E0, pc | {63'd0, pal}); else begin   // HW_MFPR
                retire_reg(ra, ipr_rd);
                if (ir[6] && !ir[7] && ir[4:0] == 5'd5) mm_lock <= 1'b0;   // VA read unlocks
                pc <= pc4; dbg_retire <= 1'b1;
            end
            6'h1D: if (!hw_ok) enter_pal(14'h13E0, pc | {63'd0, pal}); else begin   // HW_MTPR
                if (ir[7]) pal_temp[ir[4:0]] <= R[rb];
                if (ir[6]) case (ir[4:0])
                    5'd14: abox_ctl <= R[rb][15:0];
                    5'd15: alt_cm   <= R[rb][4:3];
                    default: ;
                    endcase
                if (ir[5]) case (ir[4:0])
                    5'd2: begin iccsr_fpe <= R[rb][42]; iccsr_map <= R[rb][41]; iccsr_hwe <= R[rb][40]; end
                    5'd4: exc_addr <= R[rb];
                    5'd9: ps_cm    <= R[rb][4:3];
                    5'd11: pal_base <= R[rb][33:14];
                    default: ;
                    endcase
                pc <= pc4; dbg_retire <= 1'b1;
            end
            6'h1E: if (!hw_ok) enter_pal(14'h13E0, pc | {63'd0, pal}); else begin   // HW_REI
                pc  <= {exc_addr[63:2], 2'b00};
                pal <= exc_addr[0];
                dbg_retire <= 1'b1;
            end
            6'h1B, 6'h1F: if (!hw_ok) enter_pal(14'h13E0, pc | {63'd0, pal}); else begin   // HW_LD/HW_ST
                ea = R[rb] + disp12;
                ea = ir[12] ? {ea[63:3], 3'b000} : {ea[63:2], 2'b00};
                if (ir[15]) xl = {1'b0, ea[33:0]};
                else        xl = dxlate(ea, ir[14] ? alt_cm : ps_cm);
                if (xl[34]) dfault(pal ? 14'h09E0 : 14'h08E0, ea, op == 6'h1F);
                else start_d(xl[33:0], ea, op == 6'h1B, ir[12], !ir[12], ra, av, 1'b0);
            end
            // ---------------------------------------------- branches
            6'h30, 6'h34: begin retire_reg(ra, pc4); pc <= pc4 + bdisp; dbg_retire <= 1'b1; end
            6'h38, 6'h39, 6'h3A, 6'h3B, 6'h3C, 6'h3D, 6'h3E, 6'h3F: begin
                case (op[2:0])
                3'd0: ok = !av[0];
                3'd1: ok = av == 64'd0;
                3'd2: ok = av[63];
                3'd3: ok = av[63] || av == 64'd0;
                3'd4: ok = av[0];
                3'd5: ok = av != 64'd0;
                3'd6: ok = !av[63];
                default: ok = !av[63] && av != 64'd0;
                endcase
                pc <= ok ? pc4 + bdisp : pc4;
                dbg_retire <= 1'b1;
            end
            // ---------------------------------------------- the rest
            default: enter_pal(14'h13E0, pc | {63'd0, pal});                // OPCDEC
            endcase
        end
        // -------------------------------------------------------- data access
        S_DWAIT: if (mem_ack) begin
            mem_req <= 1'b0;
            if (d_load) begin : ld
                reg [63:0] v;
                v = mem_rdata;
                if (!d_quad) v = d_lane[2] ? {{32{v[63]}}, v[63:32]} : {{32{v[31]}}, v[31:0]};
                retire_reg(d_reg, v);
            end else if (d_stc)
                retire_reg(d_reg, 64'd1);
            pc <= pc4;
            dbg_retire <= 1'b1;
            st <= S_FETCH;
        end
        // -------------------------------------------------------- multiply
        S_MUL: if (mul_done) begin
            retire_reg(rc, mul_res);
            dbg_pc <= pc; dbg_insn <= ir;
            dbg_retire <= 1'b1;
            pc <= pc4;
            st <= S_FETCH;
            if (mul_ovf) enter_pal(14'h0060, pc4 | 64'd2 | {63'd0, pal});
        end
        default: st <= S_FETCH;
        endcase
    end

    // start a data access: pa, va (for the trace), load?, quad?, sign-extend
    // longword (all longword loads do), register, store data, STx_C
    task start_d;
        input [33:0] pa; input [63:0] v; input load, quad, lsx; input [4:0] r;
        input [63:0] sd; input stc;
        begin
            mem_req     <= 1'b1;
            mem_we      <= !load;
            mem_istream <= 1'b0;
            mem_addr    <= pa[33:3];
            mem_be      <= quad ? 8'hFF : pa[2] ? 8'hF0 : 8'h0F;
            mem_wdata   <= quad ? sd : {sd[31:0], sd[31:0]};
            d_load <= load; d_quad <= quad; d_sext32 <= lsx; d_stc <= stc;
            d_reg  <= r;
            d_lane <= {pa[2], 2'b00};
            d_va   <= v;
            if (!load) begin
                dbg_mwr   <= 1'b1;
                dbg_maddr <= v;
                dbg_mval  <= quad ? sd : {32'd0, sd[31:0]};
                dbg_msize <= quad ? 4'd8 : 4'd4;
            end
            st <= S_DWAIT;
        end
    endtask
endmodule
