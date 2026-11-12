// DECchip 21071-AA ("APECS") core logic, first cut: what the SROM and the
// DROM need (docs/design/srom.md 4, docs/HARDWARE.md 4).
//
// CPU side: the ev4_core bus (one quadword-aligned access at a time, held
// until c_ack). Address map (34-bit PA):
//
//   0.0000.0000 - 0.FFFF.FFFF  memory: banks 0-2 per their BASE/CNFG CSRs
//                              (21071 Table 4-7) onto the DRAM port. What is
//                              installed (cfg_mem) sits behind the banks: a
//                              bank larger than what is installed aliases
//                              modulo it, an empty valid bank reads all ones
//                              and drops writes (the SROM sizes memory that
//                              way); no matching bank reads all ones
//   1.0000.0000                flashbus index register (TI Table 4-1)
//   1.0010.0000                flashbus data register (TI Table 4-2)
//   1.8000.0000 - 1.8000.0FFF  21071-CA CSRs (one longword every 0x20)
//   1.A000.0000 - 1.A000.0FFF  21071-DA CSRs
//   1.B000.0000 - 1.BFFF.FFFF  PCI interrupt acknowledge (read: the vector)
//   1.C000.0000 - 1.DFFF.FFFF  PCI sparse I/O     } on the internal PCI
//   1.E000.0000 - 1.FFFF.FFFF  PCI configuration } target bus
//   2.0000.0000 - 2.FFFF.FFFF  PCI sparse memory } (docs/design/pci.md):
//   3.0000.0000 - 3.FFFF.FFFF  PCI dense memory  } no claim = master abort
//                              (all ones), except I/O, which goes to the
//                              SIO's ISA side (pt_sub, subtractive decode)
//   everything else            reads all ones, writes dropped
//
// DMA (pci.md 3): PCI masters' accesses go through windows 1 and 2
// (PBR/PMR/TBR, direct-mapped; scatter/gather is a STUB) onto the DRAM, and
// have priority over the CPU between transactions.
//
// Flashbus devices (TI Table 4-3): flash 00.0000-0F.FFFF and the DROM
// 18.0000-18.FFFF on the f_* byte port (stored outside: DDR3 on the board,
// a C++ model in Verilator); NVRAM 10.0000 (8 KB, here, wraps); LEDs
// 14.0000 (write); jumpers 1C.0000 (read).
//
// Installed memory (CORE_SPEC bank table): cfg_mem 1 = 32 MB (bank slot 0
// = 32 MB at DRAM 0), 0 = 64 MB (slots 0 and 1, 32 MB at DRAM 0 and 32 MB),
// 2 = 128 MB (slot 0 = 128 MB).
module apecs (
    input  wire        clk,
    input  wire        rst,
    input  wire  [1:0] cfg_mem,         // 0 = 64 MB, 1 = 32 MB, 2 = 128 MB
    input  wire  [7:0] jumpers,         // flashbus 1C.0000 (bit 0 = J1, bit 1 = J2; 1 = normal)
    output reg   [7:0] leds,

    // the flashbus NVRAM's second port (rtl/mister/nvsave.v: load and save
    // the 8 KB through the SD card); nv_dirty pulses on every CPU write
    input  wire [12:0] nvb_addr,
    input  wire        nvb_we,
    input  wire  [7:0] nvb_wdata,
    output reg   [7:0] nvb_rdata,
    output reg         nv_dirty,

    // CPU
    input  wire        c_req,
    input  wire        c_we,
    input  wire        c_line,          // a 32-byte line read: 4 quadwords, one c_ack each
    input  wire [33:3] c_addr,
    input  wire  [7:0] c_be,
    input  wire [63:0] c_wdata,
    input  wire [31:0] c_wmask,         // a memory write with c_line: the line at c_addr[33:5] with 32 byte
    input  wire [255:0] c_wline,        // enables (the CPU's write buffer), not c_be / c_wdata
    output reg         c_ack,
    output reg  [63:0] c_rdata,

    // DRAM (128 MB)
    output reg         d_req,
    output reg         d_we,
    output reg         d_line,          // a 32-byte line read: 4 quadwords, one d_ack each
    output reg  [26:3] d_addr,
    output reg  [31:0] d_be,            // a write is a line (d_addr[26:5]) with 32 byte enables
    output reg  [255:0] d_wdata,
    input  wire        d_ack,
    input  wire [63:0] d_rdata,

    // flash + DROM bytes (flashbus offset)
    output reg         f_req,
    output reg         f_we,
    output reg  [20:0] f_addr,
    output reg   [7:0] f_wdata,
    input  wire        f_ack,
    input  wire  [7:0] f_rdata,

    // PCI target bus (pci.md 2): claim/ack/rdata are the OR of the devices'
    output reg         pt_req,
    output reg   [1:0] pt_cmd,          // 0 config, 1 I/O, 2 memory, 3 IACK
    output reg   [4:0] pt_dev,
    output reg  [31:0] pt_addr,
    output reg   [3:0] pt_be,
    output reg         pt_we,
    output reg  [31:0] pt_wdata,
    input  wire        pt_claim,
    input  wire        pt_ack,
    input  wire [31:0] pt_rdata,

    // DMA (pci.md 3), from the PCI masters' arbiter
    input  wire        dm_req,
    input  wire        dm_we,
    input  wire [31:0] dm_addr,
    input  wire  [3:0] dm_be,
    input  wire [31:0] dm_wdata,
    output reg         dm_ack,
    output reg  [31:0] dm_rdata,

    // DMA writes into memory: invalidate the CPU's D-cache line (dInvReq)
    output reg         dinv,
    output reg   [7:0] dinv_idx
);
    wire [33:0] pa = {c_addr, 3'b000} | (c_be[3:0] == 4'd0 ? 34'd4 : 34'd0);   // the longword addressed

    // ------------------------------------------------------------ CSRs
    // 128 longwords each, index = PA<11:5>; the bank registers are also
    // kept in flops for the memory decode
    // CSRs and NVRAM live in block RAM (registered read): an access writes
    // in S_IDLE and returns the read two cycles later (S_LR1, S_LR2)
    reg [31:0] ca [0:127];
    reg [31:0] da [0:127];
    reg  [6:0] ca_a, da_a;
    reg [31:0] ca_q, da_q;
    reg        ca_we, da_we;
    reg [31:0] ca_wd, da_wd;
    reg [12:0] nv_a;
    reg  [7:0] nv_wd;
    reg        nv_we;
    reg  [1:0] lsel;                    // which RAM the read comes from: 0 CA, 1 DA, 2 NVRAM
    reg [15:0] bbase [0:2];             // BaseAdr<33:23> in [15:5]
    reg  [8:0] bcnfg [0:2];
    reg [31:0] fb_index;

    // ------------------------------------------------------------ memory decode
    // per bank: valid, matches, offset within the bank
    reg        hit  [0:2];
    reg [33:0] boff [0:2];
    integer n;
    always @* begin
        for (n = 0; n < 3; n = n + 1) begin : dec
            reg [2:0] sz;              // size code 1..7 = 512 MB .. 8 MB
            reg [33:0] mask;           // bits below the compared field
            sz   = bcnfg[n][3:1];
            mask = (34'd1 << (6'd30 - {3'd0, sz})) - 34'd1;
            hit[n]  = bcnfg[n][0] && bcnfg[n][4:1] != 4'd0 && !bcnfg[n][4] &&
                      ((pa & ~mask) == ({bbase[n][15:5], 23'd0} & ~mask));
            boff[n] = pa & mask;
        end
    end

    // what is installed behind each bank slot: size (bytes, power of two) and DRAM base
    reg [27:0] inst_size [0:2];
    reg [27:0] inst_base [0:2];
    always @* begin
        inst_size[0] = cfg_mem == 2'd2 ? 28'h8000000 : 28'h2000000;
        inst_base[0] = 28'd0;
        inst_size[1] = cfg_mem == 2'd0 ? 28'h2000000 : 28'd0;
        inst_base[1] = 28'h2000000;
        inst_size[2] = 28'd0;
        inst_base[2] = 28'd0;
    end

    // ------------------------------------------------------------ sequencer
    localparam S_IDLE = 4'd0, S_DRAM = 4'd1, S_FB = 4'd2, S_PCI = 4'd3, S_LR1 = 4'd4, S_LR2 = 4'd5,
               S_PCIW = 4'd6, S_DMA = 4'd7, S_PCI2 = 4'd8, S_SGR = 4'd9;
    reg [3:0] st;
    reg       pci_hi;                   // dense quadword: the second longword is pending
    reg [1:0] d_beats;                  // quadwords delivered in a line read
    reg [31:0] pci_lo;                  // dense quadword read: the first longword

    // window registers (21071-DA; shadows of the DA CSRs at 0xC0..0x1C0)
    reg [31:0] tbr1, tbr2, pbr1, pbr2, pmr1, pmr2, haxr1, haxr2;
    // 21071-DA error state: DCSR<15:5> (RW1C), DCSR<21:18> the failing PCI command, PEAR
    reg [15:5] dcsr_err;
    reg  [3:0] dcsr_cmd;
    reg [31:0] pear;
    // DMA translation (21071 10.1.1.x, Tables 10-7/10-8). TBR<31:9> holds
    // address bits <32:10>. A window is direct mapped, or (PBR<18> SGEN)
    // scatter/gather: 8 KB pages through quadword map entries in memory
    // (bit 0 valid, bits <20:1> = PA<32:13>), cached in an 8-entry TLB
    // (round robin, cleared by a write to TBIA at 1.A000.0400)
    function [36:0] dma_xlate;          // {wh, sg, window 2, PA[33:0] or the map entry's address}
        input [31:0] a;
        reg   [31:0] m;
        reg   [33:0] tb;
        reg          w2, wh, sg;
        begin
            wh = 1'b0; w2 = 1'b0; sg = 1'b0; m = 32'd0; tb = 34'd0;
            if (pbr1[19] && (a & ~{pmr1[31:20], 20'hFFFFF}) == ({pbr1[31:20], 20'd0} & ~{pmr1[31:20], 20'hFFFFF})) begin
                wh = 1'b1; sg = pbr1[18]; m = {pmr1[31:20], 20'hFFFFF}; tb = {1'b0, tbr1[31:9], 10'd0};
            end else if (pbr2[19] && (a & ~{pmr2[31:20], 20'hFFFFF}) == ({pbr2[31:20], 20'd0} & ~{pmr2[31:20], 20'hFFFFF})) begin
                wh = 1'b1; sg = pbr2[18]; w2 = 1'b1; m = {pmr2[31:20], 20'hFFFFF}; tb = {1'b0, tbr2[31:9], 10'd0};
            end
            if (!sg)
                dma_xlate = {wh, 1'b0, w2, (tb & {2'b11, ~m}) | {2'b00, a & m}};
            else                        // the map entry: base with the page index in place of its low bits
                dma_xlate = {wh, 1'b1, w2, (tb & ~({12'd0, m[31:13], 3'b000} | 34'h7)) |
                                             {12'd0, a[31:13] & m[31:13], 3'b000}};
        end
    endfunction
    wire [36:0] dmx_raw = dma_xlate(dm_addr);
    // the S/G TLB
    reg  [7:0]  sg_v;
    reg [31:13] sg_tag [0:7];
    reg [32:13] sg_pfn [0:7];
    reg  [2:0]  sg_rr;
    reg  [7:0]  sg_hitv;
    reg [32:13] sg_hpfn;
    integer si;
    always @* begin
        sg_hpfn = 20'd0;
        for (si = 0; si < 8; si = si + 1) begin
            sg_hitv[si] = sg_v[si] && sg_tag[si] == dm_addr[31:13];
            if (sg_hitv[si]) sg_hpfn = sg_hpfn | sg_pfn[si];
        end
    end
    // {hit, PA}: direct, or an S/G TLB hit; dmx_miss: an S/G window without a TLB entry
    wire        dmx_sg   = dmx_raw[36] && dmx_raw[35];
    wire        dmx_miss = dmx_sg && sg_hitv == 8'd0;
    wire [34:0] dmx = !dmx_raw[36] ? 35'd0 :
                      !dmx_raw[35] ? {1'b1, dmx_raw[33:0]} :
                      {sg_hitv != 8'd0, 1'b0, sg_hpfn, dm_addr[12:0]};
    reg  [31:13] sgf_tag;               // the S/G entry being fetched
    reg         dma_lane;               // the longword lane of the DMA access in the DRAM quadword

    // PCI byte enables from a sparse access: length PA<4:3>, lane PCIaddr<1:0>
    function [3:0] sp_be;
        input [1:0] len; input [1:0] lane;
        sp_be = len == 2'd0 ? (4'b0001 << lane) : len == 2'd1 ? (4'b0011 << lane) :
                len == 2'd2 ? (4'b0111 << lane) : 4'b1111;
    endfunction
    (* ramstyle = "no_rw_check, M10K" *) reg [7:0] nvram [0:8191];   // no port relies on read-during-write
    reg [7:0] nv_q;
    // the NVRAM as a true dual-port M10K: each port in its own block (a port
    // that shared a block with the CSR RAMs was not inferred as RAM)
    always @(posedge clk) begin                 // port A: the CPU
        nv_q <= nvram[nv_a];
        if (nv_we) nvram[nv_a] <= nv_wd;
    end
    always @(posedge clk) begin                 // port B (true dual-port M10K)
        nvb_rdata <= nvram[nvb_addr];
        if (nvb_we) nvram[nvb_addr] <= nvb_wdata;
    end
    always @(posedge clk) begin
        ca_q <= ca[ca_a]; if (ca_we) ca[ca_a] <= ca_wd;
        da_q <= da[da_a]; if (da_we) da[da_a] <= da_wd;
        nv_dirty <= nv_we;
    end

    // the longword lane of this access, for 32-bit registers
    wire        hi   = c_be[3:0] == 4'd0;
    wire [31:0] wlw  = hi ? c_wdata[63:32] : c_wdata[31:0];
    function [63:0] lw2q;               // a longword read: both halves (the CPU picks its lane)
        input [31:0] v;
        lw2q = {v, v};
    endfunction

    integer k;
    reg [1:0] bank;
    reg       bank_hit;
    always @* begin
        bank = 2'd0; bank_hit = 1'b0;
        if (hit[2]) begin bank = 2'd2; bank_hit = 1'b1; end
        if (hit[1]) begin bank = 2'd1; bank_hit = 1'b1; end
        if (hit[0]) begin bank = 2'd0; bank_hit = 1'b1; end
    end
    wire [27:0] isz  = inst_size[bank];
    wire [27:0] doff = inst_base[bank] + (boff[bank][27:0] & (isz - 28'd1));

    // the write data is taken whenever S_IDLE sees a request, apart from the
    // decode: it means something only with the d_req that decode raises
    // (timing: its enable sat behind the DMA window compare, -2.1 ns)
    always @(posedge clk)
        if (st == S_IDLE) d_wdata <= (dm_req && !dm_ack) ? {8{dm_wdata}} : c_line ? c_wline : {4{c_wdata}};

    always @(posedge clk) begin
        c_ack <= 1'b0;
        dm_ack <= 1'b0;
        dinv <= 1'b0;
        ca_we <= 1'b0; da_we <= 1'b0; nv_we <= 1'b0;
        if (rst) begin
            st <= S_IDLE; d_req <= 1'b0; d_line <= 1'b0; f_req <= 1'b0; pt_req <= 1'b0; dm_ack <= 1'b0; leds <= 8'hFF;
            tbr1 <= 32'd0; tbr2 <= 32'd0; pbr1 <= 32'd0; pbr2 <= 32'd0; pmr1 <= 32'd0; pmr2 <= 32'd0;
            haxr1 <= 32'd0; haxr2 <= 32'd0;
            sg_v <= 8'd0; sg_rr <= 3'd0;
            dcsr_err <= 11'd0; dcsr_cmd <= 4'd0; pear <= 32'd0;
            for (k = 0; k < 3; k = k + 1) begin bcnfg[k] <= 9'd0; bbase[k] <= 16'd0; end
        end else case (st)
        S_IDLE: if (dm_req && !dm_ack) begin
            // ---------------------------------------- DMA first
            if (dmx_miss) begin
                // read the scatter/gather map entry, then retry the DMA (a TLB hit)
                d_req <= 1'b1; d_we <= 1'b0; d_addr <= dmx_raw[26:3]; d_be <= 32'hFF; d_line <= 1'b0;
                sgf_tag <= dm_addr[31:13];
                st <= S_SGR;
            end else if (dmx[34]) begin
                d_req <= 1'b1; d_we <= dm_we; d_addr <= dmx[26:3]; d_line <= 1'b0;
                d_be <= {28'd0, dm_be} << {dmx[4:2], 2'b00};
                dma_lane <= dmx[2];
                st <= S_DMA;
                dinv <= dm_we; dinv_idx <= dmx[12:5];
            end else begin
                dm_rdata <= 32'hFFFFFFFF; dm_ack <= 1'b1;      // no window: master abort (STUB: error bits)
            end
        end else if (c_req && !c_ack) begin
            if (pa[33:32] == 2'd0) begin
                // ---------------------------------------- memory
                if (bank_hit && isz != 28'd0) begin
                    d_req <= 1'b1; d_we <= c_we; d_addr <= doff[26:3];
                    if (c_line) d_be <= c_wmask;
                    else d_be <= {24'd0, c_be} << {doff[4:3], 3'b000};
                    d_line <= c_line && !c_we; d_beats <= 2'd0;
                    st <= S_DRAM;
                end else begin
                    c_rdata <= {64{1'b1}}; c_ack <= 1'b1;   // empty or no bank
                end
            end else if (pa[33:20] == 14'h1000) begin
                // ---------------------------------------- flashbus index
                if (c_we) fb_index <= wlw;
                c_rdata <= lw2q(fb_index); c_ack <= 1'b1;
            end else if (pa[33:20] == 14'h1001) begin
                // ---------------------------------------- flashbus data
                case (fb_index[28:26])           // offset <20:18>: the device
                3'd4: begin                      // NVRAM (8 KB, wraps)
                    nv_a <= fb_index[20:8]; nv_wd <= wlw[7:0]; nv_we <= c_we && fb_index[31];
                    lsel <= 2'd2; st <= S_LR1;
                end
                3'd5: begin                      // LEDs
                    if (c_we && fb_index[31]) leds <= wlw[7:0];
                    c_rdata <= lw2q({24'd0, leds}); c_ack <= 1'b1;
                end
                3'd7: begin                      // jumpers
                    c_rdata <= lw2q({24'd0, jumpers}); c_ack <= 1'b1;
                end
                3'd0, 3'd1, 3'd2, 3'd3, 3'd6: begin   // flash 0-3, DROM
                    if (c_we && !fb_index[31]) begin
                        c_rdata <= 64'd0; c_ack <= 1'b1;   // a write without the harbinger
                    end else if (!c_we || fb_index[31]) begin
                        f_req <= 1'b1; f_we <= c_we; f_addr <= fb_index[28:8]; f_wdata <= wlw[7:0];
                        st <= S_FB;
                    end
                end
                default: begin c_rdata <= {64{1'b1}}; c_ack <= 1'b1; end
                endcase
            end else if (pa[33:12] == 22'h180000) begin
                // ---------------------------------------- 21071-CA CSRs
                ca_a <= pa[11:5]; ca_we <= c_we;
                ca_wd <= pa[11:5] == 7'h02 ? 32'd0 : wlw;              // EDSR: error bits RW1C, none set
                if (c_we && pa[11:5] >= 7'h40 && pa[11:5] <= 7'h42) bbase[pa[6:5]] <= wlw[15:0];
                if (c_we && pa[11:5] >= 7'h50 && pa[11:5] <= 7'h52) bcnfg[pa[6:5]] <= wlw[8:0];
                lsel <= 2'd0; st <= S_LR1;
            end else if (pa[33:12] == 22'h1A0000) begin
                // ---------------------------------------- 21071-DA CSRs
                if (c_we) case (pa[11:5])
                    7'h06: tbr1 <= wlw;  7'h07: tbr2 <= wlw;
                    7'h08: pbr1 <= wlw;  7'h09: pbr2 <= wlw;
                    7'h0A: pmr1 <= wlw;  7'h0B: pmr2 <= wlw;
                    7'h0D: haxr1 <= wlw; 7'h0E: haxr2 <= wlw;
                    7'h20: sg_v <= 8'd0;                 // TBIA
                    default: ;
                endcase
                da_a <= pa[11:5]; da_we <= c_we;
                da_wd <= pa[11:5] == 7'h00 ? (wlw & 32'h0003000F) : wlw;   // DCSR: the RW bits only
                if (c_we && pa[11:5] == 7'h00) dcsr_err <= dcsr_err & ~wlw[15:5];   // the error bits: RW1C
                lsel <= 2'd1; st <= S_LR1;
            end else if (pa[33:28] == 6'h1B) begin
                // ---------------------------------------- PCI interrupt acknowledge (1.B000.0000, read)
                pt_req <= 1'b1; pt_cmd <= 2'd3; pt_dev <= 5'd0; pt_we <= 1'b0;
                pt_addr <= 32'd0; pt_be <= 4'hF; pt_wdata <= 32'd0; pci_hi <= 1'b0;
                st <= S_PCI;
            end else if (pa[33:29] == 5'b01110) begin
                // ---------------------------------------- PCI sparse I/O
                pt_req <= 1'b1; pt_cmd <= 2'd1; pt_dev <= 5'd0; pt_we <= c_we;
                pt_addr <= {8'd0, pa[28:7], 2'b00}; pt_be <= sp_be(pa[4:3], pa[6:5]);
                pt_wdata <= wlw; pci_hi <= 1'b0;
                st <= S_PCI;
            end else if (pa[33:29] == 5'b01111) begin
                // ---------------------------------------- PCI configuration (type 0, bus 0)
                pt_req <= 1'b1; pt_cmd <= 2'd0; pt_dev <= pa[20:16]; pt_we <= c_we;
                pt_addr <= {21'd0, pa[15:13], pa[12:7], 2'b00}; pt_be <= sp_be(pa[4:3], pa[6:5]);
                pt_wdata <= wlw; pci_hi <= 1'b0;
                st <= S_PCI;
            end else if (pa[33:32] == 2'd2) begin
                // ---------------------------------------- PCI sparse memory: {HAXR1<31:27>, PA<31:5>>...}
                pt_req <= 1'b1; pt_cmd <= 2'd2; pt_dev <= 5'd0; pt_we <= c_we;
                pt_addr <= {haxr1[31:27], pa[31:7], 2'b00}; pt_be <= sp_be(pa[4:3], pa[6:5]);
                pt_wdata <= wlw; pci_hi <= 1'b0;
                st <= S_PCI;
            end else if (pa[33:32] == 2'd3) begin
                // ---------------------------------------- PCI dense memory: longword or quadword
                pt_req <= 1'b1; pt_cmd <= 2'd2; pt_dev <= 5'd0; pt_we <= c_we;
                pt_addr <= {pa[31:3], c_be[3:0] == 4'd0, 2'b00};
                pt_be <= c_be[3:0] == 4'd0 ? c_be[7:4] : c_be[3:0];
                pt_wdata <= c_be[3:0] == 4'd0 ? c_wdata[63:32] : c_wdata[31:0];
                pci_hi <= c_be[3:0] != 4'd0 && c_be[7:4] != 4'd0;   // both halves: a quadword
                st <= S_PCI;
            end else begin
                c_rdata <= {64{1'b1}}; c_ack <= 1'b1;
            end
        end
        // a CSR/NVRAM write lands at the S_IDLE->S_LR1 edge's next edge; the
        // read (old data for a write, which software does not rely on) arrives in S_LR2
        S_LR1: st <= S_LR2;
        S_LR2: begin
            // pass-2 chips (read only): 21071-CA EDSR<13>, 21071-DA DCSR<31>. SRM's PALcode
            // picks the PCI configuration address form from DCSR<31>: pass 2 decodes the
            // device number in PA<20:16> into IDSEL itself (21071 Table 10-4)
            c_rdata <= lsel == 2'd0 ? lw2q(ca_q | (ca_a == 7'h02 ? 32'h0000_2000 : 32'd0)) :
                       lsel == 2'd1 ? lw2q(da_a == 7'h00 ? ((da_q & 32'h0003000F) | 32'h8000_0000 |
                                                             {10'd0, dcsr_cmd, 2'b00, dcsr_err, 5'd0}) :
                                           da_a == 7'h01 ? pear : da_q) :
                       lw2q({24'd0, nv_q});
            c_ack <= 1'b1; st <= S_IDLE;
        end
        S_DRAM: if (d_ack) begin
            c_rdata <= d_rdata; c_ack <= 1'b1;
            d_beats <= d_beats + 2'd1;
            if (!d_line || d_beats == 2'd3) begin d_req <= 1'b0; d_line <= 1'b0; st <= S_IDLE; end
        end
        S_FB: if (f_ack) begin
            f_req <= 1'b0;
            c_rdata <= lw2q({24'd0, f_rdata}); c_ack <= 1'b1; st <= S_IDLE;
        end
        // PCI: the claim is decided in the first cycle the request is out
        S_PCI: begin
`ifdef SIM_PCILOG
            if (pt_cmd == 2'd0) $display("PCICFG %s dev %0d addr %h be %h wdata %h claim %0d",
                                         pt_we ? "W" : "R", pt_dev, pt_addr, pt_be, pt_wdata, pt_claim);
`endif
            if (!pt_claim) begin
                pt_req <= 1'b0;
                c_rdata <= {64{1'b1}}; c_ack <= 1'b1; st <= S_IDLE;     // master abort
                // DCSR<11> ndev_err, PEAR = the PCI address, DCSR<21:18> = the PCI command
                if (dcsr_err[11] == 1'b0) begin
                    pear <= pt_cmd == 2'd0 ? (32'd1 << ({1'b0, pt_dev} + 6'd11)) | pt_addr : pt_addr;   // config: IDSEL AD<11+dev>
                    dcsr_cmd <= pt_cmd == 2'd0 ? (pt_we ? 4'hB : 4'hA) : pt_cmd == 2'd1 ? (pt_we ? 4'h3 : 4'h2)
                                                                       : (pt_we ? 4'h7 : 4'h6);
                end
                dcsr_err[11] <= 1'b1;
            end else st <= S_PCIW;
        end
        S_PCIW: if (pt_ack) begin
            pt_req <= 1'b0;
`ifdef SIM_PCILOG
            if (pt_cmd == 2'd0 && !pt_we) $display("PCICFG   -> %h", pt_rdata);
            // +iolog: the 8259s, the 8242 and IACK (the keyboard and interrupt path)
            if ($test$plusargs("iolog") && (pt_cmd == 2'd3 || (pt_cmd == 2'd1 &&
                (pt_addr[15:1] == 15'h0010 || pt_addr[15:1] == 15'h0050 || pt_addr[15:0] == 16'h0060 || pt_addr[15:0] == 16'h0064))))
                $display("IO %s %h be %h w %h r %h", pt_cmd == 2'd3 ? "IACK" : pt_we ? "W" : "R", pt_addr, pt_be, pt_wdata, pt_rdata);
`endif
            if (pci_hi) begin
                // dense quadword: now the upper longword
                pci_lo <= pt_rdata; pci_hi <= 1'b0;
                pt_addr <= pt_addr + 32'd4; pt_be <= c_be[7:4]; pt_wdata <= c_wdata[63:32];
                st <= S_PCI2;
            end else begin
                c_rdata <= (pt_cmd == 2'd2 && pa[33:32] == 2'd3 && c_be[3:0] != 4'd0 && c_be[7:4] != 4'd0)
                           ? {pt_rdata, pci_lo} : lw2q(pt_rdata);
                c_ack <= 1'b1; st <= S_IDLE;
            end
        end
        S_PCI2: begin pt_req <= 1'b1; st <= S_PCI; end
        S_SGR: if (d_ack) begin
            d_req <= 1'b0;
            if (d_rdata[0]) begin                       // valid: load the TLB (round robin)
                sg_v[sg_rr] <= 1'b1; sg_tag[sg_rr] <= sgf_tag; sg_pfn[sg_rr] <= d_rdata[20:1];
                sg_rr <= sg_rr + 3'd1;
                st <= S_IDLE;
            end else begin                              // invalid entry: DCSR<14> ptl_inv, PEAR
                dm_rdata <= 32'hFFFFFFFF; dm_ack <= 1'b1; st <= S_IDLE;
                if (dcsr_err[14] == 1'b0) pear <= {sgf_tag, 13'd0};
                dcsr_err[14] <= 1'b1;
            end
        end
        S_DMA: if (d_ack) begin
            d_req <= 1'b0;
            dm_rdata <= dma_lane ? d_rdata[63:32] : d_rdata[31:0];
            dm_ack <= 1'b1; st <= S_IDLE;
        end
        default: st <= S_IDLE;
        endcase
    end
endmodule
