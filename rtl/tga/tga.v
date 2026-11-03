// The ZLXp-E1 graphics card: a DECchip 21030 (TGA), 8 planes, 2 MB of VRAM
// (in DDR3, through rtl/mister/ddr3_arb.v), a Bt485 RAMDAC
// (rtl/tga/tga_bt485.v) and the display path (rtl/tga/tga_video.v), as a
// device on the core's internal PCI bus (docs/design/pci.md 2, 3).
// docs/design/tga.md is the specification: what DEC's SRM console, Linux
// tgafb and NetBSD tga use and how each part is modelled.
//
// PCI: vendor 1011, device 0004, revision REV, class 038000; BAR0 = 128 MB of
// prefetchable 32-bit memory. Within the BAR (aliased every 4 MB):
//   00.0000  ROM space: offset 0 reads ROM_WORD (bits 13:12 module 0 = 8
//            planes, bits 11:8 the monitor switch = SRM's mode table index)
//   10.0000  21030 registers, aliased every 1 KB
//   20.0000  frame buffer: 2 MB, one byte a pixel; what a write does depends
//            on the mode register (simple, stipple, fill, copy, DMA)
//
// Requests: configuration, register reads and the command status register
// are answered at once; writes are posted into an 8-entry command queue the
// drawing engine works through; other reads wait for the queue and the
// engine to finish. The engine's DMA (the 21030's DMA read/write copy modes,
// SRM's scroll) is a PCI master on dm_*; the command status register (1F8 /
// 1FC) is never held, so the CPU can poll it while the engine owns the bus.
module tga #(
    parameter [4:0]  DEVNUM   = 5'd12,          // PCI slot 1 (IDSEL AD23)
    parameter [7:0]  REV      = 8'h03,          // 21030 pass 2+ (SRM: >= 3 sizes BAR0 itself)
    parameter [31:0] ROM_WORD = 32'h0000_0800   // 8-plane, switch 8: 1024x768 @ 60 Hz
) (
    input  wire        clk,
    input  wire        rst,

    // PCI target
    input  wire        pt_req,
    input  wire  [1:0] pt_cmd,
    input  wire  [4:0] pt_dev,
    input  wire [31:0] pt_addr,
    input  wire  [3:0] pt_be,
    input  wire        pt_we,
    input  wire [31:0] pt_wdata,
    output wire        pt_claim,
    output reg         pt_ack,
    output wire [31:0] pt_rdata,

    // PCI master (DMA)
    output reg         dm_req,
    output reg         dm_we,
    output reg  [31:0] dm_addr,
    output wire  [3:0] dm_be,
    output reg  [31:0] dm_wdata,
    input  wire        dm_ack,
    input  wire [31:0] dm_rdata,

    output wire        inta_n,

    // VRAM (ddr3_arb vr_*)
    output reg         vr_req,
    output reg         vr_we,
    output reg  [17:0] vr_addr,
    output reg   [4:0] vr_len,
    output reg   [7:0] vr_be,
    output reg  [63:0] vr_wdata,
    input  wire        vr_ack,
    input  wire        vr_rvalid,
    input  wire [63:0] vr_rdata,

    // display fetch (ddr3_arb sc_*)
    output wire        sc_req,
    output wire [17:0] sc_addr,
    output wire  [5:0] sc_len,
    input  wire        sc_ack,
    input  wire        sc_rvalid,
    input  wire [63:0] sc_rdata,

    // video (clk_pix)
    input  wire        clk_pix,
    output wire        ce_pix,
    output wire        hs,
    output wire        vs,
    output wire        de,
    output wire        hblank,
    output wire        vblank,
    output wire  [7:0] r,
    output wire  [7:0] g,
    output wire  [7:0] b,
    output wire        video_on,        // (clk) the TGA drives a picture: VVVR<0> and a mode set

    // debug (clk): each register write and frame buffer write as it is executed, and the
    // drawing state (the OSD's TGA trace and video overlay; rtl/mister/dbg_trace.v, dbg_overlay.v)
    output reg         dbg_rw,          // a register write: dbg_ri (longword index), dbg_rd
    output reg   [7:0] dbg_ri,
    output reg  [31:0] dbg_rd,
    output reg         dbg_fw,          // a frame buffer write in mode dbg_mode
    output wire  [7:0] dbg_mode,
    output wire [319:0] dbg_st          // {24 zero, mode 16, rop 12, pshift 4, deep 32, pm 32, pxm_p 32, pxm_os 32,
                                        //  fg 32, bg 32, vvbr 16, cr0 8, cr2 8, cr3 8, pixmask 8, cur_x 12, cur_y 12}
);
    assign dm_be = 4'hF;

    // ============================================================ PCI configuration
    reg  [15:0] pci_cmd;
    reg   [7:0] pci_cls, pci_lat, pci_intl;
    reg  [31:27] bar;
    reg  [31:0] cfg40, cfg44;
    wire        mem_on = pci_cmd[1];

    wire cfg_hit = pt_cmd == 2'd0 && pt_dev == DEVNUM && pt_addr[10:8] == 3'd0;
    wire mem_hit = pt_cmd == 2'd2 && mem_on && pt_addr[31:27] == bar;
    assign pt_claim = pt_req && (cfg_hit || mem_hit);

    // ============================================================ request handling
    reg         h_pend, h_cfg, h_we;
    reg  [21:0] h_off;
    reg   [3:0] h_be;
    reg  [31:0] h_wd;
    reg  [31:0] r_q;
    wire acc = pt_req && pt_claim && !h_pend && !pt_ack;
    assign pt_rdata = pt_ack ? r_q : 32'd0;     // zero but with pt_ack: devices OR together

    wire  [1:0] h_rgn = h_off[21:20];           // 0 ROM, 1 registers, 2-3 frame buffer
    wire        h_csr = h_rgn == 2'd1 && h_off[9:3] == 7'h3F;     // 1F8 / 1FC command status

    // command queue: {frame buffer, offset<20:0>, byte enables, data}
    reg  [57:0] cq [0:7];
    reg   [2:0] cq_h, cq_t;
    reg   [3:0] cq_n;
    reg         cq_push, cq_pop;
    wire [57:0] cq_head = cq[cq_h];

    reg         rd_req;                     // a read for the engine
    reg         rd_done;
    reg  [31:0] rd_data;

    localparam [3:0] E_IDLE = 4'd0, E_DEC = 4'd1, E_GEN = 4'd2, E_PRDW = 4'd3, E_PWR = 4'd4,
                     E_SRD = 4'd5, E_SRW = 4'd6, E_DMAW = 4'd7, E_DMAR = 4'd8,
                     E_RD1 = 4'd9, E_RD2 = 4'd10, E_FBRD = 4'd11, E_RD3 = 4'd12;
    reg   [3:0] est;
    wire        busy = est != E_IDLE || cq_n != 4'd0;

    always @(posedge clk) begin
        pt_ack <= 1'b0; cq_push <= 1'b0;
        if (acc) begin
            h_pend <= 1'b1; h_cfg <= cfg_hit; h_we <= pt_we; h_off <= pt_addr[21:0];
            h_be <= pt_be; h_wd <= pt_wdata;
        end
        if (h_pend) begin
            if (h_cfg) begin
                // ---------------------------------------- configuration header
                if (h_we) case (h_off[7:2])
                    6'h01: begin
                        if (h_be[0]) pci_cmd[7:0]  <= h_wd[7:0] & 8'h46;     // memory, master, parity
                        if (h_be[1]) pci_cmd[15:8] <= h_wd[15:8] & 8'h01;    // SERR
                    end
                    6'h03: begin if (h_be[0]) pci_cls <= h_wd[7:0]; if (h_be[1]) pci_lat <= h_wd[15:8]; end
                    6'h04: if (h_be[3]) bar <= h_wd[31:27];
                    6'h0F: if (h_be[0]) pci_intl <= h_wd[7:0];
                    6'h10: cfg40 <= h_wd;
                    6'h11: cfg44 <= h_wd;
                    default: ;
                endcase
                else case (h_off[7:2])
                    6'h00:   r_q <= 32'h0004_1011;
                    6'h01:   r_q <= {16'h0200, pci_cmd};                   // medium DEVSEL
                    6'h02:   r_q <= {24'h03_8000, REV};                    // display controller, other
                    6'h03:   r_q <= {16'h0000, pci_lat, pci_cls};
                    6'h04:   r_q <= {bar, 27'h000_0008};                   // 128 MB, prefetchable
                    6'h0F:   r_q <= {8'h00, 8'h00, 8'h01, pci_intl};       // INTA
                    6'h10:   r_q <= cfg40;
                    6'h11:   r_q <= cfg44;
                    default: r_q <= 32'h0;
                endcase
                pt_ack <= 1'b1; h_pend <= 1'b0;
            end else if (h_csr) begin
                r_q <= {31'd0, busy};
                pt_ack <= 1'b1; h_pend <= 1'b0;
            end else if (h_we) begin
                if (h_rgn == 2'd0) begin pt_ack <= 1'b1; h_pend <= 1'b0; end      // ROM: no flash writes
                else if (cq_n + {3'd0, cq_push} < 4'd8) begin
                    cq_push <= 1'b1;
                    pt_ack <= 1'b1; h_pend <= 1'b0;
                end
            end else begin
                if (rd_done) begin
                    r_q <= rd_data; rd_req <= 1'b0;
                    pt_ack <= 1'b1; h_pend <= 1'b0;
                end else rd_req <= 1'b1;
            end
        end
        if (rst) begin
            h_pend <= 1'b0; pt_ack <= 1'b0; rd_req <= 1'b0; cq_push <= 1'b0;
            pci_cmd <= 16'h0; pci_cls <= 8'h0; pci_lat <= 8'h0; pci_intl <= 8'h0;
            bar <= 5'd0; cfg40 <= 32'd0; cfg44 <= 32'd0;
        end
    end

    always @(posedge clk) begin
        if (cq_push) cq[cq_t] <= {h_rgn[1], h_off[20:0], h_be, h_wd};
        if (rst) begin cq_h <= 3'd0; cq_t <= 3'd0; cq_n <= 4'd0; end
        else begin
            if (cq_push) cq_t <= cq_t + 3'd1;
            if (cq_pop)  cq_h <= cq_h + 3'd1;
            cq_n <= cq_n + {3'd0, cq_push} - {3'd0, cq_pop};
        end
    end

    // ============================================================ the 21030's registers
    reg  [31:0] fg, bg, pm, pxm_p, pxm_os, deep, ccbr, vhcr, vvcr, vvvr, cxyr, datar, gdbr, epsr;
    reg  [31:0] gadr, c64s, c64d;
    reg         os_v;                       // the one-shot pixel mask is armed
    reg  [15:0] mode;
    reg         copy_flag;                  // copy mode: the next write is the destination
    reg  [11:0] rop;
    reg   [3:0] pshift;
    reg   [8:0] vvbr;
    reg   [4:0] sisr_st, sisr_en;
    reg  [31:0] bc0, bc1;
    // everything else reads back what was written (Bresenham, Z, colour
    // increments, stencil, slopes, the other block colours, the copy buffer)
    reg  [31:0] gram [0:255];
    reg  [31:0] gram_q;
    always @(posedge clk) gram_q <= gram[h_off[9:2]];

    wire [31:0] pxm = os_v ? pxm_os : pxm_p;
    wire [20:0] vbase = deep[9] ? {1'b0, vvbr, 11'd0} : {vvbr, 12'd0};     // 2 KB / 4 KB units (NetBSD T8-01 / T8-02)
    assign inta_n = !(|(sisr_st & sisr_en));

    // Bt485
    reg         bt_wr, bt_rd;
    reg   [3:0] bt_rs;
    reg   [7:0] bt_wd;
    wire  [7:0] bt_q;

    // ============================================================ drawing engine
    // A drawing operation is a run of quadword "pixel operations" (g_*): the
    // quadword, its byte enables and source data; with the raster op or a
    // plane mask other than all ones the old quadword is read first.
    localparam [2:0] D_W = 3'd0, D_OPQ = 3'd1, D_FG = 3'd2, D_BC = 3'd3, D_CPY = 3'd4;
    reg  [17:0] g_q;                        // VRAM quadword
    reg   [9:0] g_n;                        // quadwords left
    reg         g_first;
    reg   [7:0] g_bef, g_bel;               // byte enables of the first and last quadword
    reg  [39:0] g_st;                       // stipple bits, next quadword in 7:0
    reg  [39:0] g_pw;                       // pixel mask window, next quadword in 7:0
    reg         g_rot;                      // fill: g_st[31:0] rotates (the data register repeats)
    reg         g_use_pw, g_use_st, g_rop_en, g_ret;
    reg   [2:0] g_dsel;
    reg  [31:0] g_w;                        // simple mode data
    reg  [63:0] s [0:9];                    // source quadwords (copy, COPY64, DMA)
    reg  [63:0] s_prev;
    reg   [2:0] g_fs;                       // copy: byte shift source -> destination
    reg         g_m1;                       // copy: the first destination quadword starts in s_prev
    reg  [63:0] p_d;                        // RMW: the source data
    reg   [7:0] p_be;

    wire [63:0] pm64 = {pm, pm};
    wire        pm_all = &pm;
    wire        rop_dep = (rop[3] != rop[2]) || (rop[1] != rop[0]);

    function [63:0] ropf;
        input [3:0] c; input [63:0] sv; input [63:0] dv;
        ropf = ({64{c[3]}} & ~sv & ~dv) | ({64{c[2]}} & ~sv & dv) |
               ({64{c[1]}} & sv & ~dv) | ({64{c[0]}} & sv & dv);
    endfunction

    // the current pixel operation
    wire  [7:0] rng    = (g_first ? g_bef : 8'hFF) & (g_n == 10'd1 ? g_bel : 8'hFF);
    wire  [7:0] cur_be = rng & (g_use_pw ? g_pw[7:0] : 8'hFF) & (g_use_st ? g_st[7:0] : 8'hFF);
    wire [127:0] fin   = g_m1 ? {s[0], s_prev} : {s[1], s[0]};
    wire [127:0] fsh   = fin >> {g_fs, 3'b000};
    reg  [63:0] cur_d;
    integer bi;
    always @* begin
        case (g_dsel)
        D_W:     cur_d = {g_w, g_w};
        D_FG:    cur_d = {fg, fg};
        D_BC:    cur_d = {bc1, bc0};
        D_CPY:   cur_d = fsh[63:0];
        default: for (bi = 0; bi < 8; bi = bi + 1)
                     cur_d[8*bi +: 8] = g_st[bi] ? fg[8*(bi % 4) +: 8] : bg[8*(bi % 4) +: 8];
        endcase
    end
    wire        cur_rd = (g_rop_en && rop_dep) || !pm_all;
    wire [63:0] cur_wd = g_rop_en ? ropf(rop[3:0], cur_d, 64'd0) : cur_d;

    // the command being worked on
    reg         c_fb;
    reg  [20:0] c_off;
    reg   [3:0] c_be;
    reg  [31:0] c_d;
    wire  [7:0] c_idx = c_off[9:2];
    wire  [7:0] m8 = mode[7:0];
    // transparent is mode bit 2 (21030: 05 transparent stipple, 25 transparent fill, as 0D/2D block;
    // Linux tgafb's values, and what NT's tga.dll draws its text with); 03/23 are kept as the same
    wire        m_fill = m8 == 8'h2D || m8 == 8'h21 || m8 == 8'h23 || m8 == 8'h25;

    // source reads
    reg  [17:0] sr_q;
    reg   [4:0] sr_n, sr_k;
    reg         sr_lo;
    reg   [1:0] sr_next;                    // 0 copy source, 1 COPY64 destination, 2 DMA write out
    reg  [20:0] cp_p0;                      // copy mode: the source's first byte
    // DMA
    reg  [15:0] dw_left;                    // DMA write: quadwords still to send
    reg   [3:0] dw_chunk;
    reg         dw_lane;
    reg  [17:0] dw_q;
    reg  [16:0] dr_k, dr_n;                 // DMA read: longword k of n
    reg  [20:0] dr_a;                       // its frame buffer byte
    reg  [15:0] dr_m;                       // the edge masks

    // start a fill: P0 = first byte, n = pixels
    task fill_start;
        input [20:0] p0; input [11:0] n;
        reg [11:0] e; begin
            e = {9'd0, p0[2:0]} + n - 12'd1;
            g_q <= p0[20:3]; g_n <= {1'b0, e[11:3]} + 10'd1; g_first <= 1'b1;
            g_bef <= 8'hFF << p0[2:0]; g_bel <= 8'hFF >> (3'd7 - e[2:0]);
            g_st <= {8'd0, p0[2] ? {datar[27:0], datar[31:28]} : datar}; g_rot <= 1'b1;
            g_use_pw <= 1'b0; g_rop_en <= m8 != 8'h2D; g_ret <= 1'b0;
            g_use_st <= m8 != 8'h21;
            g_dsel <= m8 == 8'h2D ? D_BC : m8 == 8'h21 ? D_OPQ : D_FG;
        end
    endtask

    integer k;
    always @(posedge clk) begin
        cq_pop <= 1'b0; rd_done <= 1'b0; bt_wr <= 1'b0; bt_rd <= 1'b0;
        dbg_rw <= 1'b0; dbg_fw <= 1'b0;
        if (vr_ack) vr_req <= 1'b0;
        if (dm_ack) dm_req <= 1'b0;
        if (vid_eof) sisr_st[0] <= 1'b1;

        case (est)
        E_IDLE: begin
            if (cq_n != 4'd0 && !cq_pop) begin
                {c_fb, c_off, c_be, c_d} <= cq_head;
                cq_pop <= 1'b1; est <= E_DEC;
            end else if (rd_req && !rd_done && cq_n == 4'd0 && !cq_pop) est <= E_RD1;
        end

        // ---------------------------------------------------- a queued write
        E_DEC: begin
            est <= E_IDLE;
            if (!c_fb) begin
                // registers
                dbg_rw <= 1'b1; dbg_ri <= c_idx; dbg_rd <= c_d;
                gram[c_idx] <= c_d;
`ifdef SIM_PCILOG
                // +tgalog: the drawing state the console firmware and NT leave behind
                if ($test$plusargs("tgalog") && (c_idx == 8'h0A || c_idx == 8'h0B || c_idx == 8'h0C ||
                                                 c_idx == 8'h0D || c_idx == 8'h17 || c_idx == 8'h14))
                    $display("TGA reg %03x = %08x", {c_idx, 2'b00}, c_d);
`endif
                case (c_idx)
                8'h08: fg <= c_d;
                8'h09: bg <= c_d;
                8'h0A: pm <= c_d;
                8'h0B: begin pxm_os <= c_d; os_v <= 1'b1; end
                8'h0C: begin mode <= c_d[15:0]; copy_flag <= 1'b0; end
                8'h0D: rop <= c_d[11:0];
                8'h0E: pshift <= c_d[3:0];
                8'h0F: gadr <= c_d;
                8'h14: deep <= c_d;
                8'h15: if (m_fill) begin fill_start(gadr[20:0], {1'b0, c_d[10:0]} + 12'd1); est <= E_GEN; end
                8'h17: begin pxm_p <= c_d; os_v <= 1'b0; end
                8'h18: ccbr <= c_d;
                8'h19: vhcr <= c_d;
                8'h1A: vvcr <= c_d;
                8'h1B: vvbr <= c_d[8:0];
                8'h1C: vvvr <= c_d;
                8'h1D: cxyr <= c_d;
                8'h1F: begin sisr_st <= sisr_st & ~c_d[4:0]; sisr_en <= c_d[20:16]; end
                8'h20: datar <= c_d;
                8'h26: gdbr <= c_d;
                8'h30: epsr <= c_d;
                8'h50: bc0 <= c_d;
                8'h51: bc1 <= c_d;
                8'h58, 8'h5A: begin c64s <= c_d; copy_flag <= 1'b0; end
                8'h59, 8'h5B: begin
                    // COPY64: 64 bytes from c64s to c_d (frame buffer offsets)
                    c64d <= c_d; copy_flag <= 1'b1;
                    sr_q <= c64s[20:3]; sr_lo <= 1'b0; sr_k <= 5'd0; sr_next <= 2'd1;
                    sr_n <= c64s[2:0] == 3'd0 ? 5'd8 : 5'd9;
                    est <= E_SRD;
                end
                8'h7C: if (!c_d[8]) begin bt_wr <= 1'b1; bt_rs <= c_d[12:9]; bt_wd <= c_d[7:0]; end
                default: ;
                endcase
            end else begin
                // the frame buffer: by mode
                dbg_fw <= 1'b1;
                os_v <= 1'b0;
                g_first <= 1'b1; g_rot <= 1'b0; g_ret <= 1'b0; g_m1 <= 1'b0; g_fs <= 3'd0;
                case (m8)
                8'h01, 8'h03, 8'h05, 8'h0D: begin
                    // stipple: 32 pixels from the longword, bit i = pixel i
                    g_q <= c_off[20:3]; g_n <= c_off[2] ? 10'd5 : 10'd4;
                    g_bef <= 8'hFF; g_bel <= 8'hFF;
                    g_st <= {8'd0, c_d} << {c_off[2], 2'b00};
                    g_pw <= {8'd0, pxm} << {c_off[2], 2'b00};
                    g_use_pw <= 1'b1; g_use_st <= m8 != 8'h01; g_rop_en <= m8 != 8'h0D;
                    g_dsel <= m8 == 8'h01 ? D_OPQ : m8 == 8'h0D ? D_BC : D_FG;
                    est <= E_GEN;
                end
                8'h2D, 8'h21, 8'h23, 8'h25: begin
                    // fill: data<10:0> + 1 pixels from the longword (+ data<17:16>)
                    fill_start({c_off[20:2], 2'b00} + {19'd0, c_d[17:16]}, {1'b0, c_d[10:0]} + 12'd1);
                    est <= E_GEN;
                end
                8'h07: if (!copy_flag) begin
                    // copy, source: 32 bytes from the longword
                    copy_flag <= 1'b1; cp_p0 <= {c_off[20:2], 2'b00};
                    sr_q <= c_off[20:3]; sr_n <= 5'd5; sr_k <= 5'd0; sr_lo <= 1'b0; sr_next <= 2'd0;
                    est <= E_SRD;
                end else begin
                    // copy, destination: the 32 pixels the data selects (and the pixel mask)
                    copy_flag <= 1'b0;
                    g_q <= c_off[20:3]; g_n <= c_off[2] ? 10'd5 : 10'd4;
                    g_bef <= 8'hFF; g_bel <= 8'hFF;
                    g_st <= {8'd0, c_d} << {c_off[2], 2'b00};
                    g_pw <= {8'd0, pxm} << {c_off[2], 2'b00};
                    g_use_pw <= 1'b1; g_use_st <= 1'b1; g_rop_en <= 1'b1; g_dsel <= D_CPY;
                    g_fs <= {cp_p0[2] ^ c_off[2], 2'b00};
                    g_m1 <= !cp_p0[2] && c_off[2];
                    s_prev <= 64'd0;
                    est <= E_GEN;
                end
                8'h1F: begin
                    // DMA write copy: data<31:16> + 1 quadwords from the frame
                    // buffer, the first only primes the shifter; the rest go to
                    // host memory at the DMA base, a longword at a time
                    dw_left <= c_d[31:16]; dw_q <= c_off[20:3] + 18'd1; dm_addr <= gdbr;
                    est <= c_d[31:16] == 16'd0 ? E_IDLE : E_DMAW;
                    dw_chunk <= 4'd0;
                end
                8'h17, 8'h37: begin
                    // DMA read copy: data<31:16> + 1 longwords from host memory into
                    // the frame buffer, edge masks in data<15:0>
                    dr_k <= 17'd0; dr_n <= {1'b0, c_d[31:16]} + 17'd1; dr_m <= c_d[15:0];
                    dr_a <= {c_off[20:2], 2'b00}; dm_addr <= gdbr;
                    est <= E_DMAR;
                end
                default: begin
                    // simple: the longword, its byte enables, the pixel mask
                    g_q <= c_off[20:3]; g_n <= 10'd1;
                    g_bef <= c_off[2] ? {c_be, 4'd0} : {4'd0, c_be}; g_bel <= 8'hFF;
                    g_pw <= {32'd0, pxm[{c_off[4:3], 3'b000} +: 8]};
                    g_w <= c_d; g_use_pw <= 1'b1; g_use_st <= 1'b0; g_rop_en <= 1'b1; g_dsel <= D_W;
                    est <= E_GEN;
                end
                endcase
            end
        end

        // ---------------------------------------------------- pixel operations
        E_GEN, E_PWR: if (est == E_GEN || vr_ack) begin
            if (g_n == 10'd0) begin
                vr_req <= 1'b0;
                est <= g_ret ? E_DMAR : E_IDLE;
            end else begin
                // step to the next quadword
                g_q <= g_q + 18'd1; g_n <= g_n - 10'd1; g_first <= 1'b0;
                g_st <= g_rot ? {8'd0, g_st[7:0], g_st[31:8]} : g_st >> 8;
                g_pw <= g_pw >> 8;
                s_prev <= s[0];
                for (k = 0; k < 9; k = k + 1) s[k] <= s[k + 1];
                s[9] <= 64'd0;
                if (cur_be == 8'd0) begin
                    vr_req <= 1'b0; est <= E_GEN;
                end else if (cur_rd) begin
                    vr_req <= 1'b1; vr_we <= 1'b0; vr_addr <= g_q; vr_len <= 5'd1;
                    p_d <= cur_d; p_be <= cur_be; est <= E_PRDW;
                end else begin
                    vr_req <= 1'b1; vr_we <= 1'b1; vr_addr <= g_q; vr_be <= cur_be; vr_wdata <= cur_wd;
                    est <= E_PWR;
                end
            end
        end
        E_PRDW: if (vr_rvalid) begin
            vr_req <= 1'b1; vr_we <= 1'b1; vr_be <= p_be;
            vr_wdata <= ((g_rop_en ? ropf(rop[3:0], p_d, vr_rdata) : p_d) & pm64) | (vr_rdata & ~pm64);
            est <= E_PWR;
        end

        // ---------------------------------------------------- source reads into s[]
        E_SRD: begin
            if (!vr_req) begin
                vr_req <= 1'b1; vr_we <= 1'b0; vr_addr <= sr_q; vr_len <= sr_n;
            end
            if (vr_ack) begin vr_req <= 1'b0; est <= E_SRW; end
        end
        E_SRW: if (vr_rvalid) begin
            s[sr_k[3:0] + {3'd0, sr_lo}] <= vr_rdata;
            sr_k <= sr_k + 5'd1;
            if (sr_k + 5'd1 == sr_n) begin
                case (sr_next)
                2'd1: begin
                    // COPY64 destination: 64 bytes
                    g_q <= c64d[20:3]; g_n <= c64d[2:0] == 3'd0 ? 10'd8 : 10'd9; g_first <= 1'b1;
                    g_bef <= 8'hFF << c64d[2:0]; g_bel <= 8'hFF >> (3'd7 - (c64d[2:0] + 3'd7));
                    g_use_pw <= 1'b0; g_use_st <= 1'b0; g_rop_en <= 1'b1; g_dsel <= D_CPY; g_ret <= 1'b0;
                    g_fs <= c64s[2:0] - c64d[2:0]; g_m1 <= c64s[2:0] < c64d[2:0]; s_prev <= 64'd0;
                    est <= E_GEN;
                end
                2'd2: est <= E_DMAW;
                default: est <= E_IDLE;
                endcase
            end
        end

        // ---------------------------------------------------- DMA write: frame buffer -> host
        E_DMAW: begin
            if (dw_chunk == 4'd0) begin
                if (dw_left == 16'd0) est <= E_IDLE;
                else begin
                    // the next up to 8 quadwords
                    sr_q <= dw_q; sr_k <= 5'd0; sr_lo <= 1'b0; sr_next <= 2'd2;
                    sr_n <= dw_left > 16'd8 ? 5'd8 : {1'b0, dw_left[3:0]};
                    dw_chunk <= dw_left > 16'd8 ? 4'd8 : dw_left[3:0];
                    dw_q <= dw_q + (dw_left > 16'd8 ? 18'd8 : {14'd0, dw_left[3:0]});
                    dw_left <= dw_left - (dw_left > 16'd8 ? 16'd8 : {12'd0, dw_left[3:0]});
                    dw_lane <= 1'b0;
                    est <= E_SRD;
                end
            end else if (!dm_req && !dm_ack) begin
                dm_req <= 1'b1; dm_we <= 1'b1; dm_wdata <= dw_lane ? s[0][63:32] : s[0][31:0];
            end else if (dm_ack) begin
                dm_addr <= dm_addr + 32'd4; dw_lane <= !dw_lane;
                if (dw_lane) begin
                    for (k = 0; k < 9; k = k + 1) s[k] <= s[k + 1];
                    dw_chunk <= dw_chunk - 4'd1;
                end
            end
        end

        // ---------------------------------------------------- DMA read: host -> frame buffer
        E_DMAR: begin
            if (dr_k == dr_n) est <= E_IDLE;
            else if (!dm_req && !dm_ack) begin
                dm_req <= 1'b1; dm_we <= 1'b0;
            end else if (dm_ack) begin
                // one longword, through the pixel operation with its edge mask
                g_q <= dr_a[20:3]; g_n <= 10'd1; g_first <= 1'b1; g_bel <= 8'hFF;
                g_bef <= dr_a[2] ? {dr_mask, 4'd0} : {4'd0, dr_mask};
                g_w <= dm_rdata; g_use_pw <= 1'b0; g_use_st <= 1'b0; g_rop_en <= 1'b1;
                g_dsel <= D_W; g_ret <= 1'b1;
                dm_addr <= dm_addr + 32'd4; dr_a <= dr_a + 21'd4; dr_k <= dr_k + 17'd1;
                est <= E_GEN;
            end
        end

        // ---------------------------------------------------- reads
        E_RD1: begin
            case (h_rgn)
            2'd0: begin rd_data <= h_off[19:0] == 20'd0 ? ROM_WORD : 32'd0; rd_done <= 1'b1; est <= E_IDLE; end
            2'd1: if (h_off[9:2] == 8'h7C) begin
                    bt_rd <= 1'b1; bt_rs <= epsr[4:1]; est <= E_RD2;
                end else begin
                    rd_data <= reg_rd; rd_done <= 1'b1; est <= E_IDLE;
                end
            default: begin
                if (!vr_req) begin vr_req <= 1'b1; vr_we <= 1'b0; vr_addr <= h_off[20:3]; vr_len <= 5'd1; end
                if (vr_ack) begin vr_req <= 1'b0; est <= E_FBRD; end
            end
            endcase
        end
        E_RD2: est <= E_RD3;                // the Bt485 registers its byte on the strobe
        E_RD3: begin rd_data <= {8'd0, bt_q, 16'd0}; rd_done <= 1'b1; est <= E_IDLE; end
        E_FBRD: if (vr_rvalid) begin
            rd_data <= h_off[2] ? vr_rdata[63:32] : vr_rdata[31:0]; rd_done <= 1'b1; est <= E_IDLE;
        end
        default: est <= E_IDLE;
        endcase

        if (rst) begin
            est <= E_IDLE; vr_req <= 1'b0; dm_req <= 1'b0; cq_pop <= 1'b0;
            fg <= 32'd0; bg <= 32'd0; pm <= 32'hFFFFFFFF; pxm_p <= 32'hFFFFFFFF; pxm_os <= 32'hFFFFFFFF;
            os_v <= 1'b0; mode <= 16'd0; copy_flag <= 1'b0; rop <= 12'h003; pshift <= 4'd0;
            deep <= 32'd0; ccbr <= 32'd0; vhcr <= 32'd0; vvcr <= 32'd0; vvbr <= 9'd0; vvvr <= 32'd0;
            cxyr <= 32'd0; sisr_st <= 5'd0; sisr_en <= 5'd0; datar <= 32'hFFFFFFFF; gdbr <= 32'd0;
            epsr <= 32'd0; gadr <= 32'd0; c64s <= 32'd0; c64d <= 32'd0; bc0 <= 32'd0; bc1 <= 32'd0;
        end
    end

    // DMA read edge masks (21030: left1, left2 for the first two longwords,
    // right1 for the last; right2, the shifter residue, is not modelled)
    wire [3:0] dr_mask = dr_k + 17'd1 == dr_n ? dr_m[11:8] :
                         dr_k == 17'd0 ? dr_m[3:0] :
                         (dr_k == 17'd1 && dr_n >= 17'd3) ? dr_m[7:4] : 4'hF;

    // register reads
    reg [31:0] reg_rd;
    always @* begin
        case (h_off[9:2])
        8'h08: reg_rd = fg;
        8'h09: reg_rd = bg;
        8'h0A: reg_rd = pm;
        8'h0B: reg_rd = pxm;
        8'h0C: reg_rd = {11'd0, copy_flag, 4'd0, mode};
        8'h0D: reg_rd = {20'd0, rop};
        8'h0E: reg_rd = {28'd0, pshift};
        8'h0F: reg_rd = gadr;
        8'h14: reg_rd = deep;
        8'h15: reg_rd = {24'd0, REV};
        8'h17: reg_rd = pxm_p;
        8'h18: reg_rd = ccbr & 32'hFFFF_FFF0;
        8'h19: reg_rd = vhcr;
        8'h1A: reg_rd = vvcr;
        8'h1B: reg_rd = {23'd0, vvbr};
        8'h1C: reg_rd = vvvr;
        8'h1D: reg_rd = cxyr;
        8'h1E: reg_rd = 32'd0;
        8'h1F: reg_rd = {11'd0, sisr_en, 11'd0, sisr_st};
        8'h20: reg_rd = datar;
        8'h26: reg_rd = gdbr;
        8'h30: reg_rd = epsr;
        8'h50: reg_rd = bc0;
        8'h51: reg_rd = bc1;
        8'h58, 8'h5A: reg_rd = c64s;
        8'h59, 8'h5B: reg_rd = c64d;
        default: reg_rd = gram_q;
        endcase
    end

    // ============================================================ RAMDAC and display
    wire  [7:0] pal_a;
    wire [23:0] pal_q;
    wire  [8:0] cur_a;
    wire  [7:0] cur_q0, cur_q1, cr0, cr2, cr3, pixmask;
    wire [95:0] curcol;
    wire [11:0] cur_x, cur_y;
    assign dbg_mode = m8;
    assign dbg_st = {24'd0, mode, rop, pshift, deep, pm, pxm_p, pxm_os, fg, bg, 7'd0, vvbr,
                     cr0, cr2, cr3, pixmask, cur_x, cur_y};
    wire        pix_en, vid_eof;

    tga_bt485 ramdac (
        .clk(clk), .rst(rst), .wr(bt_wr), .rd(bt_rd), .rs(bt_rs), .wdata(bt_wd), .rdata(bt_q),
        .clk_pix(clk_pix), .pix_en(pix_en), .pal_a(pal_a), .pal_q(pal_q),
        .cur_a(cur_a), .cur_q0(cur_q0), .cur_q1(cur_q1),
        .cr0(cr0), .cr2(cr2), .cr3(cr3), .pixmask(pixmask), .curcol(curcol), .cur_x(cur_x), .cur_y(cur_y)
    );

    tga_video video (
        .clk(clk), .rst(rst), .vhcr(vhcr), .vvcr(vvcr), .base(vbase), .vvalid(vvvr[0]), .vblnk(vvvr[1]),
        .eof(vid_eof),
        .sc_req(sc_req), .sc_addr(sc_addr), .sc_len(sc_len), .sc_ack(sc_ack), .sc_rvalid(sc_rvalid),
        .sc_rdata(sc_rdata),
        .clk_pix(clk_pix), .pix_en(pix_en), .pal_a(pal_a), .pal_q(pal_q), .cur_a(cur_a),
        .cur_q0(cur_q0), .cur_q1(cur_q1), .cr0(cr0), .cr2(cr2), .cr3(cr3), .pixmask(pixmask), .curcol(curcol),
        .cur_x(cur_x), .cur_y(cur_y),
        .ce_pix(ce_pix), .hs(hs), .vs(vs), .de(de), .hblank(hblank), .vblank(vblank), .r(r), .g(g), .b(b)
    );

    assign video_on = vvvr[0] && vhcr[8:0] != 9'd0 && vvcr[10:0] != 11'd0;
endmodule
