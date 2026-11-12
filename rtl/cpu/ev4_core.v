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

    // DMA writes: invalidate the D-cache line at this index (the 21064's
    // dInvReq, by index only: 8 KB of 32-byte lines, PA[12:5])
    input  wire        dinv,
    input  wire  [7:0] dinv_idx,

    // the six interrupt pins, irq_h[5:0] (level; AS200 wiring HARDWARE.md 3).
    // Read through HIRR; interrupt delivery is a STUB (to come with HIER)
    input  wire  [5:0] irq_h,

    output reg         mem_req,
    output reg         mem_we,
    output reg         mem_istream,
    output reg         mem_line,        // a 32-byte line fill: 4 quadwords from the line base, one mem_ack each
    output reg  [33:3] mem_addr,
    output reg   [7:0] mem_be,
    output reg  [63:0] mem_wdata,
    output wire [31:0] mem_wmask,       // a write with mem_line: the line at mem_addr[33:5], 32 byte enables
    output wire [255:0] mem_wline,      // (memory writes always go out this way; I/O writes as quadwords)
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
    output reg   [3:0] dbg_msize,
    output wire        dbg_pal,         // PAL mode (the board's CPU state line)
    // each PAL entry (exception, interrupt, CALL_PAL), a cycle after it is taken: the entry's
    // offset, EXC_ADDR and VA as they are then (the board's CPU trace, rtl/mister/dbg_trace.v)
    output reg         dbg_ent,
    output reg  [13:0] dbg_ent_off,
    output reg  [31:0] dbg_ent_ir,     // the instruction in W at the entry (an arithmetic trap's trapping instruction)
    output wire [63:0] dbg_exc_addr,
    output wire [63:0] dbg_va,
    output wire [14:0] dbg_mm_csr,    // MM_CSR as the last D-stream fault left it (the board's E01E0 line)
    output reg  [10:0] dbg_dtb_pr,    // at that fault: {more than one DTB entry matched, the OR of the matching entries' {FOW, FOR, UWE..KWE, URE..KRE}}
    output reg         dbg_psw,       // a PAL write of PS (hw_mtpr PS): dbg_psv = the value's low byte, dbg_pc its PC
    output reg   [7:0] dbg_psv
);
    // ================================================================ classes
    localparam C_NOP = 4'd0, C_ALU = 4'd1, C_SHF = 4'd2, C_MUL = 4'd3, C_LDA = 4'd4,
               C_LD  = 4'd5, C_ST  = 4'd6, C_BR  = 4'd7, C_CBR = 4'd8, C_JMP = 4'd9,
               C_MISC = 4'd10, C_MFPR = 4'd11, C_MTPR = 4'd12, C_REI = 4'd13, C_CPAL = 4'd14,
               C_CMOVX = 4'd15;                 // only as an x_slow selector
    // exception codes carried down the pipe
    localparam E_NONE = 4'd0, E_OPCDEC = 4'd1, E_FEN = 4'd2, E_ITBM = 4'd3,
               E_UNAL = 4'd4, E_DTBM = 4'd5, E_ARITH = 4'd6, E_DFAULT = 4'd7, E_ITBACV = 4'd8,
               E_INTR = 4'd9;                    // an interrupt, taken on this instruction

    // ================================================================ architectural state (W)
    reg         pal;
    assign dbg_pal = pal;
    assign dbg_exc_addr = exc_addr;
    assign dbg_va = va_ipr;
    assign dbg_mm_csr = mm_csr;
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
`ifdef SIM_PCILOG
    // the system simulation's +ccstep=N: CC advances N a cycle, so RPCC delay loops run N times
    // shorter (firmware takes the CPU speed from the console's table, not from CC)
    reg  [31:0] cc_step;
    initial if (!$value$plusargs("ccstep=%d", cc_step)) cc_step = 32'd1;
`endif
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
    reg   [5:0] fpcr_f;                 // INV DZE OVF UNF INE IOV = FPCR[57:52] (bit 0 = INV)
    reg   [1:0] fpcr_dyn;               // FPCR[59:58]
    reg   [6:0] exc_sum_r;              // EXC_SUM[8:2]: IOV INE UNF FOV DZE INV SWC
    reg  [63:0] exc_mask;               // the register write mask: bit n = Rn, 32+n = Fn

    // the interrupt pins, registered (HIRR shows "delayed copies" of the pins, cpu.md 4.2;
    // the request logic outside is long)
    reg   [5:0] irq_q;
    always @(posedge clk) irq_q <= irq_h;

    // interrupt enables and software requests (cpu.md 4.2, 7)
    reg   [5:0] hier;
    reg         hier_pc0, hier_pc1, hier_cre, hier_sle;
    reg  [15:1] sier, sirr;
    reg   [3:0] aster, astrr;               // [0] K, [1] E, [2] S, [3] U
    wire  [3:0] ast_mode_ok = {ps_cm >= 2'd3, ps_cm >= 2'd2, ps_cm >= 2'd1, 1'b1};
    wire        ast_req = sier[2] && |(astrr & aster & ast_mode_ok);
    wire        hw_req  = |(irq_q & hier);
    wire        sw_req  = |(sirr & sier);
    reg         intr_req;                    // registered: a deliverable interrupt is pending
    always @(posedge clk) intr_req <= !rst && !pal && (hw_req || sw_req || ast_req);
    // the HIRR / HIER read formats (cpu.md 4.2)
    wire [63:0] hirr_rd = {31'd0, astrr[3], astrr[2], astrr[1], astrr[0], sirr, 1'b0,
                           irq_q[2:0], 1'b0, 1'b0, irq_q[5:3], 1'b0, ast_req, sw_req, hw_req, 1'b0};
    wire [63:0] hier_rd = {31'd0, aster[3], aster[2], aster[1], aster[0], sier, hier_sle,
                           hier[2:0], hier_pc0, hier_pc1, hier[5:3], hier_cre, 4'd0};

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
    reg  [63:0] w_res; reg [5:0] w_dst; reg w_dst_v;
    reg  [63:0] w_va; reg w_cmf;   // *_cmf: a CMOV whose condition was false (rewrites Rc, not traced)
    reg         w_st;  reg [63:0] w_sdata; reg [3:0] w_ssize;
    // PAL_TEMP writes (HW_MTPR to a P register at W) outside the reset-gated
    // block: they are undefined at reset, and the reset fanned into 2048 enables
    always @(posedge clk)
        if (w_v && (w_exc == E_NONE || w_exc == E_ARITH) && w_cls == C_MTPR && w_ir[7])
            pal_temp[w_ir[4:0]] <= w_res;
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

    // I-stream translation (PALmode physical, the superpage, the ITB) is done
    // in F1 on the registered pc_f1 and registered into F2 with the RAM
    // outputs (cpu-timing.md: the ITB lookup in F2 failed by 2.4 ns); ITB
    // writes are serialized and refetched, so this is never stale
    reg  [11:0] itb_m;
    reg  [33:13] itb_spfn1;
    reg   [3:0] itb_sre1;
    reg         itb_large1;
    integer ii;
    always @* begin
        itb_spfn1 = 21'd0; itb_sre1 = 4'd0; itb_large1 = 1'b0;
        for (ii = 0; ii < 12; ii = ii + 1) begin
            itb_m[ii] = itb_v[ii] && pc_f1[42:22] == itb_tag[ii][42:22] &&
                        (ii >= 8 || pc_f1[21:13] == itb_tag[ii][21:13]);
            if (itb_m[ii]) begin itb_spfn1 = itb_spfn1 | itb_pfn[ii]; itb_sre1 = itb_sre1 | itb_re[ii]; end
            if (itb_m[ii] && ii >= 8) itb_large1 = 1'b1;
        end
    end
    wire        f1_phys  = pal || (iccsr_map && kern && pc_f1[42:41] == 2'b10);
    reg         f2_phys, itb_large, f2_itbany;
    reg  [33:13] itb_spfn;
    reg   [3:0] itb_sre;
    wire        f2_itbm  = !f2_phys && !f2_itbany;
    wire        f2_acv   = !f2_phys && !f2_itbm && !itb_sre[ps_cm];
    wire        f2_tr_ok = !f2_itbm && !f2_acv;
    wire [33:0] f2_pa    = f2_phys ? pc_f2[33:0] :
                           itb_large ? {itb_spfn[33:22], pc_f2[21:0]} : {itb_spfn, pc_f2[12:0]};
    wire        f2_hit   = v2 && t2 == f2_pa[33:13];
    wire        f2_miss  = v_f2 && f2_tr_ok && !f2_hit && fstate == FS_FETCH;
    wire [31:0] f2_insn  = pc_f2[2] ? q2[63:32] : q2[31:0];
    wire        f_hold   = stall_d;

    // Branch prediction, in F2 (docs/design/pipeline.md): BR / BSR are taken, a conditional
    // branch is predicted taken when it goes backward, RET and JSR_COROUTINE go to the top of a
    // four-entry return stack that BSR and JSR push. A predicted instruction steers the fetch in
    // the cycle it leaves F2 (p_take: one bubble, the instruction in F1) and carries d_pred /
    // x_pred; X redirects only when the prediction was wrong (to PC + 4 or to the real target),
    // so any prediction is safe. The stack is speculative: X keeps the pointer and count of the
    // instructions that really ran (cs_*), and a redirect restores them.
    wire  [5:0] f2_op    = f2_insn[31:26];
    wire        f2_isbr  = f2_op == 6'h30 || f2_op == 6'h34;
    wire        f2_iscbr = f2_op[5:3] == 3'b111 || (f2_op[5:3] == 3'b110 && f2_op[1:0] != 2'b00);
    wire        f2_isjmp = f2_op == 6'h1A;
    wire        f2_pop   = f2_isjmp && f2_insn[15];                       // RET, JSR_COROUTINE
    wire        f2_push  = f2_op == 6'h34 || (f2_isjmp && f2_insn[14]);   // BSR, JSR, JSR_COROUTINE
    reg  [40:0] rs0, rs1, rs2, rs3;     // return addresses [42:2]
    reg   [1:0] rs_sp, cs_sp;           // the top entry
    reg   [2:0] rs_n,  cs_n;            // entries that hold a return address (0-4)
    wire [40:0] rs_top = rs_sp == 2'd0 ? rs0 : rs_sp == 2'd1 ? rs1 : rs_sp == 2'd2 ? rs2 : rs3;
    wire [63:0] f2_link  = pc_f2 + 64'd4;
    wire        p_pred   = f2_isbr || (f2_iscbr && f2_insn[20]) || (f2_pop && rs_n != 3'd0);
    wire [63:0] p_target = f2_isjmp ? {{21{rs_top[40]}}, rs_top, 2'b00}
                                    : pc_f2 + 64'd4 + {{41{f2_insn[20]}}, f2_insn[20:0], 2'b00};
    // the instruction in F2 moves to D this cycle (unless a redirect kills it)
    wire        f2_go    = v_f2 && f2_tr_ok && f2_hit && fstate == FS_FETCH && !f_hold &&
                           !ld_active && !isweep && !ld_start;
    wire        p_take   = p_pred && f2_go;

    // Next PC. The X redirect (a taken branch or jump) decides last: it is
    // the late signal (operand flop -> condition), so npc_o is everything
    // else, and the X target and its I-cache valid bit are looked up in
    // parallel and picked by x_take at the very end (cpu-timing.md).
    reg  [63:0] npc_o;
    reg         nv_o;
    reg         kill_o;
    // a redirect in the cycle the I-fill ends (ifill_done) is taken at once: restart_pc
    // catches only the redirects before it, and the fill's restart would be lost (fetch
    // stopped for good: an interrupt at W as the fill of its own line finished)
    wire        x_take = x_redir && !w_redir && !ld_active && !ld_start && !isweep && (fstate == FS_FETCH || ifill_done);
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
            if (fstate == FS_FILL && !ifill_done) nv_o = 1'b0;
            else begin npc_o = w_target; nv_o = 1'b1; end
        end else if (x_redir) begin
            // only reached in FS_FILL (otherwise x_take wins): the fill finishes first
            kill_o = 1'b1; nv_o = 1'b0;
        end else if (fstate == FS_FILL) begin
            if (ifill_done) begin npc_o = restart_pc; nv_o = 1'b1; end
            else nv_o = 1'b0;
        end else if (f2_miss) begin
            nv_o = 1'b0; kill_o = 1'b1;
        end else if (p_take) begin
            npc_o = p_target; nv_o = 1'b1; kill_o = 1'b1;
        end else if (!f_hold)
            npc_o = pc_f1 + 64'd4;
    end

    ev4_ram #(.AW(10), .DW(64), .BE(1)) icache_d (.clk(clk), .raddr(npc[12:3]), .rdata(ic_q),
        .we(ic_we), .waddr(ic_wa), .wdata(ic_wd), .wbe(1'b1));
    ev4_ram #(.AW(8), .DW(22), .BE(1)) icache_t (.clk(clk), .raddr(npc[12:5]), .rdata(ict_qv),
        .we(ict_we), .waddr(ict_wa), .wdata({ict_v, ict_wd}), .wbe(1'b1));

    // ================================================================ D stage
    reg         d_v;  reg [63:0] d_pc; reg [31:0] d_ir; reg [3:0] d_exc;
    reg         d_pred;                 // the fetch followed this instruction's predicted target
    reg  [40:0] d_ptgt;                 // RET / JSR_COROUTINE: the predicted target [42:2]

    // register file: three read ports (A = Ra, B = Rb, C = Rc for CMOV)
    wire [63:0] rf_a, rf_b, rf_c;
    // one register file for both banks: R0-R31 at 0-31, F0-F31 at 32-63
    // (bit 5 = FP); which bank each field reads is predecoded from the opcode
    function fpa_op;                    // Ra is an FP register
        input [5:0] op;
        fpa_op = op == 6'h15 || op == 6'h16 || op == 6'h17 || (op >= 6'h20 && op <= 6'h27) ||
                 op == 6'h31 || op == 6'h32 || op == 6'h33 || op == 6'h35 || op == 6'h36 || op == 6'h37;
    endfunction
    function fpb_op;                    // Rb / Rc are FP registers
        input [5:0] op;
        fpb_op = op == 6'h15 || op == 6'h16 || op == 6'h17;
    endfunction
    wire [31:0] rd_ir    = f_hold ? d_ir : f2_insn;
    wire  [5:0] rfa_addr = {fpa_op(rd_ir[31:26]), rd_ir[25:21]};
    wire  [5:0] rfb_addr = {fpb_op(rd_ir[31:26]), rd_ir[20:16]};
    wire  [5:0] rfc_addr = {fpb_op(rd_ir[31:26]), rd_ir[4:0]};
    wire        rf_we = w_v && w_dst_v && (w_exc == E_NONE || w_exc == E_ARITH);
    ev4_ram #(.AW(6), .DW(64), .BE(1)) rf0 (.clk(clk), .raddr(rfa_addr), .rdata(rf_a),
        .we(rf_we), .waddr(w_dst), .wdata(w_res), .wbe(1'b1));
    ev4_ram #(.AW(6), .DW(64), .BE(1)) rf1 (.clk(clk), .raddr(rfb_addr), .rdata(rf_b),
        .we(rf_we), .waddr(w_dst), .wdata(w_res), .wbe(1'b1));
    ev4_ram #(.AW(6), .DW(64), .BE(1)) rf2 (.clk(clk), .raddr(rfc_addr), .rdata(rf_c),
        .we(rf_we), .waddr(w_dst), .wdata(w_res), .wbe(1'b1));

    // decode
    wire  [5:0] d_op   = d_ir[31:26];
    wire  [5:0] d_ra   = {fpa_op(d_ir[31:26]), d_ir[25:21]};
    wire  [5:0] d_rb   = {fpb_op(d_ir[31:26]), d_ir[20:16]};
    wire  [5:0] d_rc   = {fpb_op(d_ir[31:26]), d_ir[4:0]};
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
    reg        dc_fpu;                 // an FP arithmetic instruction (opcodes 15, 16)
    wire       fd_fen, fd_legal, fd_div, fd_rd_fa, fd_rd_fb;
    ev4_fpu_dec fdec (.ir(d_ir), .fen(fd_fen), .legal(fd_legal), .div(fd_div), .rd_fa(fd_rd_fa), .rd_fb(fd_rd_fb));
    reg  [5:0] dc_dst; reg dc_dst_v;
    reg        dc_ua, dc_ub;           // reads Ra, Rb
    reg        dc_fast, dc_ldlat;      // result forwardable from X / only from W
    reg        dc_ser;
    reg  [3:0] dc_exc;
    always @* begin
        dc_fpu = 1'b0;
        dc_cls = C_NOP; dc_dst = d_ra; dc_dst_v = 1'b0; dc_ua = 1'b0; dc_ub = 1'b0;
        dc_fast = 1'b0; dc_ldlat = 1'b0; dc_ser = 1'b0; dc_exc = E_NONE;
        case (d_op)
        6'h00: begin dc_cls = C_CPAL; dc_ser = 1'b1; end
        6'h08, 6'h09: begin dc_cls = C_LDA; dc_dst_v = 1'b1; dc_ub = 1'b1; dc_fast = 1'b1; end
        6'h0B, 6'h28, 6'h29, 6'h2A, 6'h2B: begin
            if (d_ra[4:0] == 5'd31 && d_op != 6'h2A && d_op != 6'h2B) dc_cls = C_NOP;   // load to R31: no-op
            else begin dc_cls = C_LD; dc_dst_v = 1'b1; dc_ub = 1'b1; dc_ldlat = 1'b1; end
        end
        6'h0F, 6'h2C, 6'h2D: begin dc_cls = C_ST; dc_ua = 1'b1; dc_ub = 1'b1; end
        6'h2E, 6'h2F: begin dc_cls = C_ST; dc_ua = 1'b1; dc_ub = 1'b1; dc_dst_v = 1'b1; dc_ldlat = 1'b1; end
        6'h10, 6'h11: begin
            // CMOV is not in the 1-cycle loop (its old-Rc select would lengthen it): 2 cycles
            dc_cls = C_ALU; dc_dst = d_rc; dc_dst_v = 1'b1; dc_ua = 1'b1; dc_ub = !d_lit; dc_fast = !d_cmov;
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
        // ---- floating point (cpu.md 8): FEN when ICCSR[FPE] = 0
        6'h20, 6'h21, 6'h22, 6'h23: begin                                 // LDF LDG LDS LDT
            // a load to F31 is a prefetch hint (LDS: PREFETCH_M, LDT: PREFETCH_MEN, ARM 4.11): no
            // access, no exception, not even FEN. OpenVMS 8.4's CDSA shareables prefetch 0x200
            // past an object with `lds $f31,512(a0)`, often into an unmapped page
            if (d_ra[4:0] == 5'd31) dc_cls = C_NOP;
            else begin
                dc_cls = C_LD; dc_dst_v = 1'b1; dc_ub = 1'b1; dc_ldlat = 1'b1;
                if (!iccsr_fpe) dc_exc = E_FEN;
            end
        end
        6'h24, 6'h25, 6'h26, 6'h27: begin                                 // STF STG STS STT
            dc_cls = C_ST; dc_ua = 1'b1; dc_ub = 1'b1;
            if (!iccsr_fpe) dc_exc = E_FEN;
        end
        6'h31, 6'h32, 6'h33, 6'h35, 6'h36, 6'h37: begin                   // FBxx
            dc_cls = C_CBR; dc_ua = 1'b1;
            if (!iccsr_fpe) dc_exc = E_FEN;
        end
        6'h17: begin                                                      // FP operate, no arithmetic
            dc_cls = C_ALU; dc_dst = d_rc; dc_dst_v = 1'b1; dc_ua = 1'b1; dc_ub = 1'b1; dc_fast = 1'b0;
            case (d_ir[15:5])
            11'h010, 11'h020, 11'h021, 11'h022,
            11'h030, 11'h130, 11'h530: ;                                  // CVTLQ CPYS CPYSN CPYSE CVTQL
            11'h02A, 11'h02B, 11'h02C, 11'h02D, 11'h02E, 11'h02F: ;       // FCMOVxx (reads Fc too)
            11'h024: begin dc_dst_v = 1'b0; dc_ub = 1'b0; dc_ser = 1'b1; end   // MT_FPCR (Fa)
            11'h025: begin dc_dst = d_ra; dc_ua = 1'b0; dc_ub = 1'b0; dc_ser = 1'b1; end   // MF_FPCR -> Fa
            default: dc_exc = E_OPCDEC;
            endcase
            if (!iccsr_fpe) dc_exc = E_FEN;
        end
        6'h15, 6'h16: begin                                               // FP arithmetic (rtl/cpu/ev4_fpu.v)
            dc_cls = C_SHF; dc_fpu = 1'b1;                                // issued to the FPU in X; the result joins in M2
            dc_dst = d_rc; dc_dst_v = 1'b1; dc_ua = fd_rd_fa; dc_ub = 1'b1;
            if (fd_fen || !iccsr_fpe) dc_exc = E_FEN;
            else if (!fd_legal) dc_exc = E_OPCDEC;
        end
        6'h14:                                                            // ITFP (EV6 FIX): not on the 21064
            dc_exc = E_OPCDEC;
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
        // an interrupt: this instruction does not run. It outranks the instruction's own fetch
        // faults (ITB miss/ACV; HRM Table 4-1, cpu.md 5.1): NT's first user instruction of a new
        // thread (kernel32!BaseProcessStart, not mapped yet) is reached with the APC software
        // interrupt pending, and the APC (ntdll's loader) must run before that fetch faults
        if (intr_req) begin
            dc_exc = E_INTR; dc_cls = C_NOP; dc_dst_v = 1'b0; dc_ua = 1'b0; dc_ub = 1'b0; dc_ser = 1'b0; dc_fpu = 1'b0;
        end else if (d_exc != E_NONE) begin           // fetch fault: nothing else happens
            dc_exc = d_exc; dc_cls = C_NOP; dc_dst_v = 1'b0; dc_ua = 1'b0; dc_ub = 1'b0; dc_ser = 1'b0; dc_fpu = 1'b0;
        end
        if (dc_exc != E_NONE) begin dc_dst_v = 1'b0; dc_ser = 1'b1; dc_fpu = 1'b0; end   // faults retire alone
        if (dc_dst[4:0] == 5'd31) dc_dst_v = 1'b0;
    end
    wire d_fcmov = d_op == 6'h17 && d_ir[15:5] >= 11'h02A && d_ir[15:5] <= 11'h02F;
    wire dc_uc = d_cmov || d_fcmov;
    // integer compares (CMPEQ CMPLT CMPLE CMPULT CMPULE): results 0 or 1
    wire d_iscmp = d_op == 6'h10 && (d_func == 7'h2D || d_func == 7'h4D || d_func == 7'h6D ||
                                     d_func == 7'h1D || d_func == 7'h3D);

    // ================================================================ X stage registers
    reg         x_v;  reg [63:0] x_pc; reg [31:0] x_ir; reg [3:0] x_cls; reg [3:0] x_exc;
    reg  [63:0] x_a, x_b, x_c;
    reg   [5:0] x_dst; reg x_dst_v; reg x_fast; reg x_ldlat; reg x_ser;
    reg  [63:0] x_btarget;
    reg         x_iscmp;                // the instruction in X is an integer compare
    reg  [63:0] x_link;                 // PC + 4, computed in D
    reg  [63:0] x_ipr;                  // HW_MFPR's IPR value, read in D (serialized)
    reg         x_sel_lda, x_sel_link;  // fast-result selects, decoded in D
    reg         x_cmov;
    reg         x_pred;                 // predicted taken (the fetch went to the target)
    reg         x_pk;                   // ... and sure to be right: BR / BSR
    reg         x_pj;                   // ... a jump: right when Rb is the predicted address (compared
    reg  [40:0] x_ptgt;                 //     in X on x_b; in D it sat behind the forwarding, -1.8 ns)
    reg         x_pcbr;                 // ... a conditional branch: right when the condition holds

    // M1 / M2 registers (declared here for forwarding)
    reg         m1_v;  reg [63:0] m1_pc; reg [31:0] m1_ir; reg [3:0] m1_cls; reg [3:0] m1_exc;
    reg  [63:0] m1_rf, m1_rs, m1_va, m1_sd; reg m1_cmf; reg m1_isf;
    reg   [5:0] w_fs;                    // FPCR flags to OR in (FP arithmetic)
    reg   [6:0] w_es;                    // EXC_SUM[8:2] of an FP trap
    wire [63:0] m1_res = m1_isf ? m1_rf : m1_rs;    // fast and slow results come from separate flops
    reg   [5:0] m1_dst; reg m1_dst_v; reg m1_ldlat;
    reg         m2_v;  reg [63:0] m2_pc; reg [31:0] m2_ir; reg [3:0] m2_cls;
    reg  [63:0] m2_res, m2_va, m2_sd; reg m2_cmf;
    reg  [33:0] m2_pa;
    reg   [2:0] w_fb;                   // D_FAULT reason: {FOW, FOR, ACV}
    reg   [3:0] m2_exc0;                // the exception known in M1
    reg         m2_tchk;                // a DTB-translated memory access: check the vectors
    reg  [31:0] m2_dtbm, m2_vacv, m2_vfor, m2_vfow;
    reg  [10:0] m2_dpr, w_dpr;          // debug: the matching DTB entries' protection, and whether several matched
    wire        m2_acv = |m2_vacv, m2_for = |m2_vfor, m2_fow = |m2_vfow;
    wire  [3:0] m2_exc = m2_exc0 != E_NONE ? m2_exc0 :
                         !m2_tchk ? E_NONE :
                         m2_dtbm == 32'd0 ? E_DTBM :
                         (m2_acv || m2_for || m2_fow) ? E_DFAULT : E_NONE;
    wire  [2:0] m2_fb = {m2_fow && !m2_acv, m2_for && !m2_acv, m2_acv};
    reg   [5:0] m2_dst; reg m2_dst_v; reg m2_ldlat;
    reg         r_v; reg [5:0] r_dst; reg [63:0] r_res;      // retired last cycle

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
    wire [63:0] fast_res = x_sel_lda ? agen : x_sel_link ? x_link : fa_res;

    // ---------------------------------------------------------------- FP arithmetic in flight
    // An FP operation (opcodes 15, 16) is issued to the unit in its first cycle in X and moves on
    // with the pipeline; it waits in M2 for its result and takes it into W (docs/design/fpu.md 4,
    // pipeline.md). The unit returns results in issue order, which is program order, and may
    // return one before its operation is in M2 (a stall ahead of it): fq keeps up to three, the
    // operations X, M1 and M2 can hold. A DIVx occupies the unit: no FP operation leaves D while
    // one is in X, M1 or M2. w_redir kills the unit and the queue with the pipeline behind W.
    reg         x_fpu, x_fdiv, x_fpgo, m1_fpu, m1_fdiv, m2_fpu, m2_fdiv;
    wire        fpu_busy, fpu_done, fpu_trap;
    wire [63:0] fpu_result;
    wire  [5:0] fpu_fset;
    wire  [6:0] fpu_esum;
    reg   [1:0] fq_n;
    reg  [77:0] fq0, fq1, fq2;          // {trap, EXC_SUM bits, FPCR bits, result}, fq0 the oldest
    wire [77:0] fq_in = {fpu_trap, fpu_esum, fpu_fset, fpu_result};
    wire        f_ok  = fq_n != 2'd0 || fpu_done;       // the result of M2's operation is here
    wire [77:0] f_hd  = fq_n != 2'd0 ? fq0 : fq_in;
    wire [63:0] f_res = f_hd[63:0];
    wire  [5:0] f_fs  = f_hd[69:64];
    wire  [6:0] f_es  = f_hd[76:70];
    wire        f_tr  = f_hd[77];
    wire        m2_fwait = m2_v && m2_fpu && !f_ok;
    wire        f_pop    = m2_v && m2_fpu && !stall_m2 && !w_redir;
    wire        fp_hold  = dc_fpu && ((x_v && x_fdiv) || (m1_v && m1_fdiv) || (m2_v && m2_fdiv));

    // ---------------------------------------------------------------- hazards and forwarding (D)
    function hit_src;
        input v; input dv; input [5:0] dst; input [5:0] src;
        hit_src = v && dv && dst == src && src[4:0] != 5'd31;
    endfunction

    reg        haz;
    reg [63:0] fwd_a, fwd_b, fwd_c;
    reg        loop_a, loop_b, loop_c;
    task fwd;
        input [5:0] src; input used; input [63:0] rfv;
        output [63:0] val; output loop; output stall;
        begin
            val = rfv; loop = 1'b0; stall = 1'b0;
            if (used && src[4:0] != 5'd31) begin
                if (hit_src(x_v, x_dst_v, x_dst, src)) begin
                    if (x_fast) loop = 1'b1; else stall = 1'b1;
                end else if (hit_src(m1_v, m1_dst_v, m1_dst, src)) begin
                    if (m1_ldlat) stall = 1'b1; else val = m1_res;
                end else if (hit_src(m2_v, m2_dst_v, m2_dst, src)) begin
                    // an FP result is forwarded from M2 once the unit has returned it
                    if (m2_fpu ? !f_ok : m2_ldlat) stall = 1'b1; else val = m2_fpu ? f_res : m2_res;
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
        haz = sa || sb || sc || loop_c ||        // operand C has no loop path: wait a cycle
              (dc_cls == C_CBR && loop_a && !x_iscmp);   // a branch loops only from a compare
    end

    // serialization
    reg  ser_pending;
    wire pipe_busy = x_v || m1_v || m2_v || w_v;
    wire ser_wait  = d_v && (ser_pending || (dc_ser && pipe_busy));
    assign stall_d = stall_x || (d_v && (haz || ser_wait || fp_hold));

    // ================================================================ X stage
    // multiplier
    reg         mul_go, mul_fin, mul_live;    // mul_live: the running multiply belongs to X
    wire        mul_busy, mul_done, mul_ovf;
    wire [63:0] mul_res;
    ev4_imul xmul (.clk(clk), .rst(rst), .start(mul_go), .func(x_ir[11:5]), .a(x_a), .b(x_b),
                   .busy(mul_busy), .done(mul_done), .res(mul_res), .ovf(mul_ovf), .illegal());
    wire x_mul_wait = x_v && x_cls == C_MUL && x_exc == E_NONE && !mul_fin;

    // the FP arithmetic unit: started in the operation's first cycle in X (x_fpgo, a flop)
    ev4_fpu #(.TAG_W(1)) fpu (.clk(clk), .rst(rst), .kill(w_redir), .start(x_fpgo), .ir(x_ir), .fa(x_a), .fb(x_b),
        .fpcr_dyn(fpcr_dyn), .tag(1'b0), .busy(fpu_busy), .done(fpu_done), .done_tag(),
        .result(fpu_result), .fpcr_set(fpu_fset), .exc_sum(fpu_esum), .trap(fpu_trap));
    assign stall_x = stall_m1 || x_mul_wait;

    // IPR read, in D (HW_MFPR issues serialized, so the state is current)
    reg [63:0] ipr_rd;
    always @* begin
        ipr_rd = 64'd0;
        if (d_ir[7])      ipr_rd = pal_temp[d_ir[4:0]];
        else if (d_ir[6]) case (d_ir[4:0])
            5'd3:  ipr_rd = {29'd0, dtb_temp};                             // DTB_PTE_TEMP
            5'd4:  ipr_rd = {49'd0, mm_csr};
            5'd12: ipr_rd = {60'd0, 1'b0, 3'b111};                        // DC_STAT: CHIP_ID 7 = production 21064
            5'd5:  ipr_rd = va_ipr;
            default: ipr_rd = 64'd0;
            endcase
        else if (d_ir[5]) case (d_ir[4:0])
            5'd2:  ipr_rd = {40'd0, iccsr_fpe, iccsr_map, iccsr_hwe, 21'd0};
            5'd3:  ipr_rd = {29'd0, itb_temp};                             // ITB_PTE_TEMP
            5'd4:  ipr_rd = exc_addr;
            5'd10: ipr_rd = {30'd0, exc_mask[63], 24'd0, exc_sum_r, 2'b00};   // EXC_SUM, MSK
            5'd5:  ipr_rd = {60'd0, sl_rcv, 3'b000};                       // SL_RCV
            5'd12, 5'd13, 5'd14: ipr_rd = hirr_rd;                        // HIRR (SIRR, ASTRR read the same)
            5'd16, 5'd17, 5'd18: ipr_rd = hier_rd;                        // HIER (SIER, ASTER read the same)
            5'd9:  ipr_rd = {29'd0, ps_cm[1], 32'd0, ps_cm[0], 1'b0};
            5'd11: ipr_rd = {30'd0, pal_base, 14'd0};
            default: ipr_rd = 64'd0;
            endcase
    end

    // branch resolution
    // the branch condition from flags of operand A computed with it in D (or
    // from the forwarded result): the zero tests are off the X -> next-PC path
    reg x_az, x_az63, x_as, x_al;       // A == 0, A[62:0] == 0, A[63], A[0]
    reg x_cond;
    always @* begin
        if (!x_ir[29]) begin                                              // FBxx (opcodes 31-37)
            case (x_ir[28:26])
            3'd1: x_cond = x_az63;                                        // FBEQ
            3'd2: x_cond = x_as && !x_az63;                               // FBLT
            3'd3: x_cond = x_as || x_az63;                                // FBLE
            3'd5: x_cond = !x_az63;                                       // FBNE
            3'd6: x_cond = !(x_as && !x_az63);                            // FBGE
            default: x_cond = !(x_as || x_az63);                          // FBGT
            endcase
        end else
        case (x_ir[28:26])
        3'd0: x_cond = !x_al;
        3'd1: x_cond = x_az;
        3'd2: x_cond = x_as;
        3'd3: x_cond = x_as || x_az;
        3'd4: x_cond = x_al;
        3'd5: x_cond = !x_az;
        3'd6: x_cond = !x_as;
        default: x_cond = !x_as && !x_az;
        endcase
    end
    wire x_fire = x_v && !stall_x && !w_redir;
    // a redirect is a wrong prediction: taken and not predicted, or predicted and not taken
    // (x_btarget is PC + 4 then), or a jump to another address than the return stack's
    wire x_taken = x_cls == C_BR || x_cls == C_JMP || (x_cls == C_CBR && x_cond);
    assign x_redir = x_fire && x_exc == E_NONE && (x_pcbr ? !x_cond : x_pred ? !(x_pk || (x_pj && x_b[63:2] == {{21{x_ptgt[40]}}, x_ptgt})) : x_taken);
    assign x_target_r = x_cls == C_JMP ? {x_b[63:2], 2'b00} : x_btarget;
    // the return stack as the instructions that ran leave it
    wire        x_push = x_ir[31:26] == 6'h34 || (x_cls == C_JMP && x_ir[14]);
    wire        x_pop  = x_cls == C_JMP && x_ir[15];
    wire        x_rsop = x_fire && x_exc == E_NONE && (x_cls == C_BR || x_cls == C_JMP);
    wire  [1:0] cs_sp_n = !x_rsop || x_push == x_pop ? cs_sp : x_push ? cs_sp + 2'd1 : cs_sp - 2'd1;
    wire  [2:0] cs_n_n  = !x_rsop ? cs_n :
                          x_push && x_pop ? (cs_n == 3'd0 ? 3'd1 : cs_n) :
                          x_push ? (cs_n == 3'd4 ? 3'd4 : cs_n + 3'd1) :
                          x_pop  ? (cs_n == 3'd0 ? 3'd0 : cs_n - 3'd1) : cs_n;

    // the slow X results (into M1's second result flop)
    // FP operate (opcode 17), FPCR (cpu.md 8.2, 8.5)
    wire [63:0] fpcr_rd = {|fpcr_f, 3'b000, fpcr_dyn, fpcr_f[5], fpcr_f[4], fpcr_f[3], fpcr_f[2], fpcr_f[1], fpcr_f[0], 52'd0};
    function ftest;                     // the FBxx / FCMOVxx condition on Fa ({ir[28:26]} or func[2:0])
        input [2:0] c; input [63:0] f;
        reg z, n;
        begin
            z = f[62:0] == 63'd0; n = f[63] && !z;
            case (c)
            3'd1: ftest = z;            // EQ (FBEQ 31, FCMOVEQ 2A -> 2)
            3'd2: ftest = n;            // LT
            3'd3: ftest = n || z;       // LE
            3'd5: ftest = !z;           // NE
            3'd6: ftest = !n;           // GE
            3'd7: ftest = !(n || z);    // GT
            default: ftest = 1'b0;
            endcase
        end
    endfunction
    reg [63:0] fpx_res;
    always @* begin
        case (x_ir[15:5])
        11'h010: fpx_res = {{32{x_b[63]}}, x_b[63:62], x_b[58:29]};                      // CVTLQ
        11'h020: fpx_res = {x_a[63], x_b[62:0]};                                          // CPYS
        11'h021: fpx_res = {~x_a[63], x_b[62:0]};                                         // CPYSN
        11'h022: fpx_res = {x_a[63:52], x_b[51:0]};                                       // CPYSE
        11'h024: fpx_res = x_a;                                                           // MT_FPCR (into W)
        11'h025: fpx_res = fpcr_rd;                                                       // MF_FPCR
        11'h02A: fpx_res = ftest(3'd1, x_a) ? x_b : x_c;                                  // FCMOVEQ
        11'h02B: fpx_res = ftest(3'd5, x_a) ? x_b : x_c;                                  // FCMOVNE
        11'h02C: fpx_res = ftest(3'd2, x_a) ? x_b : x_c;                                  // FCMOVLT
        11'h02D: fpx_res = ftest(3'd6, x_a) ? x_b : x_c;                                  // FCMOVGE
        11'h02E: fpx_res = ftest(3'd3, x_a) ? x_b : x_c;                                  // FCMOVLE
        11'h02F: fpx_res = ftest(3'd7, x_a) ? x_b : x_c;                                  // FCMOVGT
        default: fpx_res = {x_b[31:30], 3'b000, x_b[29:0], 29'd0};                        // CVTQL (/V, /SV)
        endcase
    end
    wire x_fpop = x_ir[31:26] == 6'h17;
    // FP store data in memory format (cpu.md 8.3)
    reg [63:0] x_sdata;
    always @* begin
        case (x_ir[31:26])
        6'h24: x_sdata = {32'd0, x_a[44:29], x_a[63:62], x_a[58:45]};                    // STF
        6'h25: x_sdata = {x_a[15:0], x_a[31:16], x_a[47:32], x_a[63:48]};                // STG
        6'h26: x_sdata = {32'd0, x_a[63:62], x_a[58:29]};                                 // STS
        default: x_sdata = x_a;                                                           // integer, STT
        endcase
    end

    reg [63:0] x_slow;
    always @* begin
        if (x_fpop) x_slow = fpx_res; else
        case (x_cmov ? C_CMOVX : x_cls)
        C_CMOVX: x_slow = fa_wr ? fa_res : x_c;                // a false CMOV keeps Rc
        C_SHF:  x_slow = sh_res;
        C_MUL:  x_slow = mul_res;
        C_MFPR: x_slow = x_ipr;
        C_MTPR: x_slow = x_b;
        C_MISC: x_slow = x_ir[15:0] == 16'hC000 ? {cc_hi, cc} : {63'd0, intr_flag};
        default: x_slow = 64'd0;
        endcase
    end
    wire x_isf = (x_cls == C_ALU && !x_cmov && !x_fpop) || x_cls == C_LDA || x_cls == C_BR || x_cls == C_JMP;
    wire x_ovf = (x_cls == C_ALU && !x_fpop && fa_ovf) || (x_cls == C_MUL && mul_ovf);

    // ================================================================ M1
    // D-stream translation of the registered VA
    wire        m1_hw   = m1_ir[31:26] == 6'h1B || m1_ir[31:26] == 6'h1F;
    wire        m1_phys = m1_hw && m1_ir[15];
    wire  [1:0] m1_cm   = (m1_hw && m1_ir[14]) ? alt_cm : ps_cm;
    wire        m1_quad = m1_hw ? m1_ir[12] :
                          (m1_ir[31:26] == 6'h0B || m1_ir[31:26] == 6'h0F || m1_ir[31:26] == 6'h29 ||
                           m1_ir[31:26] == 6'h2B || m1_ir[31:26] == 6'h2D || m1_ir[31:26] == 6'h2F ||
                           m1_ir[31:26] == 6'h21 || m1_ir[31:26] == 6'h23 || m1_ir[31:26] == 6'h25 || m1_ir[31:26] == 6'h27);
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
    // protection (DTB hits only; superpages are kernel-only by construction),
    // and the D-cache tag compare, both per entry and ORed (no serial select
    // of the matching entry first: cpu-timing.md)
    wire        m1_wr   = m1_cls == C_ST;
    // HW_LD with RWC (ir[13], virtual): the read also needs write access and takes FOW (the PAL's
    // PROBEW; cpu.md 11.5). OpenVMS's PROBEW said yes to a user write of the supervisor stack
    // without it, and DCL then took the ACCVIO (gaps.md, OpenVMS 7.3's installer)
    wire        m1_rwc  = m1_hw && m1_ir[31:26] == 6'h1B && m1_ir[13] && !m1_phys;
    wire        m1_spx  = m1_phys || m1_sp2 || m1_sp1;
    reg  [31:0] dtb_acv, dtb_for, dtb_fow, dtb_teq;
    integer dj;
    always @* begin
        for (dj = 0; dj < 32; dj = dj + 1) begin : pe
            reg [33:13] p;
            p = {dtb_pfn[dj][33:22],
                 dtb_gh[dj] == 2'd3 ? m1_va[21:19] : dtb_pfn[dj][21:19],
                 dtb_gh[dj][1]      ? m1_va[18:16] : dtb_pfn[dj][18:16],
                 dtb_gh[dj] != 2'd0 ? m1_va[15:13] : dtb_pfn[dj][15:13]};
            dtb_teq[dj] = dtb_m[dj] && p == dct_q && p[33:32] == 2'd0;
            dtb_acv[dj] = dtb_m[dj] && (m1_wr ? !dtb_pr[dj][4 + m1_cm] : (!dtb_pr[dj][m1_cm] || (m1_rwc && !dtb_pr[dj][4 + m1_cm])));
            dtb_for[dj] = dtb_m[dj] && !m1_wr && dtb_pr[dj][8];
            dtb_fow[dj] = dtb_m[dj] && (m1_wr || m1_rwc) && dtb_pr[dj][9];
        end
    end
    wire        m1_acv  = !m1_spx && |dtb_acv;
    wire        m1_for  = !m1_spx && |dtb_for;
    wire        m1_fow  = !m1_spx && |dtb_fow;
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
    reg         tagw;                   // (blocking) a D-cache tag write is taken this cycle
    reg         dinv_p; reg [7:0] dinv_pi;   // a DMA invalidate waiting for the tag port
    wire [12:3] dc_ra = stall_m1 ? m1_va[12:3] : agen[12:3];
    ev4_ram #(.AW(10), .DW(64), .BE(8)) dcache_d (.clk(clk), .raddr(dc_ra), .rdata(dc_q),
        .we(dc_we), .waddr(dc_wa), .wdata(dc_wd), .wbe(dc_wbe));
    ev4_ram #(.AW(8), .DW(22), .BE(1)) dcache_t (.clk(clk), .raddr(dc_ra[12:5]), .rdata(dct_qv),
        .we(dct_we), .waddr(dct_wa), .wdata({dct_v, dct_wd}), .wbe(1'b1));

    reg  [63:0] m2_dq; reg [20:0] m2_dt; reg m2_dv;     // registered D-cache outputs
    reg         m2_hitq;                                 // the hit, compared in M1 (timing)
    // M1 compares the tag it just read (M1 re-reads while stalled, so this
    // stays current through fills)
    wire        m1_sptag = (m1_phys || m1_sp2) ? (m1_va[33:32] == 2'd0 && dct_q == m1_va[33:13])
                                               : (dct_q == {4'd0, m1_va[29:13]});
    wire        m1_hit = dc_ena && !dsweep && dcv_q && (m1_spx ? m1_sptag : |dtb_teq);

    // ================================================================ M2
    wire        m2_hw    = m2_ir[31:26] == 6'h1B || m2_ir[31:26] == 6'h1F;
    wire        m2_quad  = m2_hw ? m2_ir[12] :
                           (m2_ir[31:26] == 6'h0B || m2_ir[31:26] == 6'h0F || m2_ir[31:26] == 6'h29 ||
                            m2_ir[31:26] == 6'h2B || m2_ir[31:26] == 6'h2D || m2_ir[31:26] == 6'h2F ||
                            m2_ir[31:26] == 6'h21 || m2_ir[31:26] == 6'h23 || m2_ir[31:26] == 6'h25 || m2_ir[31:26] == 6'h27);
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
    reg         sh0_v, sh1_v, sh2_v; reg [12:3] sh0_a, sh1_a, sh2_a; reg [63:0] sh0_d, sh1_d, sh2_d; reg [7:0] sh0_b, sh1_b, sh2_b;
    function [63:0] merge;
        input [63:0] q; input v; input [33:3] a; input [33:3] la; input [63:0] d; input [7:0] be;
        integer k;
        begin
            merge = q;
            if (v && a == la)
                for (k = 0; k < 8; k = k + 1) if (be[k]) merge[8*k +: 8] = d[8*k +: 8];
        end
    endfunction
    // the address compares are done in M1 against the entries the load will
    // meet in M2 (sh0, sh1 then and the store committing then) and registered
    // with their data (timing: they ran from m2_pa into the load result).
    // Only the D-cache index is compared (cpu-timing.md): the history holds
    // stores that hit, the merged data is used only when the load hits
    // (m2_lq), and two hits on one index are on one line, so one address. The
    // tag cannot change in between: a fill takes more cycles than the history
    // lives (and clears it), an invalidate makes the load miss. The full
    // compare ran m1_va -> DTB -> m1_pa -> 31 bits, the worst path of the core
    reg         mg2_v, mg1_v, mg0_v;
    reg  [63:0] mg2_d, mg1_d, mg0_d;
    reg   [7:0] mg2_b, mg1_b, mg0_b;
    function [63:0] mrg;
        input [63:0] q; input v; input [63:0] d; input [7:0] be;
        integer k;
        begin
            mrg = q;
            if (v) for (k = 0; k < 8; k = k + 1) if (be[k]) mrg[8*k +: 8] = d[8*k +: 8];
        end
    endfunction
    wire [63:0] m2_dqm = mrg(mrg(mrg(m2_dq, mg2_v, mg2_d, mg2_b), mg1_v, mg1_d, mg1_b), mg0_v, mg0_d, mg0_b);
    // the store M2 commits into the D-cache this cycle (becomes sh0)

    // the bus side of M2: misses and uncached loads
    localparam MS_IDLE = 2'd0, MS_WAIT = 2'd1, MS_DONE = 2'd2;
    reg   [1:0] mstate;
    reg  [63:0] m2_ldata;               // data from the bus for this load
    localparam B_NONE = 2'd0, B_DFILL = 2'd1, B_IFILL = 2'd2, B_WB = 2'd3;
    reg   [1:0] bown;
    integer wi, wj;
    // The write buffer: four entries in a ring, each one 32-byte line with byte enables. A memory
    // store joins the entry of its line, unless that entry is on the bus, and else takes a new one:
    // the stores of a stack frame or a copy loop leave as one line write. I/O writes never merge:
    // each is one entry holding its quadword in the low 64 bits, and leaves in program order.
    reg   [3:0] wb_ev;                  // entry valid
    reg   [1:0] wb_wp, wb_rp;           // next free entry, oldest entry
    reg  [33:5] wb_la [0:3];
    reg   [3:0] wb_io;
    reg   [1:0] wb_q  [0:3];            // an I/O write's quadword in its line
    reg  [31:0] wb_m  [0:3];
    reg [255:0] wb_ld [0:3];
    wire        wb_any  = |wb_ev;
    wire        wb_full = &wb_ev;
    wire        m2_io   = m2_pa[33:32] != 2'd0;
    wire  [3:0] wb_same = {wb_la[3] == m2_pa[33:5], wb_la[2] == m2_pa[33:5], wb_la[1] == m2_pa[33:5], wb_la[0] == m2_pa[33:5]}
                          & wb_ev & ~wb_io & ~((bown == B_WB) ? (4'd1 << wb_rp) : 4'd0);
    wire        wb_join = !m2_io && wb_same != 4'd0;
    // an I-fill must not read a line the buffer still holds (code copied, then run)
    wire        wb_ihit = |({wb_la[3] == ifill_line, wb_la[2] == ifill_line, wb_la[1] == ifill_line, wb_la[0] == ifill_line} & wb_ev);
    assign mem_wmask = wb_m[wb_rp];
    assign mem_wline = wb_ld[wb_rp];

    wire m2_live    = m2_v && m2_exc == E_NONE && !w_redir;
    wire m2_need_bus = m2_live && m2_load && !m2_hit && mstate != MS_DONE;
    wire m2_need_wb  = m2_live && m2_store && wb_full;  // buffer full (a failing STx_C waits too: timing)
    // after a D-fill the line's tag and data land in the RAMs one cycle after the
    // last beat and M1 reads them a cycle later: hold M1 until it has re-read them,
    // or a store behind the load is judged a miss against the old (invalid) tag,
    // skips the D-cache (write-through, no allocate) and leaves the filled line stale
    // (ARC 4.58's FindScsiDevices: stl then ldl of the same longword read 0)
    reg   [1:0] dsettle;
    assign stall_m2 = m2_need_bus || m2_need_wb || dsettle != 2'd0 || m2_fwait;
    assign stall_m1 = stall_m2;

    reg [63:0] m2_lq;
    always @* m2_lq = m2_hit ? m2_dqm : m2_ldata;
    // FP loads in register format (cpu.md 8.3): the exponent maps of S and F
    function [10:0] map_exp;
        input [7:0] e; input s_fmt;
        map_exp = (s_fmt && e == 8'hFF) ? 11'h7FF : e == 8'd0 ? 11'd0 :
                  e[7] ? {4'b1000, e[6:0]} : {4'b0111, e[6:0]};
    endfunction
    reg [63:0] m2_lres;
    reg [31:0] m2_lw;
    always @* begin
        m2_lw = m2_pa[2] ? m2_lq[63:32] : m2_lq[31:0];
        case (m2_ir[31:26])
        6'h20: m2_lres = {m2_lw[15], map_exp(m2_lw[14:7], 1'b0), m2_lw[6:0], m2_lw[31:16], 29'd0};   // LDF
        6'h21: m2_lres = {m2_lq[15:0], m2_lq[31:16], m2_lq[47:32], m2_lq[63:48]};                 // LDG
        6'h22: m2_lres = {m2_lw[31], map_exp(m2_lw[30:23], 1'b1), m2_lw[22:0], 29'd0};             // LDS
        default: m2_lres = m2_quad ? m2_lq : {{32{m2_lw[31]}}, m2_lw};
        endcase
    end

    // ================================================================ bus (one transaction at a time)
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
        E_INTR:   begin w_ent = 1'b1; w_off = 14'h00E0; end
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
        tagw = 1'b0;
        dbg_retire <= 1'b0;
        ic_we <= 1'b0; ict_we <= 1'b0; dc_we <= 1'b0; dct_we <= 1'b0;
        // a fill's tag write lands one cycle after its last beat (registered
        // write port): the line becomes valid with it, and the fetch restarts
        // the cycle after, so its read sees the new tag
        // (also during a sweep: a fill started before a FLUSH_IC must still finish
        // its state machine, or the fetch never leaves FS_FILL; the sweep holds fetch)
        ifill_done <= ict_we && ict_v && !rst && !ld_active;
        mul_go <= 1'b0;
`ifdef SIM_PCILOG
        if (cc_en) cc <= cc + cc_step;
`else
        if (cc_en) cc <= cc + 32'd1;
`endif
        if (rst) begin
            pal <= 1'b1; iccsr_fpe <= 1'b0; iccsr_map <= 1'b0; iccsr_hwe <= 1'b0;
            pal_base <= 20'd0; abox_ctl <= 16'd0; ps_cm <= 2'd0; alt_cm <= 2'd0;
            itb_v <= 12'd0; dtb_v <= 32'd0; itb_sp <= 3'd0; itb_lp <= 2'd0; dtb_p <= 5'd0;
            fpcr_f <= 6'd0; fpcr_dyn <= 2'b10;
            hier <= 6'd0; hier_pc0 <= 1'b0; hier_pc1 <= 1'b0; hier_cre <= 1'b0; hier_sle <= 1'b0;
            sier <= 15'd0; sirr <= 15'd0; aster <= 4'd0; astrr <= 4'd0;
            mm_lock <= 1'b0; lock_flag <= 1'b0; intr_flag <= 1'b0; cc <= 32'd0; cc_hi <= 32'd0; cc_en <= 1'b0;
            fstate <= FS_FETCH; ifill_issued <= 1'b0; pc_f1 <= 64'd0; v_f1 <= 1'b0; v_f2 <= 1'b0;   // fetch starts after the sweep or the SROM load
            ld_active <= !icmode; ld_start <= 1'b0; ld_fin <= 1'b0; ld_bcnt <= 9'd0; ld_blk <= 9'd0;
            ld_byte_ok <= 1'b0; ld_fetch <= 2'd0; ld_baddr <= 14'd0; ld_wph <= 3'd0;
            isweep <= icmode; isw_idx <= 8'd0; dsweep <= 1'b1; dsw_idx <= 8'd0; restart_after <= 64'd0;
            dinv_p <= 1'b0;
            sl_xmit <= 1'b1;
            d_v <= 1'b0; x_v <= 1'b0; m1_v <= 1'b0; m2_v <= 1'b0; w_v <= 1'b0; r_v <= 1'b0;
            ser_pending <= 1'b0; mul_fin <= 1'b0; mul_live <= 1'b0; mstate <= MS_IDLE;
            x_fpgo <= 1'b0; fq_n <= 2'd0; rs_sp <= 2'd0; cs_sp <= 2'd0; rs_n <= 3'd0; cs_n <= 3'd0; exc_sum_r <= 7'd0; exc_mask <= 64'd0;
            wb_ev <= 4'd0; wb_wp <= 2'd0; wb_rp <= 2'd0; bown <= B_NONE; mem_req <= 1'b0; dsettle <= 2'd0;
            sh0_v <= 1'b0; sh1_v <= 1'b0; sh2_v <= 1'b0;
        end else begin
            // ------------------------------------------------ cache sweeps
            // (a fill's last tag write takes the port this cycle: wait one)
            if (isweep && !(bown == B_IFILL && mem_ack && bbeat == 2'd3)) begin
                ict_we <= 1'b1; ict_wa <= isw_idx; ict_v <= 1'b0; ict_wd <= 21'd0;
                isw_idx <= isw_idx + 8'd1;
                if (isw_idx == 8'd255) begin isweep <= 1'b0; ld_start <= 1'b1; end
            end
            if (dsweep) begin
                dct_we <= 1'b1; dct_wa <= dsw_idx; dct_v <= 1'b0; dct_wd <= 21'd0; tagw = 1'b1;
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
                f2_phys <= f1_phys; f2_itbany <= itb_m != 12'd0;
                itb_spfn <= itb_spfn1; itb_sre <= itb_sre1; itb_large <= itb_large1;
            end

            // ------------------------------------------------ D
            if (w_redir || x_redir) d_v <= 1'b0;
            else if (!f_hold) begin
                d_v   <= v_f2 && (fstate == FS_FETCH) && (!f2_tr_ok || f2_hit);
                d_pc  <= pc_f2;
                d_ir  <= f2_tr_ok ? f2_insn : 32'd0;
                d_exc <= f2_tr_ok ? E_NONE : f2_itbm ? E_ITBM : E_ITBACV;
                d_pred <= p_take; d_ptgt <= rs_top;
            end

            // the return stack: pushed and popped as calls and returns leave F2, put back to what
            // the instructions that ran left when X or W redirects
            cs_sp <= cs_sp_n; cs_n <= cs_n_n;
            if (w_redir || x_redir) begin
                rs_sp <= cs_sp_n; rs_n <= cs_n_n;
            end else if (f2_go && (f2_push || f2_pop)) begin
                if (f2_push) begin
                    case (f2_pop ? rs_sp : rs_sp + 2'd1)
                    2'd0: rs0 <= f2_link[42:2];
                    2'd1: rs1 <= f2_link[42:2];
                    2'd2: rs2 <= f2_link[42:2];
                    default: rs3 <= f2_link[42:2];
                    endcase
                end
                if (f2_push && !f2_pop) begin rs_sp <= rs_sp + 2'd1; rs_n <= rs_n == 3'd4 ? 3'd4 : rs_n + 3'd1; end
                else if (!f2_push)      begin rs_sp <= rs_sp - 2'd1; rs_n <= rs_n == 3'd0 ? 3'd0 : rs_n - 3'd1; end
                else if (rs_n == 3'd0) rs_n <= 3'd1;
            end

            // ------------------------------------------------ D -> X
            x_fpgo <= 1'b0;
            if (w_redir) x_v <= 1'b0;
            else if (!stall_x) begin
                x_v <= d_v && !stall_d && !x_redir;
                if (d_v && !stall_d && !x_redir) begin
                    x_pc <= d_pc; x_ir <= d_ir; x_cls <= dc_cls; x_exc <= dc_exc;
                    x_dst <= dc_dst; x_dst_v <= dc_dst_v; x_fast <= dc_fast; x_ldlat <= dc_ldlat || dc_fpu;
                    x_ser <= dc_ser;
                    x_a <= loop_a ? fast_res : fwd_a;
                    // a branch takes the loop only from a compare (result 0 or 1), so
                    // the flags come from bit 0 (no zero test after the ALU)
                    x_az   <= loop_a ? !fast_res[0] : fwd_a == 64'd0;
                    x_az63 <= loop_a ? !fast_res[0] : fwd_a[62:0] == 63'd0;
                    x_as   <= loop_a ? 1'b0 : fwd_a[63];
                    x_al   <= loop_a ? fast_res[0] : fwd_a[0];
                    x_iscmp <= d_iscmp;
                    x_b <= d_lit && d_op[5:2] == 4'b0100      // the literal form: integer operate (10-13) only
                           ? {56'd0, d_ir[20:13]} : (loop_b ? fast_res : fwd_b);
                    x_c <= fwd_c;                       // CMOV's Rc: never from the loop (stalls instead)
                    // where a wrong prediction goes: the target, or PC + 4 when it was predicted taken
                    x_btarget <= d_pred ? d_pc + 64'd4 : d_pc + 64'd4 + {{41{d_ir[20]}}, d_ir[20:0], 2'b00};
                    x_pred <= d_pred; x_pcbr <= d_pred && dc_cls == C_CBR;
                    x_pk   <= d_pred && dc_cls == C_BR;
                    x_pj   <= d_pred && dc_cls == C_JMP; x_ptgt <= d_ptgt;
                    x_link <= d_pc + 64'd4;
                    x_ipr <= ipr_rd;
                    x_sel_lda <= dc_cls == C_LDA;
                    x_sel_link <= dc_cls == C_BR || dc_cls == C_JMP;
                    x_cmov <= d_cmov;
                    x_fpu <= dc_fpu; x_fdiv <= dc_fpu && fd_div; x_fpgo <= dc_fpu;
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
            // the FPU's results: fq0 leaves with M2's operation, a new one joins behind the others
            // (taken straight from the unit when the queue is empty)
            if (f_pop && fq_n != 2'd0) begin fq0 <= fq1; fq1 <= fq2; end
            if (fpu_done && !(f_pop && fq_n == 2'd0))
                case (f_pop ? fq_n - 2'd1 : fq_n)
                2'd0: fq0 <= fq_in;
                2'd1: fq1 <= fq_in;
                default: fq2 <= fq_in;
                endcase
            if (w_redir) fq_n <= 2'd0;
            else fq_n <= fq_n + {1'b0, fpu_done} - {1'b0, f_pop};

            // ------------------------------------------------ X -> M1
            if (w_redir) m1_v <= 1'b0;
            else if (!stall_m1) begin
                // a multiply waits in X for the multiplier: without the gate a copy of it entered M1
                // every waiting cycle
                m1_v <= x_v && !x_mul_wait;
                m1_pc <= x_pc; m1_ir <= x_ir; m1_cls <= x_cls;
                m1_exc <= (x_exc == E_NONE && x_ovf) ? E_ARITH : x_exc;
                m1_fpu <= x_fpu; m1_fdiv <= x_fdiv;
                m1_rf <= fast_res; m1_rs <= x_slow; m1_isf <= x_isf; m1_va <= x_va; m1_sd <= x_sdata; m1_cmf <= x_cls == C_ALU && !x_fpop && !fa_wr;
                m1_dst <= x_dst; m1_dst_v <= x_dst_v; m1_ldlat <= x_ldlat;
            end

            // ------------------------------------------------ M1 -> M2
            if (w_redir) m2_v <= 1'b0;
            else if (!stall_m2) begin
                m2_v <= m1_v;
                m2_pc <= m1_pc; m2_ir <= m1_ir; m2_cls <= m1_cls; m2_res <= m1_res;
                m2_va <= m1_va; m2_sd <= m1_sd; m2_pa <= m1_pa; m2_cmf <= m1_cmf; m2_fpu <= m1_fpu; m2_fdiv <= m1_fdiv;
                m2_dst <= m1_dst; m2_dst_v <= m1_dst_v; m2_ldlat <= m1_ldlat;
                // translation faults are formed in M2 from registered vectors (timing)
                m2_exc0 <= (m1_exc != E_NONE || !m1_mem) ? m1_exc : m1_unal ? E_UNAL : E_NONE;
                m2_tchk <= m1_exc == E_NONE && m1_mem && !m1_unal && !m1_spx;
                m2_dtbm <= dtb_m; m2_vacv <= dtb_acv; m2_vfor <= dtb_for; m2_vfow <= dtb_fow;
                m2_dpr <= {(dtb_m & (dtb_m - 32'd1)) != 32'd0, dtb_spr};
                m2_dq <= dc_q; m2_dt <= dct_q; m2_dv <= dcv_q; m2_hitq <= m1_hit;
                // store history as M2 will see it: sh1 -> sh2, sh0 -> sh1, M2's commit -> sh0
                mg2_v <= sh1_v && sh1_a == m1_va[12:3]; mg2_d <= sh1_d; mg2_b <= sh1_b;
                mg1_v <= sh0_v && sh0_a == m1_va[12:3]; mg1_d <= sh0_d; mg1_b <= sh0_b;
                mg0_v <= m2_live && m2_store && !(m2_stc && !m2_stc_ok) && m2_hit && m2_pa[12:3] == m1_va[12:3];
                mg0_d <= m2_wq; mg0_b <= m2_be;
                mstate <= MS_IDLE;
            end

            // store history ages every cycle
            sh2_v <= sh1_v; sh2_a <= sh1_a; sh2_d <= sh1_d; sh2_b <= sh1_b;
            sh1_v <= sh0_v; sh1_a <= sh0_a; sh1_d <= sh0_d; sh1_b <= sh0_b;
            sh0_v <= 1'b0;

            // ------------------------------------------------ M2 actions (commit when it advances)
            if (m2_live && !stall_m2) begin
                if (m2_store && !(m2_stc && !m2_stc_ok)) begin
                    for (wi = 0; wi < 4; wi = wi + 1)
                        if (wb_join ? wb_same[wi] : wb_wp == wi) begin
                            if (!wb_join) begin
                                wb_ev[wi] <= 1'b1; wb_la[wi] <= m2_pa[33:5]; wb_io[wi] <= m2_io; wb_q[wi] <= m2_pa[4:3];
                                wb_m[wi] <= 32'd0;
                            end
                            for (wj = 0; wj < 8; wj = wj + 1)
                                if (m2_be[wj]) begin
                                    wb_m[wi][{m2_io ? 2'd0 : m2_pa[4:3], wj[2:0]}] <= 1'b1;
                                    wb_ld[wi][{m2_io ? 2'd0 : m2_pa[4:3], wj[2:0], 3'd0} +: 8] <= m2_wq[8 * wj +: 8];
                                end
                        end
                    if (!wb_join) wb_wp <= wb_wp + 2'd1;
                    if (m2_hit) begin
                        dc_we <= 1'b1; dc_wa <= m2_pa[12:3]; dc_wd <= m2_wq; dc_wbe <= m2_be;
                        sh0_v <= 1'b1; sh0_a <= m2_pa[12:3]; sh0_d <= m2_wq; sh0_b <= m2_be;
                    end
                end
                if (m2_lock) begin lock_flag <= 1'b1; lock_addr <= m2_pa[33:4]; end
                // the 21071-CA's lock (cpu.md 9.1) is cleared by any STx_C and any CPU write
                // to I/O space: an interrupt's 8259 EOI between LDx_L and STx_C makes it fail
                if (m2_stc || (m2_store && m2_pa[33:32] != 2'd0)) lock_flag <= 1'b0;
            end

            // ------------------------------------------------ M2 -> W
            if (w_redir) w_v <= 1'b0;
            else begin
                w_v <= m2_v && !stall_m2;
                w_pc <= m2_pc; w_ir <= m2_ir; w_cls <= m2_cls;
                // an FP operation's trap, flags and result come with it from the unit: each takes its
                // own, never what the FP operation before it left (NT 4.0 + IE 4.01: win32k's
                // CMPTLT/SU after IE's user-mode NaN compares took a bogus ARITH, STOP 0x3B;
                // 2026-11-04, tests/cpu/t3_fpld.py)
                w_exc <= (m2_fpu && f_tr) ? E_ARITH : m2_exc;
                w_dst <= m2_dst; w_dst_v <= m2_dst_v; w_va <= m2_va; w_cmf <= m2_cmf; w_fb <= m2_fb; w_fs <= m2_fpu ? f_fs : 6'd0; w_es <= (m2_fpu && f_tr) ? f_es : 7'd0; w_dpr <= m2_dpr;
                w_res <= m2_load ? m2_lres : (m2_store && m2_stc) ? {63'd0, m2_stc_ok} : m2_fpu ? f_res : m2_res;
                w_st <= m2_store && m2_exc == E_NONE && !(m2_stc && !m2_stc_ok);
                w_sdata <= m2_quad ? m2_sd : {32'd0, m2_sd[31:0]};
                w_ssize <= m2_quad ? 4'd8 : 4'd4;
                w_ser <= m2_cls == C_CPAL || m2_cls == C_MFPR || m2_cls == C_MTPR || m2_cls == C_REI ||
                         m2_hw || (m2_cls == C_MISC && (m2_ir[15:0] == 16'hE000 || m2_ir[15:0] == 16'hF000)) ||
                         (m2_ir[31:26] == 6'h17 && (m2_ir[15:5] == 11'h024 || m2_ir[15:5] == 11'h025));   // MT/MF_FPCR
            end

            // ------------------------------------------------ W: retire
            r_v <= rf_we; r_dst <= w_dst; r_res <= w_res;
            dbg_ent <= 1'b0; dbg_psw <= 1'b0;
            if (w_v) begin
                if (w_exc == E_NONE || w_exc == E_ARITH) begin
                    fpcr_f <= fpcr_f | w_fs;            // FP arithmetic flags, trap or not
                    if (w_exc == E_ARITH && w_es != 7'd0) begin
                        // EXC_SUM[8:3] accumulate; SWC stays set only while every trap had /S
                        exc_sum_r <= {exc_sum_r[6:1] | w_es[6:1], (exc_sum_r[6:1] == 6'd0 ? 1'b1 : exc_sum_r[0]) & w_es[0]};
                        if (w_dst_v) exc_mask[w_dst] <= 1'b1;
                    end else if (w_exc == E_ARITH) begin
                        exc_sum_r[6] <= 1'b1;                                     // integer /V: IOV
                        if (w_dst_v) exc_mask[w_dst] <= 1'b1;
                    end
                    dbg_retire <= w_cls != C_CPAL;      // CALL_PAL enters PALcode, it does not retire
                    dbg_pc <= w_pc; dbg_insn <= w_ir;
                    dbg_rwr <= rf_we && !w_cmf && !w_dst[5]; dbg_rnum <= w_dst[4:0]; dbg_rval <= w_res;
                    dbg_mwr <= w_st; dbg_maddr <= w_va; dbg_mval <= w_sdata; dbg_msize <= w_ssize;
                    // IPR writes
                    if (w_cls == C_MTPR) begin
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
                            5'd6: begin dtb_v <= 32'd0; dtb_p <= 5'd0; end             // DTBZAP (and its pointer)
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
                            5'd9: begin ps_cm <= w_res[4:3]; dbg_psw <= 1'b1; dbg_psv <= w_res[7:0]; end
                            5'd11: pal_base <= w_res[33:14];
                            5'd22: sl_xmit <= w_res[4];               // SL_XMIT
                            5'd13: sirr <= w_res[47:33];                               // SIRR
                            5'd10: exc_sum_r <= 7'd0;                                 // EXC_SUM: a write clears [8:2], not the mask
                            5'd14: astrr <= w_res[51:48];                              // ASTRR {U, S, E, K}
                            5'd16: begin hier <= w_res[14:9]; hier_pc0 <= w_res[8]; hier_pc1 <= w_res[15];
                                         hier_cre <= w_res[2]; hier_sle <= w_res[32]; end   // HIER
                            5'd17: sier <= w_res[47:33];                               // SIER
                            5'd18: aster <= w_res[51:48];                              // ASTER {U, S, E, K}
                            5'd0: tb_tag <= w_res[42:13];                              // TB_TAG
                            5'd1: begin                                                 // ITB_PTE
                                if (tb_gh == 2'd3) begin
                                    itb_v[8 + itb_lp] <= 1'b1; itb_tag[8 + itb_lp] <= tb_tag;
                                    // a large entry holds PFN[33:22] only (SRM's PALcode tells the
                                    // 21064 apart by reading the low PFN bits back as 0)
                                    itb_pfn[8 + itb_lp] <= {w_res[52:41], 9'd0}; itb_re[8 + itb_lp] <= w_res[11:8];
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
                    if (w_cls == C_MFPR && !w_ir[7] && !w_ir[6] && w_ir[5] && w_ir[4:0] == 5'd10) begin
                        // MSK: the mask is a shift register, each read returns bit 63 (F31 first, then F30 ...
                        // F0, R31 ... R0) and shifts it out. NT's PALcode reads EXC_SUM once at the ARITH
                        // entry, writes it, then reads 31 more bits as F30..F0: a pointer reset by the write
                        // gave it F31..F1, so its software completion looked for the wrong register (TSE's
                        // win32k: a CMPTLT/SU writing F1 became a bogus inexact trap, STOP 0x3B)
                        exc_mask <= {exc_mask[62:0], 1'b0};
                    end
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
                    if (w_ir[31:26] == 6'h17 && w_ir[15:5] == 11'h024) begin            // MT_FPCR
                        fpcr_f <= {w_res[57], w_res[56], w_res[55], w_res[54], w_res[53], w_res[52]};
                        fpcr_dyn <= w_res[59:58];
                    end
                end
                if (w_exc == E_UNAL || w_exc == E_DTBM || w_exc == E_DFAULT) begin
                    if (!mm_lock) begin
                        va_ipr <= w_va;
                        mm_csr <= {w_ir[31:26], w_ir[25:21], w_exc == E_DFAULT ? w_fb : 3'b000, w_cls == C_ST};   // opcode, Ra, FOW FOR ACV, WR
                        mm_lock <= 1'b1;
                        dbg_dtb_pr <= w_dpr;
                    end
                end
                dbg_ent <= w_ent; dbg_ent_off <= w_off; dbg_ent_ir <= w_ir;
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
            if (dsettle != 2'd0) dsettle <= dsettle - 2'd1;     // (a fill's last beat below sets it again)
            if (bown == B_NONE) begin
                // D-side (M2) first, after the write buffer; then I-fill; then the buffer
                if (m2_need_bus && mstate == MS_IDLE && !wb_any) begin
                    bown <= B_DFILL; bbeat <= 2'd0; bunc <= !m2_cachable;
                    mem_req <= 1'b1; mem_we <= 1'b0; mem_istream <= 1'b0; mem_be <= 8'hFF; mem_line <= m2_cachable;
                    mem_addr <= m2_cachable ? {m2_pa[33:5], 2'd0} : m2_pa[33:3];
                    mstate <= MS_WAIT;
                    if (m2_cachable) begin dct_we <= 1'b1; dct_wa <= m2_pa[12:5]; dct_v <= 1'b0; dct_wd <= 21'd0; tagw = 1'b1; end
                end else if (wb_any && (m2_need_bus || m2_need_wb || fstate != FS_FILL || ifill_issued || wb_ihit)) begin
                    bown <= B_WB;
                    mem_req <= 1'b1; mem_we <= 1'b1; mem_istream <= 1'b0; mem_line <= !wb_io[wb_rp];
                    mem_addr <= {wb_la[wb_rp], wb_io[wb_rp] ? wb_q[wb_rp] : 2'd0};
                    mem_be <= wb_m[wb_rp][7:0]; mem_wdata <= wb_ld[wb_rp][63:0];
                end else if (fstate == FS_FILL && !ifill_issued) begin
                    bown <= B_IFILL; bbeat <= 2'd0; ifill_issued <= 1'b1;
                    ict_we <= 1'b1; ict_wa <= ifill_line[12:5]; ict_v <= 1'b0; ict_wd <= 21'd0;
                    mem_req <= 1'b1; mem_we <= 1'b0; mem_istream <= 1'b1; mem_be <= 8'hFF; mem_line <= 1'b1;
                    mem_addr <= {ifill_line, 2'd0};
                end
            end else if (mem_ack) begin
                case (bown)
                B_WB: begin mem_req <= 1'b0; bown <= B_NONE; wb_ev[wb_rp] <= 1'b0; wb_rp <= wb_rp + 2'd1; end
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
                        if (!bunc) begin dct_we <= 1'b1; dct_wa <= m2_pa[12:5]; dct_wd <= m2_pa[33:13]; dct_v <= 1'b1; tagw = 1'b1; dsettle <= 2'd3;
                                           sh0_v <= 1'b0; sh1_v <= 1'b0; sh2_v <= 1'b0; end
                    end else begin
                        bbeat <= bbeat + 2'd1; mem_addr <= {m2_pa[33:5], bbeat + 2'd1};
                    end
                end
                endcase
            end
            // a filled load completes from m2_ldata (mstate MS_DONE) even if the
            // RAM outputs it holds are stale: force the miss path's data
            if (mstate == MS_DONE && !stall_m2) mstate <= MS_IDLE;

            // DMA invalidates (dInvReq): one may wait while the tag port is busy
            // (a newer one replaces it only once the older is done: the 21071
            // model sends at most one per DMA quadword, many cycles apart)
            if (dinv) begin dinv_p <= 1'b1; dinv_pi <= dinv_idx; end
            if (dinv && lock_addr[12:5] == dinv_idx) lock_flag <= 1'b0;   // a DMA write to the locked block (by index: may clear more often)
            if ((dinv_p || dinv) && !tagw) begin
                dct_we <= 1'b1; dct_wa <= dinv_p ? dinv_pi : dinv_idx; dct_v <= 1'b0; dct_wd <= 21'd0;
                if (!(dinv && dinv_p)) dinv_p <= 1'b0;
            end
        end
    end
endmodule
