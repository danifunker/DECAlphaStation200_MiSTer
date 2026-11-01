// 21064 (EV4) pipelined core for the 100 MHz target (docs/design/pipeline.md).
//
//   F0  next PC (combinational): W redirect > X redirect > fill restart > PC + 4
//   F1  I-cache data/tag/valid read (RAM address = next PC)
//   F2  registered RAM outputs: translation, tag compare, instruction select
//   D   decode, register file read (3 ports), hazards, forwarding select
//   X   fast ALU (opcodes 10/11, LDA/LDAH, links) with the X->X forwarding
//       loop; shift/byte unit; address adder; branches; multiplier; IPR reads
//   M1  D-cache data/tag/valid read, D-stream translation, alignment
//   M2  hit, store-to-load merge, load align; stores to the cache and the
//       write buffer; misses and uncached accesses on the bus
//   W   register write, IPR side effects, exceptions (precise), retire trace
//
// Latencies (the 21064's): fast ops 1 cycle (back-to-back forwarding),
// shifts/byte ops/multiply/IPR reads 2, loads and STx_C 3. PAL instructions
// (CALL_PAL, HW_*, RC/RS) run serialized: issued into an empty pipeline,
// nothing younger issues until they retire.
//
// After reset the SROM bitstream is loaded into the I-cache the way the
// 21064 does it (HRM SROM chapter; tools/srom/srom.py is the same format):
// per 32-byte block, LSB first: LW0 LW2 LW4 LW6 TAG(21) ASN(6) ASM V LW1 LW3
// LW5 LW7 BHT(8) = 293 bits, 256 blocks; bits past the 65,536 of an
// XC1765D read as 0, so those blocks load invalid.
//
// Architectural coverage is ev4_seq's (its header lists it); ev4_seq is the
// reference this core is checked against. Bus and debug ports are ev4_seq's.
module ev4_core (
    input  wire        clk,
    input  wire        rst,

    // SROM (cpu.md 1.4): icmode 0 = after reset, load the I-cache from the
    // serial ROM bitstream (a byte ROM read at srom_addr, data one clock
    // after the registered address), then start at PC 0; 1 = start with an
    // empty I-cache (the T0 tests)
    input  wire        icmode,
    output reg  [12:0] srom_addr,
    input  wire  [7:0] srom_data,

    // the SROM port after the load: a bit-banged serial line (SL_XMIT[4]
    // drives sRomClk_h, SL_RCV[3] reads sRomD_h); the DROM's console uses it
    output reg         sl_xmit,
    input  wire        sl_rcv,

    // the six interrupt pins, irq_h[5:0] (level; AS200 wiring HARDWARE.md 3).
    // Read through HIRR; interrupt delivery is a STUB (to come with HIER)
    input  wire  [5:0] irq_h,

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
    // ================================================================ classes
    localparam C_NOP = 4'd0, C_ALU = 4'd1, C_SHF = 4'd2, C_MUL = 4'd3, C_LDA = 4'd4,
               C_LD  = 4'd5, C_ST  = 4'd6, C_BR  = 4'd7, C_CBR = 4'd8, C_JMP = 4'd9,
               C_MISC = 4'd10, C_MFPR = 4'd11, C_MTPR = 4'd12, C_REI = 4'd13, C_CPAL = 4'd14;
    // exception codes carried down the pipe
    localparam E_NONE = 4'd0, E_OPCDEC = 4'd1, E_FEN = 4'd2, E_ITBM = 4'd3,
               E_UNAL = 4'd4, E_DTBM = 4'd5, E_ARITH = 4'd6, E_DFAULT = 4'd7, E_ITBACV = 4'd8;

    // ================================================================ architectural state (W)
    reg         pal;
    reg         iccsr_fpe, iccsr_map, iccsr_hwe;
    reg  [63:0] exc_addr;
    reg   [1:0] ps_cm;
    reg [33:14] pal_base;
    reg  [15:0] abox_ctl;
    reg   [1:0] alt_cm;
    reg  [63:0] va_ipr;
    reg  [14:0] mm_csr;
    reg         mm_lock;
    reg  [31:0] cc;                     // CC[31:0]: counts while cc_en (CC_CTL)
    reg  [31:0] cc_hi;                  // CC[63:32]: written through CC, returned by RPCC
    reg         cc_en;
    reg         intr_flag;
    reg         lock_flag;
    reg  [33:4] lock_addr;
    wire        kern  = ps_cm == 2'd0;
    wire        hw_ok = pal || (kern && iccsr_hwe);
    wire        spe1  = abox_ctl[4];
    wire        spe2  = abox_ctl[5];
    wire        dc_ena = abox_ctl[10];

    reg  [63:0] pal_temp [0:31];

    // ---------------------------------------------------------------- TBs (cpu.md 4.2, 4.3, 6)
    reg  [42:13] tb_tag;                // TB_TAG: VA of the next PTE write
    reg   [1:0] tb_gh;                  // TB_CTL[6:5]
    // ITB: entries 0-7 small (8 KB), 8-11 large (4 MB); no ASN (ASM kept for ITBASM)
    reg  [11:0] itb_v, itb_asm;
    reg  [42:13] itb_tag [0:11];
    reg  [33:13] itb_pfn [0:11];
    reg   [3:0] itb_re  [0:11];         // {URE, SRE, ERE, KRE}
    reg   [2:0] itb_sp;                 // small replacement pointer
    reg   [1:0] itb_lp;                 // large replacement pointer
    reg  [34:0] itb_temp;               // ITB_PTE_TEMP read format [34:0]
    // DTB: 32 entries, any granularity
    reg  [31:0] dtb_v, dtb_asm;
    reg  [42:13] dtb_tag [0:31];
    reg   [1:0] dtb_gh  [0:31];
    reg  [33:13] dtb_pfn [0:31];
    reg   [9:0] dtb_pr  [0:31];         // {FOW, FOR, UWE, SWE, EWE, KWE, URE, SRE, ERE, KRE}
    reg   [4:0] dtb_p;
    reg  [34:0] dtb_temp;               // DTB_PTE_TEMP read format [34:0]

    function dtb_hit_i;                 // does DTB entry i map va?
        input v; input [42:13] tag; input [1:0] gh; input [42:13] va;
        dtb_hit_i = v && va[42:22] == tag[42:22] &&
                    (gh == 2'd3 || va[21:19] == tag[21:19]) &&
                    (gh[1]      || va[18:16] == tag[18:16]) &&
                    (gh != 2'd0 || va[15:13] == tag[15:13]);
    endfunction

    // ================================================================ forward declarations
    reg         w_v;  reg [63:0] w_pc; reg [31:0] w_ir; reg [3:0] w_cls; reg [3:0] w_exc;
    reg  [63:0] w_res; reg [4:0] w_dst; reg w_dst_v;
    reg  [63:0] w_va; reg w_cmf;   // *_cmf: a CMOV whose condition was false (rewrites Rc, not traced)
    reg         w_st;  reg [63:0] w_sdata; reg [3:0] w_ssize;
    wire        w_redir;
    reg  [63:0] w_target;

    wire        stall_m2, stall_m1, stall_x, stall_d;
    wire        x_redir;
    wire [63:0] x_target_r;

    // ================================================================ fetch
    localparam FS_FETCH = 1'b0, FS_FILL = 1'b1;
    reg         fstate;
    reg  [63:0] pc_f1;  reg v_f1;
    reg  [63:0] pc_f2;  reg v_f2;
    reg  [63:0] restart_pc;
    reg  [33:5] ifill_line;
    reg         ifill_done;            // pulse: the fill's line is valid, restart the fetch
    reg         ifill_issued;          // the fill's bus transaction has been started

    // SROM loader
    reg         ld_active;             // loading the I-cache from the SROM
    reg         ld_start;              // pulse: the last block landed, fetch from PC 0
    reg         ld_fin;
    reg [292:0] ld_sr;
    reg   [8:0] ld_bcnt;               // bits of the current block
    reg   [8:0] ld_blk;
    reg   [2:0] ld_bitpos;
    reg   [7:0] ld_byte;
    reg         ld_byte_ok;
    reg   [1:0] ld_fetch;              // byte fetch in progress: cycles waited
    reg  [13:0] ld_baddr;              // next byte (8192 = past the end)
    reg   [2:0] ld_wph;                // block write phase: 1-4 data, 5 tag

    // I-cache: 1024 x 64 data, 256 x {valid, tag[20:0]} tags. The valid bit
    // lives in the tag RAM (no 256:1 lookup after the next-PC logic); a flush
    // is a 256-cycle sweep (isweep), at reset with an empty I-cache.
    wire [63:0] ic_q;
    wire [21:0] ict_qv;
    wire [20:0] ict_q = ict_qv[20:0];
    wire        icv_q = ict_qv[21];
    reg         isweep; reg [7:0] isw_idx;
    reg  [63:0] restart_after;          // fetch restarts here after a sweep or the SROM load
    reg         ic_we;  reg [9:0] ic_wa; reg [63:0] ic_wd;
    reg         ict_we; reg [7:0] ict_wa; reg [20:0] ict_wd; reg ict_v;

    reg  [63:0] q2; reg [20:0] t2; reg v2;    // F2 copies of the RAM outputs

    // F2: translation (PALmode physical, the superpage, the ITB) and hit
    reg  [11:0] itb_m;
    reg  [33:13] itb_spfn;
    reg   [3:0] itb_sre;
    reg         itb_large;
    integer ii;
    always @* begin
        itb_spfn = 21'd0; itb_sre = 4'd0; itb_large = 1'b0;
        for (ii = 0; ii < 12; ii = ii + 1) begin
            itb_m[ii] = itb_v[ii] && pc_f2[42:22] == itb_tag[ii][42:22] &&
                        (ii >= 8 || pc_f2[21:13] == itb_tag[ii][21:13]);
            if (itb_m[ii]) begin itb_spfn = itb_spfn | itb_pfn[ii]; itb_sre = itb_sre | itb_re[ii]; end
            if (itb_m[ii] && ii >= 8) itb_large = 1'b1;
        end
    end
    wire        f2_phys  = pal || (iccsr_map && kern && pc_f2[42:41] == 2'b10);
    wire        f2_itbm  = !f2_phys && itb_m == 12'd0;
    wire        f2_acv   = !f2_phys && !f2_itbm && !itb_sre[ps_cm];
    wire        f2_tr_ok = !f2_itbm && !f2_acv;
    wire [33:0] f2_pa    = f2_phys ? pc_f2[33:0] :
                           itb_large ? {itb_spfn[33:22], pc_f2[21:0]} : {itb_spfn, pc_f2[12:0]};
    wire        f2_hit   = v2 && t2 == f2_pa[33:13];
    wire        f2_miss  = v_f2 && f2_tr_ok && !f2_hit && fstate == FS_FETCH;
    wire [31:0] f2_insn  = pc_f2[2] ? q2[63:32] : q2[31:0];
    wire        f_hold   = stall_d;

    // Next PC. The X redirect (a taken branch or jump) decides last: it is
    // the late signal (operand flop -> condition), so npc_o is everything
    // else, and the X target and its I-cache valid bit are looked up in
    // parallel and picked by x_take at the very end (cpu-timing.md).
    reg  [63:0] npc_o;
    reg         nv_o;
    reg         kill_o;
    wire        x_take = x_redir && !w_redir && !ld_active && !ld_start && !isweep && fstate == FS_FETCH;
    wire [63:0] npc  = x_take ? x_target_r : npc_o;
    wire        nv   = x_take ? 1'b1 : nv_o;
    wire        kill_f2 = kill_o || x_redir;
    always @* begin
        npc_o = pc_f1; nv_o = v_f1; kill_o = 1'b0;
        if (ld_active || isweep) begin
            npc_o = 64'd0; nv_o = 1'b0; kill_o = 1'b1;
        end else if (ld_start) begin
            npc_o = restart_after; nv_o = 1'b1; kill_o = 1'b1;
        end else if (w_redir) begin
            kill_o = 1'b1;
            if (fstate == FS_FILL) nv_o = 1'b0;
            else begin npc_o = w_target; nv_o = 1'b1; end
        end else if (x_redir) begin
            // only reached in FS_FILL (otherwise x_take wins): the fill finishes first
            kill_o = 1'b1; nv_o = 1'b0;
        end else if (fstate == FS_FILL) begin
            if (ifill_done) begin npc_o = restart_pc; nv_o = 1'b1; end
            else nv_o = 1'b0;
        end else if (f2_miss) begin
            nv_o = 1'b0; kill_o = 1'b1;
        end else if (!f_hold)
            npc_o = pc_f1 + 64'd4;
    end

    ev4_ram #(.AW(10), .DW(64), .BE(1)) icache_d (.clk(clk), .raddr(npc[12:3]), .rdata(ic_q),
        .we(ic_we), .waddr(ic_wa), .wdata(ic_wd), .wbe(1'b1));
    ev4_ram #(.AW(8), .DW(22), .BE(1)) icache_t (.clk(clk), .raddr(npc[12:5]), .rdata(ict_qv),
        .we(ict_we), .waddr(ict_wa), .wdata({ict_v, ict_wd}), .wbe(1'b1));

    // ================================================================ D stage
    reg         d_v;  reg [63:0] d_pc; reg [31:0] d_ir; reg [3:0] d_exc;

    // register file: three read ports (A = Ra, B = Rb, C = Rc for CMOV)
    wire [63:0] rf_a, rf_b, rf_c;
    wire  [4:0] rfa_addr = f_hold ? d_ir[25:21] : f2_insn[25:21];
    wire  [4:0] rfb_addr = f_hold ? d_ir[20:16] : f2_insn[20:16];
    wire  [4:0] rfc_addr = f_hold ? d_ir[4:0]   : f2_insn[4:0];
    wire        rf_we = w_v && w_dst_v && (w_exc == E_NONE || w_exc == E_ARITH);
    ev4_ram #(.AW(5), .DW(64), .BE(1)) rf0 (.clk(clk), .raddr(rfa_addr), .rdata(rf_a),
        .we(rf_we), .waddr(w_dst), .wdata(w_res), .wbe(1'b1));
    ev4_ram #(.AW(5), .DW(64), .BE(1)) rf1 (.clk(clk), .raddr(rfb_addr), .rdata(rf_b),
        .we(rf_we), .waddr(w_dst), .wdata(w_res), .wbe(1'b1));
    ev4_ram #(.AW(5), .DW(64), .BE(1)) rf2 (.clk(clk), .raddr(rfc_addr), .rdata(rf_c),
        .we(rf_we), .waddr(w_dst), .wdata(w_res), .wbe(1'b1));

    // decode
    wire  [5:0] d_op   = d_ir[31:26];
    wire  [4:0] d_ra   = d_ir[25:21];
    wire  [4:0] d_rb   = d_ir[20:16];
    wire  [4:0] d_rc   = d_ir[4:0];
    wire  [6:0] d_func = d_ir[11:5];
    wire        d_lit  = d_ir[12];
    wire        alu_ill_d, mul_ill_d;
    ev4_ialu dchk (.op(d_op), .func(d_func), .a(64'd0), .b(64'd0),
                   .res(), .wr(), .ovf(), .illegal(alu_ill_d));
    assign mul_ill_d = !(d_func == 7'h00 || d_func == 7'h20 || d_func == 7'h30 ||
                         d_func == 7'h40 || d_func == 7'h60);
    wire        d_cmov = d_op == 6'h11 && (d_func == 7'h14 || d_func == 7'h16 || d_func == 7'h24 ||
                         d_func == 7'h26 || d_func == 7'h44 || d_func == 7'h46 ||
                         d_func == 7'h64 || d_func == 7'h66);

    reg  [3:0] dc_cls;
    reg  [4:0] dc_dst; reg dc_dst_v;
    reg        dc_ua, dc_ub;           // reads Ra, Rb
    reg        dc_fast, dc_ldlat;      // result forwardable from X / only from W
    reg        dc_ser;
    reg  [3:0] dc_exc;
    always @* begin
        dc_cls = C_NOP; dc_dst = d_ra; dc_dst_v = 1'b0; dc_ua = 1'b0; dc_ub = 1'b0;
        dc_fast = 1'b0; dc_ldlat = 1'b0; dc_ser = 1'b0; dc_exc = E_NONE;
        case (d_op)
        6'h00: begin dc_cls = C_CPAL; dc_ser = 1'b1; end
        6'h08, 6'h09: begin dc_cls = C_LDA; dc_dst_v = 1'b1; dc_ub = 1'b1; dc_fast = 1'b1; end
        6'h0B, 6'h28, 6'h29, 6'h2A, 6'h2B: begin
            if (d_ra == 5'd31 && d_op != 6'h2A && d_op != 6'h2B) dc_cls = C_NOP;   // load to R31: no-op
            else begin dc_cls = C_LD; dc_dst_v = 1'b1; dc_ub = 1'b1; dc_ldlat = 1'b1; end
        end
        6'h0F, 6'h2C, 6'h2D: begin dc_cls = C_ST; dc_ua = 1'b1; dc_ub = 1'b1; end
        6'h2E, 6'h2F: begin dc_cls = C_ST; dc_ua = 1'b1; dc_ub = 1'b1; dc_dst_v = 1'b1; dc_ldlat = 1'b1; end
        6'h10, 6'h11: begin
            dc_cls = C_ALU; dc_dst = d_rc; dc_dst_v = 1'b1; dc_ua = 1'b1; dc_ub = !d_lit; dc_fast = 1'b1;
            if (alu_ill_d) dc_exc = E_OPCDEC;
        end
        6'h12: begin
            dc_cls = C_SHF; dc_dst = d_rc; dc_dst_v = 1'b1; dc_ua = 1'b1; dc_ub = !d_lit;
            if (alu_ill_d) dc_exc = E_OPCDEC;
        end
        6'h13: begin
            dc_cls = C_MUL; dc_dst = d_rc; dc_dst_v = 1'b1; dc_ua = 1'b1; dc_ub = !d_lit;
            if (mul_ill_d) dc_exc = E_OPCDEC;
        end
        6'h14, 6'h15, 6'h16, 6'h17, 6'h20, 6'h21, 6'h22, 6'h23, 6'h24, 6'h25, 6'h26, 6'h27,
        6'h31, 6'h32, 6'h33, 6'h35, 6'h36, 6'h37:
            dc_exc = (d_op == 6'h14 || iccsr_fpe) ? E_OPCDEC : E_FEN;      // no FPU yet
        6'h18: begin
            dc_cls = C_MISC;
            if (d_ir[15:0] == 16'hC000) dc_dst_v = 1'b1;                     // RPCC
            if (d_ir[15:0] == 16'hE000 || d_ir[15:0] == 16'hF000) begin dc_dst_v = 1'b1; dc_ser = 1'b1; end
        end
        6'h19: begin dc_cls = C_MFPR; dc_dst_v = 1'b1; dc_ser = 1'b1; if (!hw_ok) dc_exc = E_OPCDEC; end
        6'h1A: begin dc_cls = C_JMP; dc_dst_v = 1'b1; dc_ub = 1'b1; dc_fast = 1'b1; end
        6'h1B: begin dc_cls = C_LD; dc_dst_v = 1'b1; dc_ub = 1'b1; dc_ldlat = 1'b1; dc_ser = 1'b1;
                     if (!hw_ok) dc_exc = E_OPCDEC; end
        6'h1D: begin dc_cls = C_MTPR; dc_ub = 1'b1; dc_ser = 1'b1; if (!hw_ok) dc_exc = E_OPCDEC; end
        6'h1E: begin dc_cls = C_REI; dc_ser = 1'b1; if (!hw_ok) dc_exc = E_OPCDEC; end
        6'h1F: begin dc_cls = C_ST; dc_ua = 1'b1; dc_ub = 1'b1; dc_ser = 1'b1;
                     if (!hw_ok) dc_exc = E_OPCDEC; end
        6'h30, 6'h34: begin dc_cls = C_BR; dc_dst_v = 1'b1; dc_fast = 1'b1; end
        6'h38, 6'h39, 6'h3A, 6'h3B, 6'h3C, 6'h3D, 6'h3E, 6'h3F: begin dc_cls = C_CBR; dc_ua = 1'b1; end
        default: dc_exc = E_OPCDEC;
        endcase
        if (d_exc != E_NONE) begin                    // fetch fault: nothing else happens
            dc_exc = d_exc; dc_cls = C_NOP; dc_dst_v = 1'b0; dc_ua = 1'b0; dc_ub = 1'b0; dc_ser = 1'b0;
        end
        if (dc_exc != E_NONE) begin dc_dst_v = 1'b0; dc_ser = 1'b1; end   // faults retire alone
        if (dc_dst == 5'd31) dc_dst_v = 1'b0;
    end
    wire dc_uc = d_cmov;

    // ================================================================ X stage registers
    reg         x_v;  reg [63:0] x_pc; reg [31:0] x_ir; reg [3:0] x_cls; reg [3:0] x_exc;
    reg  [63:0] x_a, x_b, x_c;
    reg   [4:0] x_dst; reg x_dst_v; reg x_fast; reg x_ldlat; reg x_ser;
    reg  [63:0] x_btarget;
    reg  [63:0] x_link;                 // PC + 4, computed in D
    reg  [63:0] x_ipr;                  // HW_MFPR's IPR value, read in D (serialized)
    reg         x_sel_lda, x_sel_link;  // fast-result selects, decoded in D

    // M1 / M2 registers (declared here for forwarding)
    reg         m1_v;  reg [63:0] m1_pc; reg [31:0] m1_ir; reg [3:0] m1_cls; reg [3:0] m1_exc;
    reg  [63:0] m1_rf, m1_rs, m1_va, m1_sd; reg m1_cmf; reg m1_isf;
    wire [63:0] m1_res = m1_isf ? m1_rf : m1_rs;    // fast and slow results come from separate flops
    reg   [4:0] m1_dst; reg m1_dst_v; reg m1_ldlat;
    reg         m2_v;  reg [63:0] m2_pc; reg [31:0] m2_ir; reg [3:0] m2_cls; reg [3:0] m2_exc;
    reg  [63:0] m2_res, m2_va, m2_sd; reg m2_cmf;
    reg  [33:0] m2_pa;
    reg   [2:0] m2_fb, w_fb;            // D_FAULT reason: {FOW, FOR, ACV}
    reg   [4:0] m2_dst; reg m2_dst_v; reg m2_ldlat;
    reg         r_v; reg [4:0] r_dst; reg [63:0] r_res;      // retired last cycle

    // ---------------------------------------------------------------- X execute (needed by forwarding)
    wire [63:0] fa_res, sh_res;
    wire        fa_wr, fa_ovf, sh_ovf;
    ev4_ialu xfast (.op({5'b01000, x_ir[26]}), .func(x_ir[11:5]), .a(x_a), .b(x_b),
                    .res(fa_res), .wr(fa_wr), .ovf(fa_ovf), .illegal());
    ev4_ialu xshf  (.op(6'h12), .func(x_ir[11:5]), .a(x_a), .b(x_b),
                    .res(sh_res), .wr(), .ovf(sh_ovf), .illegal());
    wire [63:0] x_disp = x_cls == C_LD || x_cls == C_ST ?
                         ((x_ir[31:26] == 6'h1B || x_ir[31:26] == 6'h1F) ? {{52{x_ir[11]}}, x_ir[11:0]}
                                                                         : {{48{x_ir[15]}}, x_ir[15:0]})
                       : (x_ir[31:26] == 6'h09 ? {{32{x_ir[15]}}, x_ir[15:0], 16'd0}
                                               : {{48{x_ir[15]}}, x_ir[15:0]});
    wire [63:0] agen   = x_b + x_disp;
    wire        x_hwm  = x_ir[31:26] == 6'h1B || x_ir[31:26] == 6'h1F;
    wire [63:0] x_va   = (x_ir[31:26] == 6'h0B || x_ir[31:26] == 6'h0F || (x_hwm && x_ir[12]))
                         ? {agen[63:3], 3'b000} : x_hwm ? {agen[63:2], 2'b00} : agen;
    // the fast result: what the X->X loop forwards
    wire [63:0] fast_res = x_sel_lda ? agen : x_sel_link ? x_link :
                           (fa_wr ? fa_res : x_c);            // a false CMOV keeps Rc

    // ---------------------------------------------------------------- hazards and forwarding (D)
    function hit_src;
        input v; input dv; input [4:0] dst; input [4:0] src;
        hit_src = v && dv && dst == src && src != 5'd31;
    endfunction

    reg        haz;
    reg [63:0] fwd_a, fwd_b, fwd_c;
    reg        loop_a, loop_b, loop_c;
    task fwd;
        input [4:0] src; input used; input [63:0] rfv;
        output [63:0] val; output loop; output stall;
        begin
            val = rfv; loop = 1'b0; stall = 1'b0;
            if (used && src != 5'd31) begin
                if (hit_src(x_v, x_dst_v, x_dst, src)) begin
                    if (x_fast) loop = 1'b1; else stall = 1'b1;
                end else if (hit_src(m1_v, m1_dst_v, m1_dst, src)) begin
                    if (m1_ldlat) stall = 1'b1; else val = m1_res;
                end else if (hit_src(m2_v, m2_dst_v, m2_dst, src)) begin
                    if (m2_ldlat) stall = 1'b1; else val = m2_res;
                end else if (hit_src(w_v, w_dst_v && (w_exc == E_NONE || w_exc == E_ARITH), w_dst, src))
                    val = w_res;
                else if (hit_src(r_v, 1'b1, r_dst, src))
                    val = r_res;
            end else if (used)
                val = 64'd0;
        end
    endtask

    reg sa, sb, sc;
    always @* begin
        fwd(d_ra, dc_ua, rf_a, fwd_a, loop_a, sa);
        fwd(d_rb, dc_ub, rf_b, fwd_b, loop_b, sb);
        fwd(d_rc, dc_uc, rf_c, fwd_c, loop_c, sc);
        haz = sa || sb || sc;
    end

    // serialization
    reg  ser_pending;
    wire pipe_busy = x_v || m1_v || m2_v || w_v;
    wire ser_wait  = d_v && (ser_pending || (dc_ser && pipe_busy));
    assign stall_d = stall_x || (d_v && (haz || ser_wait));

    // ================================================================ X stage
    // multiplier
    reg         mul_go, mul_fin, mul_live;    // mul_live: the running multiply belongs to X
    wire        mul_busy, mul_done, mul_ovf;
    wire [63:0] mul_res;
    ev4_imul xmul (.clk(clk), .rst(rst), .start(mul_go), .func(x_ir[11:5]), .a(x_a), .b(x_b),
                   .busy(mul_busy), .done(mul_done), .res(mul_res), .ovf(mul_ovf), .illegal());
    wire x_mul_wait = x_v && x_cls == C_MUL && x_exc == E_NONE && !mul_fin;
    assign stall_x = stall_m1 || x_mul_wait;

    // IPR read, in D (HW_MFPR issues serialized, so the state is current)
    reg [63:0] ipr_rd;
    always @* begin
        ipr_rd = 64'd0;
        if (d_ir[7])      ipr_rd = pal_temp[d_ir[4:0]];
        else if (d_ir[6]) case (d_ir[4:0])
            5'd3:  ipr_rd = {29'd0, dtb_temp};                             // DTB_PTE_TEMP
            5'd4:  ipr_rd = {49'd0, mm_csr};
            5'd5:  ipr_rd = va_ipr;
            default: ipr_rd = 64'd0;
            endcase
        else if (d_ir[5]) case (d_ir[4:0])
            5'd2:  ipr_rd = {40'd0, iccsr_fpe, iccsr_map, iccsr_hwe, 21'd0};
            5'd3:  ipr_rd = {29'd0, itb_temp};                             // ITB_PTE_TEMP
            5'd4:  ipr_rd = exc_addr;
            5'd5:  ipr_rd = {60'd0, sl_rcv, 3'b000};                       // SL_RCV
            5'd12: ipr_rd = {51'd0, irq_h[2:0], 2'b00, irq_h[5:3], 3'b000, |irq_h, 1'b0};   // HIRR [12:10] [7:5], HWR
            5'd9:  ipr_rd = {29'd0, ps_cm[1], 32'd0, ps_cm[0], 1'b0};
            5'd11: ipr_rd = {30'd0, pal_base, 14'd0};
            default: ipr_rd = 64'd0;
            endcase
    end

    // branch resolution
    reg x_cond;
    always @* begin
        case (x_ir[28:26])
        3'd0: x_cond = !x_a[0];
        3'd1: x_cond = x_a == 64'd0;
        3'd2: x_cond = x_a[63];
        3'd3: x_cond = x_a[63] || x_a == 64'd0;
        3'd4: x_cond = x_a[0];
        3'd5: x_cond = x_a != 64'd0;
        3'd6: x_cond = !x_a[63];
        default: x_cond = !x_a[63] && x_a != 64'd0;
        endcase
    end
    wire x_fire = x_v && !stall_x && !w_redir;
    assign x_redir = x_fire && x_exc == E_NONE &&
                     (x_cls == C_BR || x_cls == C_JMP || (x_cls == C_CBR && x_cond));
    assign x_target_r = x_cls == C_JMP ? {x_b[63:2], 2'b00} : x_btarget;

    // the slow X results (into M1's second result flop)
    reg [63:0] x_slow;
    always @* begin
        case (x_cls)
        C_SHF:  x_slow = sh_res;
        C_MUL:  x_slow = mul_res;
        C_MFPR: x_slow = x_ipr;
        C_MTPR: x_slow = x_b;
        C_MISC: x_slow = x_ir[15:0] == 16'hC000 ? {cc_hi, cc} : {63'd0, intr_flag};
        default: x_slow = 64'd0;
        endcase
    end
    wire x_isf = x_cls == C_ALU || x_cls == C_LDA || x_cls == C_BR || x_cls == C_JMP;
    wire x_ovf = (x_cls == C_ALU && fa_ovf) || (x_cls == C_MUL && mul_ovf);

    // ================================================================ M1
    // D-stream translation of the registered VA
    wire        m1_hw   = m1_ir[31:26] == 6'h1B || m1_ir[31:26] == 6'h1F;
    wire        m1_phys = m1_hw && m1_ir[15];
    wire  [1:0] m1_cm   = (m1_hw && m1_ir[14]) ? alt_cm : ps_cm;
    wire        m1_quad = m1_hw ? m1_ir[12] :
                          (m1_ir[31:26] == 6'h0B || m1_ir[31:26] == 6'h0F || m1_ir[31:26] == 6'h29 ||
                           m1_ir[31:26] == 6'h2B || m1_ir[31:26] == 6'h2D || m1_ir[31:26] == 6'h2F);
    wire        m1_sp2  = spe2 && m1_cm == 2'd0 && m1_va[42:41] == 2'b10;
    wire        m1_sp1  = spe1 && m1_cm == 2'd0 && m1_va[42:30] == 13'h1FFE;
    // the DTB (all entries compared at once; at most one matches)
    reg  [31:0] dtb_m;
    reg  [33:13] dtb_spfn;
    reg   [1:0] dtb_sgh;
    reg   [9:0] dtb_spr;
    integer di;
    always @* begin
        dtb_spfn = 21'd0; dtb_sgh = 2'd0; dtb_spr = 10'd0;
        for (di = 0; di < 32; di = di + 1) begin
            dtb_m[di] = dtb_hit_i(dtb_v[di], dtb_tag[di], dtb_gh[di], m1_va[42:13]);
            if (dtb_m[di]) begin dtb_spfn = dtb_spfn | dtb_pfn[di]; dtb_sgh = dtb_sgh | dtb_gh[di]; dtb_spr = dtb_spr | dtb_pr[di]; end
        end
    end
    wire        m1_dtbhit = dtb_m != 32'd0;
    wire        m1_xok  = m1_phys || m1_sp2 || m1_sp1 || m1_dtbhit;
    wire [33:0] m1_dpa  = {dtb_spfn[33:22],
                           dtb_sgh == 2'd3 ? m1_va[21:19] : dtb_spfn[21:19],
                           dtb_sgh[1]      ? m1_va[18:16] : dtb_spfn[18:16],
                           dtb_sgh != 2'd0 ? m1_va[15:13] : dtb_spfn[15:13], m1_va[12:0]};
    wire [33:0] m1_pa   = (m1_phys || m1_sp2) ? m1_va[33:0] : m1_sp1 ? {4'd0, m1_va[29:0]} : m1_dpa;
    // protection (DTB hits only; superpages are kernel-only by construction)
    wire        m1_wr   = m1_cls == C_ST;
    wire        m1_acv  = !m1_phys && !m1_sp2 && !m1_sp1 && m1_dtbhit &&
                          (m1_wr ? !dtb_spr[4 + m1_cm] : !dtb_spr[m1_cm]);
    wire        m1_for  = !m1_phys && !m1_sp2 && !m1_sp1 && m1_dtbhit && !m1_wr && dtb_spr[8];
    wire        m1_fow  = !m1_phys && !m1_sp2 && !m1_sp1 && m1_dtbhit &&  m1_wr && dtb_spr[9];
    wire        m1_unal = !m1_hw && (m1_quad ? m1_va[2:0] != 3'd0 : m1_va[1:0] != 2'd0);
    wire        m1_mem  = m1_cls == C_LD || m1_cls == C_ST;

    // D-cache: 1024 x 64 data (byte enables), 256 x {valid, tag} tags; a
    // flush is a 256-cycle sweep (dsweep: reset, D-cache enable changes),
    // during which the D-cache neither hits nor fills
    wire [63:0] dc_q;
    wire [21:0] dct_qv;
    wire [20:0] dct_q = dct_qv[20:0];
    wire        dcv_q = dct_qv[21];
    reg         dsweep; reg [7:0] dsw_idx;
    reg         dc_we;  reg [9:0] dc_wa; reg [63:0] dc_wd; reg [7:0] dc_wbe;
    reg         dct_we; reg [7:0] dct_wa; reg [20:0] dct_wd; reg dct_v;
    wire [12:3] dc_ra = stall_m1 ? m1_va[12:3] : agen[12:3];
    ev4_ram #(.AW(10), .DW(64), .BE(8)) dcache_d (.clk(clk), .raddr(dc_ra), .rdata(dc_q),
        .we(dc_we), .waddr(dc_wa), .wdata(dc_wd), .wbe(dc_wbe));
    ev4_ram #(.AW(8), .DW(22), .BE(1)) dcache_t (.clk(clk), .raddr(dc_ra[12:5]), .rdata(dct_qv),
        .we(dct_we), .waddr(dct_wa), .wdata({dct_v, dct_wd}), .wbe(1'b1));

    reg  [63:0] m2_dq; reg [20:0] m2_dt; reg m2_dv;     // registered D-cache outputs
    reg         m2_hitq;                                 // the hit, compared in M1 (timing)
    // M1 compares the tag it just read (M1 re-reads while stalled, so this
    // stays current through fills)
    wire        m1_hit = m1_pa[33:32] == 2'd0 && dc_ena && !dsweep && dcv_q && dct_q == m1_pa[33:13];

    // ================================================================ M2
    wire        m2_hw    = m2_ir[31:26] == 6'h1B || m2_ir[31:26] == 6'h1F;
    wire        m2_quad  = m2_hw ? m2_ir[12] :
                           (m2_ir[31:26] == 6'h0B || m2_ir[31:26] == 6'h0F || m2_ir[31:26] == 6'h29 ||
                            m2_ir[31:26] == 6'h2B || m2_ir[31:26] == 6'h2D || m2_ir[31:26] == 6'h2F);
    wire        m2_load  = m2_cls == C_LD;
    wire        m2_store = m2_cls == C_ST;
    wire        m2_stc   = m2_ir[31:26] == 6'h2E || m2_ir[31:26] == 6'h2F;
    wire        m2_lock  = m2_ir[31:26] == 6'h2A || m2_ir[31:26] == 6'h2B;
    wire        m2_cachable = m2_pa[33:32] == 2'd0 && dc_ena && !dsweep;   // the AS200's memory is all below 4 GB; above is I/O
    wire        m2_hit   = m2_hitq && !dsweep;
    wire  [7:0] m2_be    = m2_quad ? 8'hFF : (m2_pa[2] ? 8'hF0 : 8'h0F);
    wire [63:0] m2_wq    = m2_quad ? m2_sd : {m2_sd[31:0], m2_sd[31:0]};
    wire        m2_stc_ok = lock_flag && lock_addr == m2_pa[33:4];

    // stores that hit the D-cache in the last three cycles: their RAM write
    // lands one cycle after the commit (registered write port), so a load up
    // to three instructions younger read the line before it: merge them in,
    // oldest first
    reg         sh0_v, sh1_v, sh2_v; reg [33:3] sh0_a, sh1_a, sh2_a; reg [63:0] sh0_d, sh1_d, sh2_d; reg [7:0] sh0_b, sh1_b, sh2_b;
    function [63:0] merge;
        input [63:0] q; input v; input [33:3] a; input [33:3] la; input [63:0] d; input [7:0] be;
        integer k;
        begin
            merge = q;
            if (v && a == la)
                for (k = 0; k < 8; k = k + 1) if (be[k]) merge[8*k +: 8] = d[8*k +: 8];
        end
    endfunction
    wire [63:0] m2_dqm = merge(merge(merge(m2_dq, sh2_v, sh2_a, m2_pa[33:3], sh2_d, sh2_b),
                                     sh1_v, sh1_a, m2_pa[33:3], sh1_d, sh1_b),
                               sh0_v, sh0_a, m2_pa[33:3], sh0_d, sh0_b);

    // the bus side of M2: misses and uncached loads
    localparam MS_IDLE = 2'd0, MS_WAIT = 2'd1, MS_DONE = 2'd2;
    reg   [1:0] mstate;
    reg  [63:0] m2_ldata;               // data from the bus for this load
    reg         wb_v; reg [33:3] wb_a; reg [7:0] wb_be; reg [63:0] wb_d;

    wire m2_live    = m2_v && m2_exc == E_NONE && !w_redir;
    wire m2_need_bus = m2_live && m2_load && !m2_hit && mstate != MS_DONE;
    wire m2_need_wb  = m2_live && m2_store && wb_v;     // buffer full (a failing STx_C waits too: timing)
    assign stall_m2 = m2_need_bus || m2_need_wb;
    assign stall_m1 = stall_m2;

    reg [63:0] m2_lq;
    always @* m2_lq = m2_hit ? m2_dqm : m2_ldata;
    reg [63:0] m2_lres;
    always @* begin
        if (!m2_quad) m2_lres = m2_pa[2] ? {{32{m2_lq[63]}}, m2_lq[63:32]} : {{32{m2_lq[31]}}, m2_lq[31:0]};
        else          m2_lres = m2_lq;
    end

    // ================================================================ bus (one transaction at a time)
    localparam B_NONE = 2'd0, B_DFILL = 2'd1, B_IFILL = 2'd2, B_WB = 2'd3;
    reg   [1:0] bown;
    reg   [1:0] bbeat;
    reg         bunc;                   // D access is a single uncached quadword
    reg         m2_go;                  // M2's bus need was taken this cycle

    // ================================================================ W stage: redirects
    reg [13:0] w_off;
    reg        w_ent;                   // take a PAL entry
    always @* begin
        w_ent = 1'b0; w_off = 14'd0; w_target = 64'd0;
        case (w_exc)
        E_OPCDEC: begin w_ent = 1'b1; w_off = 14'h13E0; end
        E_FEN:    begin w_ent = 1'b1; w_off = 14'h17E0; end
        E_ITBM:   begin w_ent = 1'b1; w_off = 14'h03E0; end
        E_ITBACV: begin w_ent = 1'b1; w_off = 14'h07E0; end
        E_DFAULT: begin w_ent = 1'b1; w_off = 14'h01E0; end
        E_UNAL:   begin w_ent = 1'b1; w_off = 14'h11E0; end
        E_DTBM:   begin w_ent = 1'b1; w_off = pal ? 14'h09E0 : 14'h08E0; end
        E_ARITH:  begin w_ent = 1'b1; w_off = 14'h0060; end
        default: if (w_cls == C_CPAL) begin
            w_ent = 1'b1;
            if (w_ir[25:8] != 18'd0 || w_ir[6] || (!w_ir[7] && !kern && !pal)) w_off = 14'h13E0;
            else w_off = {1'b1, w_ir[7], w_ir[5:0], 6'd0};
        end
        endcase
        if (w_ent) w_target = {30'd0, pal_base, w_off};
        else if (w_cls == C_REI) w_target = {exc_addr[63:2], 2'b00};
        else w_target = w_pc + 64'd4;                 // serialized: refetch after it
    end
    reg w_ser;
    assign w_redir = w_v && (w_ent || w_ser);

    // ================================================================ sequential logic
    integer i;
    always @(posedge clk) begin
        dbg_retire <= 1'b0;
        ic_we <= 1'b0; ict_we <= 1'b0; dc_we <= 1'b0; dct_we <= 1'b0;
        // a fill's tag write lands one cycle after its last beat (registered
        // write port): the line becomes valid with it, and the fetch restarts
        // the cycle after, so its read sees the new tag
        ifill_done <= ict_we && ict_v && !rst && !ld_active && !isweep;
        mul_go <= 1'b0;
        if (cc_en) cc <= cc + 32'd1;
        if (rst) begin
            pal <= 1'b1; iccsr_fpe <= 1'b0; iccsr_map <= 1'b0; iccsr_hwe <= 1'b0;
            pal_base <= 20'd0; abox_ctl <= 16'd0; ps_cm <= 2'd0; alt_cm <= 2'd0;
            itb_v <= 12'd0; dtb_v <= 32'd0; itb_sp <= 3'd0; itb_lp <= 2'd0; dtb_p <= 5'd0;
            mm_lock <= 1'b0; lock_flag <= 1'b0; intr_flag <= 1'b0; cc <= 32'd0; cc_hi <= 32'd0; cc_en <= 1'b0;
            fstate <= FS_FETCH; ifill_issued <= 1'b0; pc_f1 <= 64'd0; v_f1 <= 1'b0; v_f2 <= 1'b0;   // fetch starts after the sweep or the SROM load
            ld_active <= !icmode; ld_start <= 1'b0; ld_fin <= 1'b0; ld_bcnt <= 9'd0; ld_blk <= 9'd0;
            ld_byte_ok <= 1'b0; ld_fetch <= 2'd0; ld_baddr <= 14'd0; ld_wph <= 3'd0;
            isweep <= icmode; isw_idx <= 8'd0; dsweep <= 1'b1; dsw_idx <= 8'd0; restart_after <= 64'd0;
            sl_xmit <= 1'b1;
            d_v <= 1'b0; x_v <= 1'b0; m1_v <= 1'b0; m2_v <= 1'b0; w_v <= 1'b0; r_v <= 1'b0;
            ser_pending <= 1'b0; mul_fin <= 1'b0; mul_live <= 1'b0; mstate <= MS_IDLE;
            wb_v <= 1'b0; bown <= B_NONE; mem_req <= 1'b0;
            sh0_v <= 1'b0; sh1_v <= 1'b0; sh2_v <= 1'b0;
        end else begin
            // ------------------------------------------------ cache sweeps
            if (isweep) begin
                ict_we <= 1'b1; ict_wa <= isw_idx; ict_v <= 1'b0; ict_wd <= 21'd0;
                isw_idx <= isw_idx + 8'd1;
                if (isw_idx == 8'd255) begin isweep <= 1'b0; ld_start <= 1'b1; end
            end
            if (dsweep) begin
                dct_we <= 1'b1; dct_wa <= dsw_idx; dct_v <= 1'b0; dct_wd <= 21'd0;
                dsw_idx <= dsw_idx + 8'd1;
                if (dsw_idx == 8'd255) dsweep <= 1'b0;
            end

            // ------------------------------------------------ SROM load
            if (!(isweep && isw_idx == 8'd255)) ld_start <= 1'b0;
            if (ld_fin) begin ld_fin <= 1'b0; ld_start <= 1'b1; end
            if (ld_active) begin
                if (ld_wph != 3'd0) begin
                    // write the assembled block: quadwords {LW1,LW0} .. {LW7,LW6}, then the tag
                    ld_wph <= ld_wph == 3'd5 ? 3'd0 : ld_wph + 3'd1;
                    if (ld_wph != 3'd5) begin
                        ic_we <= 1'b1; ic_wa <= {ld_blk[7:0], ld_wph[1:0] - 2'd1};
                        case (ld_wph)
                        3'd1: ic_wd <= {ld_sr[188:157], ld_sr[31:0]};
                        3'd2: ic_wd <= {ld_sr[220:189], ld_sr[63:32]};
                        3'd3: ic_wd <= {ld_sr[252:221], ld_sr[95:64]};
                        default: ic_wd <= {ld_sr[284:253], ld_sr[127:96]};
                        endcase
                    end else begin
                        ict_we <= 1'b1; ict_wa <= ld_blk[7:0]; ict_wd <= ld_sr[148:128]; ict_v <= ld_sr[156];
                        ld_blk <= ld_blk + 9'd1;
                        if (ld_blk == 9'd255) begin ld_active <= 1'b0; ld_fin <= 1'b1; end
                    end
                end else if (!ld_byte_ok) begin
                    // fetch the next byte: address out, the ROM registers it, data
                    if (ld_fetch == 2'd0) begin srom_addr <= ld_baddr[12:0]; ld_fetch <= 2'd1; end
                    else if (ld_fetch == 2'd1) ld_fetch <= 2'd2;
                    else begin
                        ld_byte <= ld_baddr[13] ? 8'd0 : srom_data;
                        ld_byte_ok <= 1'b1; ld_bitpos <= 3'd0; ld_fetch <= 2'd0;
                        if (!ld_baddr[13]) ld_baddr <= ld_baddr + 14'd1;
                    end
                end else begin
                    ld_sr <= {ld_byte[ld_bitpos], ld_sr[292:1]};
                    ld_bitpos <= ld_bitpos + 3'd1;
                    if (ld_bitpos == 3'd7) ld_byte_ok <= 1'b0;
                    if (ld_bcnt == 9'd292) begin ld_bcnt <= 9'd0; ld_wph <= 3'd1; end
                    else ld_bcnt <= ld_bcnt + 9'd1;
                end
            end

            // ------------------------------------------------ fetch
            pc_f1 <= npc; v_f1 <= nv;
            if (fstate == FS_FETCH && !(w_redir || x_redir) && f2_miss) begin
                fstate <= FS_FILL; restart_pc <= pc_f2; ifill_line <= f2_pa[33:5];
            end
            if (fstate == FS_FILL && (w_redir || x_redir)) restart_pc <= w_redir ? w_target : x_target_r;
            if (fstate == FS_FILL && ifill_done) begin fstate <= FS_FETCH; ifill_issued <= 1'b0; end
            if (kill_f2) v_f2 <= 1'b0;
            else if (!f_hold) begin
                pc_f2 <= pc_f1; v_f2 <= v_f1; q2 <= ic_q; t2 <= ict_q; v2 <= icv_q;
            end

            // ------------------------------------------------ D
            if (w_redir || x_redir) d_v <= 1'b0;
            else if (!f_hold) begin
                d_v   <= v_f2 && (fstate == FS_FETCH) && (!f2_tr_ok || f2_hit);
                d_pc  <= pc_f2;
                d_ir  <= f2_tr_ok ? f2_insn : 32'd0;
                d_exc <= f2_tr_ok ? E_NONE : f2_itbm ? E_ITBM : E_ITBACV;
            end

            // ------------------------------------------------ D -> X
            if (w_redir) x_v <= 1'b0;
            else if (!stall_x) begin
                x_v <= d_v && !stall_d && !x_redir;
                if (d_v && !stall_d && !x_redir) begin
                    x_pc <= d_pc; x_ir <= d_ir; x_cls <= dc_cls; x_exc <= dc_exc;
                    x_dst <= dc_dst; x_dst_v <= dc_dst_v; x_fast <= dc_fast; x_ldlat <= dc_ldlat;
                    x_ser <= dc_ser;
                    x_a <= loop_a ? fast_res : fwd_a;
                    x_b <= d_lit && (dc_cls == C_ALU || dc_cls == C_SHF || dc_cls == C_MUL)
                           ? {56'd0, d_ir[20:13]} : (loop_b ? fast_res : fwd_b);
                    x_c <= loop_c ? fast_res : fwd_c;
                    x_btarget <= d_pc + 64'd4 + {{41{d_ir[20]}}, d_ir[20:0], 2'b00};
                    x_link <= d_pc + 64'd4;
                    x_ipr <= ipr_rd;
                    x_sel_lda <= dc_cls == C_LDA;
                    x_sel_link <= dc_cls == C_BR || dc_cls == C_JMP;
                    if (dc_ser) ser_pending <= 1'b1;
                end
            end

            // ------------------------------------------------ multiplier
            if (x_v && x_cls == C_MUL && x_exc == E_NONE && !mul_fin && !mul_busy && !mul_go && !mul_live && !w_redir) begin
                mul_go <= 1'b1; mul_live <= 1'b1;
            end
            if (mul_done && mul_live) begin mul_fin <= 1'b1; mul_live <= 1'b0; end
            if (x_fire) mul_fin <= 1'b0;
            if (w_redir) begin mul_fin <= 1'b0; mul_live <= 1'b0; end

            // ------------------------------------------------ X -> M1
            if (w_redir) m1_v <= 1'b0;
            else if (!stall_m1) begin
                m1_v <= x_v && !x_mul_wait;
                m1_pc <= x_pc; m1_ir <= x_ir; m1_cls <= x_cls;
                m1_exc <= (x_exc == E_NONE && x_ovf) ? E_ARITH : x_exc;
                m1_rf <= fast_res; m1_rs <= x_slow; m1_isf <= x_isf; m1_va <= x_va; m1_sd <= x_a; m1_cmf <= x_cls == C_ALU && !fa_wr;
                m1_dst <= x_dst; m1_dst_v <= x_dst_v; m1_ldlat <= x_ldlat;
            end

            // ------------------------------------------------ M1 -> M2
            if (w_redir) m2_v <= 1'b0;
            else if (!stall_m2) begin
                m2_v <= m1_v;
                m2_pc <= m1_pc; m2_ir <= m1_ir; m2_cls <= m1_cls; m2_res <= m1_res;
                m2_va <= m1_va; m2_sd <= m1_sd; m2_pa <= m1_pa; m2_cmf <= m1_cmf;
                m2_dst <= m1_dst; m2_dst_v <= m1_dst_v; m2_ldlat <= m1_ldlat;
                m2_exc <= (m1_exc != E_NONE || !m1_mem) ? m1_exc :
                          m1_unal ? E_UNAL : !m1_xok ? E_DTBM :
                          (m1_acv || m1_for || m1_fow) ? E_DFAULT : E_NONE;
                m2_fb <= {m1_fow && !m1_acv, m1_for && !m1_acv, m1_acv};
                m2_dq <= dc_q; m2_dt <= dct_q; m2_dv <= dcv_q; m2_hitq <= m1_hit;
                mstate <= MS_IDLE;
            end

            // store history ages every cycle
            sh2_v <= sh1_v; sh2_a <= sh1_a; sh2_d <= sh1_d; sh2_b <= sh1_b;
            sh1_v <= sh0_v; sh1_a <= sh0_a; sh1_d <= sh0_d; sh1_b <= sh0_b;
            sh0_v <= 1'b0;

            // ------------------------------------------------ M2 actions (commit when it advances)
            if (m2_live && !stall_m2) begin
                if (m2_store && !(m2_stc && !m2_stc_ok)) begin
                    wb_v <= 1'b1; wb_a <= m2_pa[33:3]; wb_be <= m2_be; wb_d <= m2_wq;
                    if (m2_hit) begin
                        dc_we <= 1'b1; dc_wa <= m2_pa[12:3]; dc_wd <= m2_wq; dc_wbe <= m2_be;
                        sh0_v <= 1'b1; sh0_a <= m2_pa[33:3]; sh0_d <= m2_wq; sh0_b <= m2_be;
                    end
                end
                if (m2_lock) begin lock_flag <= 1'b1; lock_addr <= m2_pa[33:4]; end
                if (m2_stc) lock_flag <= 1'b0;
            end

            // ------------------------------------------------ M2 -> W
            if (w_redir) w_v <= 1'b0;
            else begin
                w_v <= m2_v && !stall_m2;
                w_pc <= m2_pc; w_ir <= m2_ir; w_cls <= m2_cls; w_exc <= m2_exc;
                w_dst <= m2_dst; w_dst_v <= m2_dst_v; w_va <= m2_va; w_cmf <= m2_cmf; w_fb <= m2_fb;
                w_res <= m2_load ? m2_lres : (m2_store && m2_stc) ? {63'd0, m2_stc_ok} : m2_res;
                w_st <= m2_store && m2_exc == E_NONE && !(m2_stc && !m2_stc_ok);
                w_sdata <= m2_quad ? m2_sd : {32'd0, m2_sd[31:0]};
                w_ssize <= m2_quad ? 4'd8 : 4'd4;
                w_ser <= m2_cls == C_CPAL || m2_cls == C_MFPR || m2_cls == C_MTPR || m2_cls == C_REI ||
                         m2_hw || (m2_cls == C_MISC && (m2_ir[15:0] == 16'hE000 || m2_ir[15:0] == 16'hF000));
            end

            // ------------------------------------------------ W: retire
            r_v <= rf_we; r_dst <= w_dst; r_res <= w_res;
            if (w_v) begin
                if (w_exc == E_NONE || w_exc == E_ARITH) begin
                    dbg_retire <= w_cls != C_CPAL;      // CALL_PAL enters PALcode, it does not retire
                    dbg_pc <= w_pc; dbg_insn <= w_ir;
                    dbg_rwr <= rf_we && !w_cmf; dbg_rnum <= w_dst; dbg_rval <= w_res;
                    dbg_mwr <= w_st; dbg_maddr <= w_va; dbg_mval <= w_sdata; dbg_msize <= w_ssize;
                    // IPR writes
                    if (w_cls == C_MTPR) begin
                        if (w_ir[7]) pal_temp[w_ir[4:0]] <= w_res;
                        if (w_ir[6]) case (w_ir[4:0])
                            5'd14: begin
                                abox_ctl <= w_res[15:0];
                                if (w_res[10] != abox_ctl[10]) begin dsweep <= 1'b1; dsw_idx <= 8'd0; end   // D-cache on/off: start clean
                            end
                            5'd15: alt_cm <= w_res[4:3];
                            5'd0:  tb_gh <= w_res[6:5];                                // TB_CTL
                            5'd2: begin                                                 // DTB_PTE
                                dtb_v[dtb_p] <= 1'b1; dtb_tag[dtb_p] <= tb_tag; dtb_gh[dtb_p] <= tb_gh;
                                dtb_pfn[dtb_p] <= w_res[52:32]; dtb_asm[dtb_p] <= w_res[4];
                                dtb_pr[dtb_p] <= {w_res[2], w_res[1], w_res[15:12], w_res[11:8]};
                                dtb_p <= dtb_p + 5'd1;
                            end
                            5'd6: dtb_v <= 32'd0;                                       // DTBZAP
                            5'd7: dtb_v <= dtb_v & dtb_asm;                             // DTBASM
                            5'd8: begin : dtbis                                         // DTBIS
                                integer q;
                                for (q = 0; q < 32; q = q + 1)
                                    if (dtb_hit_i(dtb_v[q], dtb_tag[q], dtb_gh[q], w_res[42:13])) dtb_v[q] <= 1'b0;
                            end
                            5'd16: cc_hi <= w_res[63:32];             // CC
                            5'd17: begin cc <= w_res[31:0]; cc_en <= w_res[32]; end   // CC_CTL
                            5'd21, 5'd23: begin                       // FLUSH_IC, FLUSH_IC_ASM: sweep, then resume after this
                                isweep <= 1'b1; isw_idx <= 8'd0; restart_after <= w_pc + 64'd4;
                            end
                            default: ;
                            endcase
                        if (w_ir[5]) case (w_ir[4:0])
                            5'd2: begin iccsr_fpe <= w_res[42]; iccsr_map <= w_res[41]; iccsr_hwe <= w_res[40]; end
                            5'd4: exc_addr <= w_res;
                            5'd9: ps_cm <= w_res[4:3];
                            5'd11: pal_base <= w_res[33:14];
                            5'd22: sl_xmit <= w_res[4];               // SL_XMIT
                            5'd0: tb_tag <= w_res[42:13];                              // TB_TAG
                            5'd1: begin                                                 // ITB_PTE
                                if (tb_gh == 2'd3) begin
                                    itb_v[8 + itb_lp] <= 1'b1; itb_tag[8 + itb_lp] <= tb_tag;
                                    itb_pfn[8 + itb_lp] <= w_res[52:32]; itb_re[8 + itb_lp] <= w_res[11:8];
                                    itb_asm[8 + itb_lp] <= w_res[4]; itb_lp <= itb_lp + 2'd1;
                                end else begin
                                    itb_v[itb_sp] <= 1'b1; itb_tag[itb_sp] <= tb_tag;
                                    itb_pfn[itb_sp] <= w_res[52:32]; itb_re[itb_sp] <= w_res[11:8];
                                    itb_asm[itb_sp] <= w_res[4]; itb_sp <= itb_sp + 3'd1;
                                end
                            end
                            5'd6: begin itb_v <= 12'd0; itb_sp <= 3'd0; itb_lp <= 2'd0; end   // ITBZAP
                            5'd7: itb_v <= itb_v & itb_asm;                             // ITBASM
                            5'd8: begin : itbis                                         // ITBIS
                                integer q;
                                for (q = 0; q < 12; q = q + 1)
                                    if (itb_v[q] && w_res[42:22] == itb_tag[q][42:22] &&
                                        (q >= 8 || w_res[21:13] == itb_tag[q][21:13])) itb_v[q] <= 1'b0;
                            end
                            default: ;
                            endcase
                    end
                    if (w_cls == C_MFPR && !w_ir[7] && w_ir[6] && w_ir[4:0] == 5'd5) mm_lock <= 1'b0;
                    if (w_cls == C_MFPR && !w_ir[7] && w_ir[6] && w_ir[4:0] == 5'd2) begin   // DTB_PTE read
                        dtb_temp <= {dtb_asm[dtb_p], dtb_pfn[dtb_p], dtb_pr[dtb_p][3:0], dtb_pr[dtb_p][7:4], dtb_pr[dtb_p][9:8], 3'b000};
                        dtb_p <= dtb_p + 5'd1;
                    end
                    if (w_cls == C_MFPR && !w_ir[7] && !w_ir[6] && w_ir[5] && w_ir[4:0] == 5'd1) begin   // ITB_PTE read
                        if (tb_gh == 2'd3) begin
                            itb_temp <= {itb_asm[8 + itb_lp], itb_pfn[8 + itb_lp], itb_re[8 + itb_lp][3:0], 9'd0};
                            itb_lp <= itb_lp + 2'd1;
                        end else begin
                            itb_temp <= {itb_asm[itb_sp], itb_pfn[itb_sp], itb_re[itb_sp][3:0], 9'd0};
                            itb_sp <= itb_sp + 3'd1;
                        end
                    end
                    if (w_cls == C_MISC && w_ir[15:0] == 16'hE000) intr_flag <= 1'b0;
                    if (w_cls == C_MISC && w_ir[15:0] == 16'hF000) intr_flag <= 1'b1;
                    if (w_cls == C_REI) pal <= exc_addr[0];
                end
                if (w_exc == E_UNAL || w_exc == E_DTBM || w_exc == E_DFAULT) begin
                    if (!mm_lock) begin
                        va_ipr <= w_va;
                        mm_csr <= {w_ir[31:26], w_ir[25:21], w_exc == E_DFAULT ? w_fb : 3'b000, w_cls == C_ST};   // opcode, Ra, FOW FOR ACV, WR
                        mm_lock <= 1'b1;
                    end
                end
                if (w_ent) begin
                    exc_addr <= w_exc == E_ARITH ? ((w_pc + 64'd4) | 64'd2 | {63'd0, pal}) :
                                (w_cls == C_CPAL && w_exc == E_NONE) ? ((w_pc + 64'd4) | {63'd0, pal}) :
                                (w_pc | {63'd0, pal});
                    pal <= 1'b1;
                end
                if (w_ser || w_ent) ser_pending <= 1'b0;
            end
            if (w_redir) ser_pending <= 1'b0;

            // ------------------------------------------------ bus
            if (bown == B_NONE) begin
                // D-side (M2) first, after the write buffer; then I-fill; then the buffer
                if (m2_need_bus && mstate == MS_IDLE && !wb_v) begin
                    bown <= B_DFILL; bbeat <= 2'd0; bunc <= !m2_cachable;
                    mem_req <= 1'b1; mem_we <= 1'b0; mem_istream <= 1'b0; mem_be <= 8'hFF;
                    mem_addr <= m2_cachable ? {m2_pa[33:5], 2'd0} : m2_pa[33:3];
                    mstate <= MS_WAIT;
                    if (m2_cachable) begin dct_we <= 1'b1; dct_wa <= m2_pa[12:5]; dct_v <= 1'b0; dct_wd <= 21'd0; end
                end else if (wb_v && (m2_need_bus || m2_need_wb || fstate != FS_FILL)) begin
                    bown <= B_WB;
                    mem_req <= 1'b1; mem_we <= 1'b1; mem_istream <= 1'b0;
                    mem_addr <= wb_a; mem_be <= wb_be; mem_wdata <= wb_d;
                end else if (fstate == FS_FILL && !ifill_issued) begin
                    bown <= B_IFILL; bbeat <= 2'd0; ifill_issued <= 1'b1;
                    ict_we <= 1'b1; ict_wa <= ifill_line[12:5]; ict_v <= 1'b0; ict_wd <= 21'd0;
                    mem_req <= 1'b1; mem_we <= 1'b0; mem_istream <= 1'b1; mem_be <= 8'hFF;
                    mem_addr <= {ifill_line, 2'd0};
                end
            end else if (mem_ack) begin
                case (bown)
                B_WB: begin mem_req <= 1'b0; bown <= B_NONE; wb_v <= 1'b0; end
                B_IFILL: begin
                    ic_we <= 1'b1; ic_wa <= {ifill_line[12:5], bbeat}; ic_wd <= mem_rdata;
                    if (bbeat == 2'd3) begin
                        mem_req <= 1'b0; bown <= B_NONE;
                        ict_we <= 1'b1; ict_wa <= ifill_line[12:5]; ict_wd <= ifill_line[33:13]; ict_v <= 1'b1;
                    end else begin
                        bbeat <= bbeat + 2'd1; mem_addr <= {ifill_line, bbeat + 2'd1};
                    end
                end
                default: begin   // B_DFILL
                    if (bunc || bbeat == m2_pa[4:3]) m2_ldata <= mem_rdata;
                    if (!bunc) begin dc_we <= 1'b1; dc_wa <= {m2_pa[12:5], bbeat}; dc_wd <= mem_rdata; dc_wbe <= 8'hFF; end
                    if (bunc || bbeat == 2'd3) begin
                        mem_req <= 1'b0; bown <= B_NONE; mstate <= MS_DONE;
                        if (!bunc) begin dct_we <= 1'b1; dct_wa <= m2_pa[12:5]; dct_wd <= m2_pa[33:13]; dct_v <= 1'b1; end
                    end else begin
                        bbeat <= bbeat + 2'd1; mem_addr <= {m2_pa[33:5], bbeat + 2'd1};
                    end
                end
                endcase
            end
            // a filled load completes from m2_ldata (mstate MS_DONE) even if the
            // RAM outputs it holds are stale: force the miss path's data
            if (mstate == MS_DONE && !stall_m2) mstate <= MS_IDLE;
        end
    end
endmodule
