//============================================================================
//
//  DEC AlphaStation 200 - the NCR 53C810 PCI SCSI controller (on board,
//  PCI device 6 = IDSEL AD17, INTA -> PIRQ3)
//
//  Ported to Verilog-2001 from the user's IBM RS/6000 7248 core
//  (rtl/machine/IBMRS6K7248_ncr810.sv, itself from the HP 9000/715 core's
//  ncr53c710.sv). docs/design/scsi.md has the design, what DEC's DROM and
//  SRM use, and the gaps. Changes from the RS6K version:
//    - the host side is the core's internal PCI target bus and the DMA port
//      of docs/design/pci.md (32-bit, little-endian lanes: byte k of a
//      longword in bits 8k+7:8k, be[k]);
//    - BAR0 (I/O, 256 bytes) and BAR1 (memory, 256 bytes) both decode the
//      registers (SRM's driver uses BAR1); 80-FF alias 00-7F;
//    - configuration space 80-FF reaches the operating registers too (the
//      DROM's "53C810 Test" writes and reads back config 0xDC-0xDF, i.e.
//      SCRATCHB);
//    - LOAD and STORE (absolute and DSA-relative, 1-4 bytes);
//    - single step (DCNTL.SSM: DSTAT.SSI after each instruction, STD goes on);
//    - the general-purpose timer (STIME1 -> SIST1.GEN);
//    - a memory move whose source or destination is the chip's own
//      registers through either BAR (DMODE.SIOM/DIOM selects the space).
//  Still missing: reselection and target mode, the handshake timer, the
//  low-level bus mode (SOCL/SBCL driving), loopback (STEST2.SLB), parity.
//
//  The SCSI bus is scsi_targets.v's byte-level one (no arbitration, no
//  REQ/ACK timing, one target connected at a time).
//
//============================================================================

module ncr53c810 #(
    parameter DEVNUM   = 6,         // PCI device number (IDSEL)
    parameter REV      = 8'h02,     // PCI revision = CTEST3<7:4>
    parameter STO_UNIT = 6250       // clocks per 1/16 ms (100 MHz): timer code n = 2^n units
) (
    input  wire        clk,
    input  wire        reset,

    // the PCI target bus (docs/design/pci.md 2)
    input  wire        pt_req,
    input  wire  [1:0] pt_cmd,      // 0 configuration, 1 I/O, 2 memory
    input  wire  [4:0] pt_dev,
    input  wire [31:0] pt_addr,
    input  wire  [3:0] pt_be,
    input  wire        pt_we,
    input  wire [31:0] pt_wdata,
    output wire        pt_claim,
    output reg         pt_ack,
    output wire [31:0] pt_rdata,    // valid with pt_ack, else 0

    // DMA (docs/design/pci.md 3): one longword, held until dm_ack
    output reg         dm_req,
    output reg         dm_we,
    output wire [31:0] dm_addr,
    output reg   [3:0] dm_be,
    output reg  [31:0] dm_wdata,
    input  wire        dm_ack,
    input  wire [31:0] dm_rdata,

    output wire        inta_n,

    // the SCSI bus (scsi_targets.v)
    output reg         sb_sel,
    output reg   [2:0] sb_sel_id,
    output reg         sb_sel_atn,
    input  wire        sb_sel_done,
    input  wire        sb_sel_fail,
    input  wire        sb_bsy,
    input  wire        sb_req,
    input  wire  [2:0] sb_phase,
    input  wire  [7:0] sb_tdata,
    output reg         sb_ack,
    output reg   [7:0] sb_idata,
    output reg         sb_ackhold,
    output reg         sb_atn,
    output reg         sb_rst
);

// ---- PCI configuration header ---------------------------------------------------------------
reg  [15:0] pci_cmd;
reg   [4:0] pci_sts_w1c;                        // status bits 15-11
reg         pci_sts_dpd;                        // status bit 8
reg   [7:0] pci_cls, pci_lat, pci_intl;
reg  [31:8] bar0, bar1;
reg         set_ma;                             // received master abort (unused: no DMA errors yet)
reg  [31:0] cfg_q;
reg         ack_cfg;                            // the access acked was a header read
wire        io_on  = pci_cmd[0];
wire        mem_on = pci_cmd[1];

// the claim: combinational from the request (docs/design/pci.md 2), a small BAR compare
wire cfg_hit = pt_cmd == 2'd0 && pt_dev == DEVNUM[4:0] && pt_addr[10:8] == 3'd0;
wire io_hit  = pt_cmd == 2'd1 && io_on  && pt_addr[31:8] == bar0;
wire mem_hit = pt_cmd == 2'd2 && mem_on && pt_addr[31:8] == bar1;
assign pt_claim = pt_req && (cfg_hit || io_hit || mem_hit);

// the request is registered when accepted (cycle 0); cycle 1 does the access from the
// registered copy; pt_ack is out in cycle 2 with the data
reg         h_pend, h_hdr, h_we;
reg  [7:2]  h_reg;
reg  [3:0]  h_be;
reg  [31:0] h_wd;
wire acc     = pt_req && pt_claim && !h_pend && !pt_ack;
wire hdr_sel = h_pend && h_hdr;                 // the header (config 00-7F)
wire sel     = h_pend && !h_hdr;                // the registers: BAR0, BAR1, config 80-FF
wire we      = h_we;
wire [6:2] off = h_reg[6:2];
wire [3:0] be  = h_be;
wire [31:0] wdata = h_wd;
reg  [31:0] rdata;

integer k;
always @(posedge clk) begin
    h_pend <= acc;
    if (acc) begin
        h_hdr <= cfg_hit && !pt_addr[7]; h_we <= pt_we; h_reg <= pt_addr[7:2];
        h_be <= pt_be; h_wd <= pt_wdata;
    end
    pt_ack <= h_pend;
    if (h_pend) ack_cfg <= h_hdr;
    if (hdr_sel && we)
        case (h_reg)
            6'h01: begin
                if (be[0]) pci_cmd[7:0]  <= wdata[7:0] & 8'h47;
                if (be[1]) pci_cmd[15:8] <= wdata[15:8] & 8'h01;
                if (be[3]) pci_sts_w1c   <= pci_sts_w1c & ~wdata[31:27];
                if (be[3]) pci_sts_dpd   <= pci_sts_dpd & ~wdata[24];
            end
            6'h03: begin
                if (be[0]) pci_cls <= wdata[7:0];
                if (be[1]) pci_lat <= wdata[15:8];
            end
            6'h04: for (k = 1; k < 4; k = k + 1) if (be[k]) bar0[8 * k +: 8] <= wdata[8 * k +: 8];
            6'h05: for (k = 1; k < 4; k = k + 1) if (be[k]) bar1[8 * k +: 8] <= wdata[8 * k +: 8];
            6'h0F: if (be[0]) pci_intl <= wdata[7:0];
            default: ;
        endcase
    if (hdr_sel && !we)
        case (h_reg)
            6'h00:   cfg_q <= 32'h0001_1000;                                        // 53C810, NCR
            6'h01:   cfg_q <= {pci_sts_w1c, 2'b01, pci_sts_dpd, 8'h00, pci_cmd};    // medium DEVSEL
            6'h02:   cfg_q <= {24'h01_0000, REV};                                   // SCSI controller
            6'h03:   cfg_q <= {16'h0000, pci_lat, pci_cls};
            6'h04:   cfg_q <= {bar0, 8'h01};                                        // I/O, 256 bytes
            6'h05:   cfg_q <= {bar1, 8'h00};                                        // memory, 32-bit, 256 bytes
            6'h0F:   cfg_q <= {8'h40, 8'h11, 8'h01, pci_intl};                      // MAX_LAT, MIN_GNT, INTA
            default: cfg_q <= 32'h0;
        endcase
    if (set_ma) pci_sts_w1c[2] <= 1'b1;                                             // bit 13
    if (reset) begin
        pt_ack <= 1'b0; h_pend <= 1'b0;
        pci_cmd <= 16'h0; pci_sts_w1c <= 5'd0; pci_sts_dpd <= 1'b0;
        pci_cls <= 8'h0; pci_lat <= 8'h0; pci_intl <= 8'h0;
        bar0 <= 24'h0; bar1 <= 24'h0;
    end
end
assign pt_rdata = !pt_ack ? 32'd0 : ack_cfg ? cfg_q : rdata;   // zero but with pt_ack: devices OR together

// ---- the chip's registers -------------------------------------------------------------------
reg  [7:0]  scntl0, scntl1, scntl2, scntl3, scid, sxfer, sdid, gpreg, sfbr, socl, ssid;
reg  [6:0]  dstat_st, dstat_pend;               // DSTAT 6-0 (DFE separately)
reg  [7:0]  sist0_st, sist0_pend;
reg  [2:0]  sist1_st, sist1_pend;
reg  [2:0]  latched_phase;                      // SSTAT1's: the phase at the last REQ
reg  [31:0] dsa, temp, mm_dst, dnad, dsp, dsps, scratcha, scratchb, adder;
reg  [7:0]  ctest0, ctest3_w, ctest4, ctest5, ctest6;
reg  [23:0] dbc;
reg  [7:0]  dcmd;
reg  [7:0]  dmode, dien, sbr, dcntl;
reg  [7:0]  sien0;
reg  [2:0]  sien1;
reg  [7:0]  slpar, macntl, gpcntl, stime0, stime1, respid, stest1, stest2, stest3_w;
reg  [7:0]  sidl, sodl;
reg         sigp, sem, intf, abrt_req, srst, carry;
reg         con;                                // connected
reg         bsy_q;
reg         target_mode;

// fatal SCSI interrupts halt and show in ISTAT.SIP whatever SIEN says; GEN (non-fatal) only when enabled
wire         sip    = sist0_st != 8'd0 || sist1_st[2] || sist1_st[0] || (sist1_st[1] && sien1[1]);
wire         dip    = dstat_st != 7'd0;
wire  [7:0]  dstat  = {1'b1, dstat_st};                       // DFE: no FIFO
wire  [7:0]  istat  = {abrt_req, srst, sigp, sem, con, intf, sip, dip};
wire  [7:0]  sstat0 = {6'd0, sb_rst, 1'b0};
wire  [7:0]  sstat1 = {5'd0, latched_phase};
wire  [7:0]  sbcl   = {sb_req, sb_ack | sb_ackhold, sb_bsy, sb_sel, sb_atn, sb_bsy ? sb_phase : 3'b000};
wire  [7:0]  sbdl   = sb_req ? sb_tdata : sodl;
wire  [7:0]  ctest1 = 8'hF0;                                  // the FIFO's lanes empty
wire  [7:0]  ctest2 = {1'b0, sigp, 1'b1, 1'b0, 3'b000, 1'b1}; // CIO (I/O mapped), DACK
wire  [7:0]  ctest3 = {REV[3:0], ctest3_w[3], 1'b0, ctest3_w[1:0]};
wire  [7:0]  dfifo  = {1'b0, dbc[6:0]};

wire irq = !dcntl[1] && ((dstat_st & dien[6:0] & 7'h7D) != 7'd0 || (sist0_st & sien0) != 8'd0 ||
                         (sist1_st & sien1) != 3'd0 || intf);

function [7:0] reg_rd;
    input [6:0] a;
    case (a)
        7'h00: reg_rd = scntl0;   7'h01: reg_rd = {scntl1[7:5], con, scntl1[3:0]};
        7'h02: reg_rd = scntl2;   7'h03: reg_rd = scntl3;
        7'h04: reg_rd = scid;     7'h05: reg_rd = sxfer;
        7'h06: reg_rd = sdid;     7'h07: reg_rd = gpreg;
        7'h08: reg_rd = sfbr;     7'h09: reg_rd = socl;
        7'h0A: reg_rd = ssid;     7'h0B: reg_rd = sbcl;
        7'h0C: reg_rd = dstat;    7'h0D: reg_rd = sstat0;
        7'h0E: reg_rd = sstat1;   7'h0F: reg_rd = 8'h00;          // SSTAT2
        7'h10: reg_rd = dsa[7:0]; 7'h11: reg_rd = dsa[15:8]; 7'h12: reg_rd = dsa[23:16]; 7'h13: reg_rd = dsa[31:24];
        7'h14: reg_rd = istat;
        7'h18: reg_rd = ctest0;   7'h19: reg_rd = ctest1;
        7'h1A: reg_rd = ctest2;   7'h1B: reg_rd = ctest3;
        7'h1C: reg_rd = temp[7:0]; 7'h1D: reg_rd = temp[15:8]; 7'h1E: reg_rd = temp[23:16]; 7'h1F: reg_rd = temp[31:24];
        7'h20: reg_rd = dfifo;    7'h21: reg_rd = ctest4;
        7'h22: reg_rd = ctest5;   7'h23: reg_rd = ctest6;
        7'h24: reg_rd = dbc[7:0]; 7'h25: reg_rd = dbc[15:8]; 7'h26: reg_rd = dbc[23:16]; 7'h27: reg_rd = dcmd;
        7'h28: reg_rd = dnad[7:0]; 7'h29: reg_rd = dnad[15:8]; 7'h2A: reg_rd = dnad[23:16]; 7'h2B: reg_rd = dnad[31:24];
        7'h2C: reg_rd = dsp[7:0]; 7'h2D: reg_rd = dsp[15:8]; 7'h2E: reg_rd = dsp[23:16]; 7'h2F: reg_rd = dsp[31:24];
        7'h30: reg_rd = dsps[7:0]; 7'h31: reg_rd = dsps[15:8]; 7'h32: reg_rd = dsps[23:16]; 7'h33: reg_rd = dsps[31:24];
        7'h34: reg_rd = scratcha[7:0]; 7'h35: reg_rd = scratcha[15:8]; 7'h36: reg_rd = scratcha[23:16]; 7'h37: reg_rd = scratcha[31:24];
        7'h38: reg_rd = dmode;    7'h39: reg_rd = dien;
        7'h3A: reg_rd = sbr;      7'h3B: reg_rd = dcntl;
        7'h3C: reg_rd = adder[7:0]; 7'h3D: reg_rd = adder[15:8]; 7'h3E: reg_rd = adder[23:16]; 7'h3F: reg_rd = adder[31:24];
        7'h40: reg_rd = sien0;    7'h41: reg_rd = {5'd0, sien1};
        7'h42: reg_rd = sist0_st; 7'h43: reg_rd = {5'd0, sist1_st};
        7'h44: reg_rd = slpar;
        7'h46: reg_rd = {4'h0, macntl[3:0]};
        7'h47: reg_rd = gpcntl;
        7'h48: reg_rd = stime0;   7'h49: reg_rd = stime1;
        7'h4A: reg_rd = respid;
        7'h4C: reg_rd = 8'h00;    7'h4D: reg_rd = stest1;         // STEST0, STEST1
        7'h4E: reg_rd = stest2;   7'h4F: reg_rd = {stest3_w[7:2], 1'b0, stest3_w[0]};
        7'h50: reg_rd = sidl;     7'h54: reg_rd = sodl;     7'h58: reg_rd = sbdl;
        7'h5C: reg_rd = scratchb[7:0]; 7'h5D: reg_rd = scratchb[15:8]; 7'h5E: reg_rd = scratchb[23:16]; 7'h5F: reg_rd = scratchb[31:24];
        default: reg_rd = 8'h00;
    endcase
endfunction


// ---- the SCRIPTS engine ---------------------------------------------------------------------
// Timing (100 MHz): an instruction is fetched (E_FETCH), then E_PRE registers its address
// arithmetic (DSA + offset, the jump target) and the comparisons decode needs; E_DECODE works
// from those registers. Register instructions take three cycles (operand, ALU, write), transfer
// control two (condition, action). The interrupt status bits an engine cycle raises (set_*)
// are registered (q_*) before they are stacked into DSTAT/SIST0/SIST1.
localparam [4:0] E_IDLE = 5'd0, E_FETCH = 5'd1, E_DECODE = 5'd2, E_IND = 5'd3,
                 E_BM_WAIT = 5'd4, E_BM_BYTE = 5'd5, E_BM_RD = 5'd6, E_BM_GIVE = 5'd7, E_BM_END = 5'd8,
                 E_SEL = 5'd9, E_SEL_WAIT = 5'd10, E_STO = 5'd11, E_WDISC = 5'd12, E_WRESEL = 5'd13,
                 E_TC_WAIT = 5'd14, E_TC_EVAL = 5'd15,
                 E_MM_RD = 5'd16, E_MM_WR = 5'd17, E_FLUSH = 5'd18,
                 E_PRE = 5'd19, E_REG_RD = 5'd20, E_REG_ALU = 5'd21, E_REG_WR = 5'd22, E_TC_DO = 5'd23;
reg  [4:0]  est;

reg  [2:0]  fcnt;                               // the fetch's word
reg  [31:0] ins0;                               // DCMD | DBC as fetched
reg         first_byte;
reg         fl_next;                            // after E_FLUSH: the next instruction (else halt)
reg         stepped;                            // an instruction ran since the start (single step)
reg  [31:0] sto_cnt, sto_lim, gen_cnt, gen_lim;
reg         sto_hit, gen_hit, gen_on;
// E_PRE's results
reg  [31:0] dsa_rel;                            // DSA + DSPS<23:0> (table indirect, LOAD/STORE)
reg  [31:0] sel_rel;                            // DSA + DBC (SELECT table indirect)
reg  [31:0] jmp_tgt;                            // the transfer target: relative or absolute
reg         i_dbc0;                             // the count is 0
reg         i_mm_sself, i_mm_dself, i_mm_iobad, i_mm_align;
// the register instruction and transfer control stages
reg  [7:0]  r_src, r_res;
reg         tc_take;
// the one-longword write buffer and read cache
reg         wb_valid;
reg  [31:2] wb_addr;
reg  [31:0] wb_data;
reg  [3:0]  wb_be;
reg         rc_valid;
reg  [31:2] rc_addr;
reg  [31:0] rc_data;
// a memory move / LOAD / STORE: its source or destination is the chip's own registers
reg         mm_sreg, mm_dreg;
reg  [7:0]  mm_byte;
// the DMA: dm_* are its registers, held while the request is out
reg         dmst;                               // 0 idle, 1 busy
reg         d_go, d_done;
reg  [31:0] d_addr;
assign dm_addr = {d_addr[31:2], 2'b00};

wire [7:0] reg_imm = ins0[15:8];
wire [6:0] reg_adr = ins0[22:16];

// an address that is the chip's own registers: memory space through BAR1, I/O through BAR0
function self_hit;
    input        io;
    input [31:0] a;
    self_hit = io ? (io_on && a[31:8] == bar0) : (mem_on && a[31:8] == bar1);
endfunction

function [31:0] sext24;
    input [23:0] v;
    sext24 = {{8{v[23]}}, v};
endfunction

always @(posedge clk) begin
    d_done <= 1'b0;
    if (reset || srst) begin dmst <= 1'b0; dm_req <= 1'b0; end
    else if (!dmst) begin if (d_go) begin dm_req <= 1'b1; dmst <= 1'b1; end end
    else if (dm_ack) begin dm_req <= 1'b0; d_done <= 1'b1; dmst <= 1'b0; end
end
wire d_idle = !dmst && !d_go && !d_done;

// the timers: 2^code units (code 0: none); the compares registered
always @(posedge clk) begin
    sto_lim <= stime0[3:0] == 4'd0 ? 32'hFFFF_FFFF : STO_UNIT << stime0[3:0];
    gen_lim <= STO_UNIT << stime1[3:0];
    sto_hit <= sto_cnt == sto_lim;
    gen_hit <= gen_cnt == gen_lim;
end

// INTA, registered
reg inta_q;
always @(posedge clk) inta_q <= reset ? 1'b1 : !irq;
assign inta_n = inta_q;

// set by the engine this cycle (blocking, inside the clocked block below), then registered
reg  [7:0] set_s0, set_ds, q_s0, q_ds;
reg  [2:0] set_s1, q_s1;

// a register written by the host or by SCRIPTS (not those with side effects)
task reg_wr;
    input [6:0] a;
    input [7:0] v;
    case (a)
        7'h00: scntl0 <= v;
        7'h02: scntl2 <= v;   7'h03: scntl3 <= v;
        7'h04: scid <= v;     7'h05: sxfer <= v;
        7'h06: sdid <= v;     7'h07: gpreg <= v;
        7'h08: sfbr <= v;     7'h09: socl <= v;
        7'h0A: ssid <= v;
        7'h10: dsa[7:0] <= v; 7'h11: dsa[15:8] <= v; 7'h12: dsa[23:16] <= v; 7'h13: dsa[31:24] <= v;
        7'h18: ctest0 <= v;
        7'h1C: temp[7:0] <= v; 7'h1D: temp[15:8] <= v; 7'h1E: temp[23:16] <= v; 7'h1F: temp[31:24] <= v;
        7'h21: ctest4 <= v;   7'h22: ctest5 <= v;   7'h23: ctest6 <= v;
        7'h24: dbc[7:0] <= v; 7'h25: dbc[15:8] <= v; 7'h26: dbc[23:16] <= v; 7'h27: dcmd <= v;
        7'h28: dnad[7:0] <= v; 7'h29: dnad[15:8] <= v; 7'h2A: dnad[23:16] <= v; 7'h2B: dnad[31:24] <= v;
        7'h30: dsps[7:0] <= v; 7'h31: dsps[15:8] <= v; 7'h32: dsps[23:16] <= v; 7'h33: dsps[31:24] <= v;
        7'h34: scratcha[7:0] <= v; 7'h35: scratcha[15:8] <= v; 7'h36: scratcha[23:16] <= v; 7'h37: scratcha[31:24] <= v;
        7'h38: dmode <= v;    7'h39: dien <= v;     7'h3A: sbr <= v;
        7'h40: sien0 <= v;    7'h41: sien1 <= v[2:0];
        7'h44: slpar <= v;    7'h46: macntl <= v;   7'h47: gpcntl <= v;
        7'h48: stime0 <= v;   7'h4A: respid <= v;
        7'h4D: stest1 <= v;   7'h4E: stest2 <= v;
        7'h54: sodl <= v;
        7'h5C: scratchb[7:0] <= v; 7'h5D: scratchb[15:8] <= v; 7'h5E: scratchb[23:16] <= v; 7'h5F: scratchb[31:24] <= v;
        default: ;
    endcase
endtask

// a register written by SCRIPTS (register instruction, memory move, LOAD): the side effects
// the engine may have (no SCRIPTS start, no ISTAT reset or abort)
task reg_wr_eng;
    input [6:0] a;
    input [7:0] v;
    case (a)
        7'h01: begin scntl1 <= v; sb_rst <= v[3]; if (v[3] && !scntl1[3]) set_s0[1] = 1'b1; end   // our own RST
        7'h14: begin sigp <= v[5]; sem <= v[4]; end
        7'h1B: ctest3_w <= v & 8'hFB;
        7'h2C: dsp[7:0] <= v; 7'h2D: dsp[15:8] <= v; 7'h2E: dsp[23:16] <= v; 7'h2F: dsp[31:24] <= v;
        7'h3B: dcntl <= v & 8'hFB;
        7'h49: begin stime1 <= v; gen_cnt <= 32'd0; gen_on <= v[3:0] != 4'd0; end
        7'h4F: stest3_w <= v & 8'hFD;
        default: reg_wr(a, v);
    endcase
endtask

// the write buffer out (the caller checks wb_valid && d_idle)
task wb_out;
    begin
        d_go <= 1'b1; dm_we <= 1'b1; d_addr <= {wb_addr, 2'b00}; dm_be <= wb_be; dm_wdata <= wb_data;
        wb_valid <= 1'b0;
    end
endtask
task dma_rd;
    input [31:0] a;
    begin
        d_go <= 1'b1; dm_we <= 1'b0; d_addr <= a; dm_be <= 4'hF;
    end
endtask
// one byte into the write buffer
task wb_put;
    input [31:0] a;
    input [7:0]  b;
    begin
        if (!wb_valid) begin wb_valid <= 1'b1; wb_addr <= a[31:2]; wb_be <= 4'b0001 << a[1:0]; end
        else wb_be[a[1:0]] <= 1'b1;
        wb_data[8 * a[1:0] +: 8] <= b;
    end
endtask

integer i;
always @(posedge clk) begin : engine
    reg [6:0]  a;
    reg [7:0]  v, res, b;
    reg [8:0]  sum;
    reg        c_out, s, pm, dm, cnd, take;
    reg [2:0]  ph;
    reg [31:0] w, ma;
    set_s0 = 8'd0; set_ds = 8'd0; set_s1 = 3'd0;
    sb_sel <= 1'b0; sb_ack <= 1'b0;
    d_go <= 1'b0;
    set_ma <= 1'b0;

    if (reset || srst) begin
        scntl0 <= 8'hC0; scntl1 <= 8'd0; scntl2 <= 8'd0; scntl3 <= 8'd0; scid <= 8'd0; sxfer <= 8'd0;
        sdid <= 8'd0; gpreg <= 8'd0; sfbr <= 8'd0; socl <= 8'd0; ssid <= 8'd0;
        dstat_st <= 7'd0; dstat_pend <= 7'd0; sist0_st <= 8'd0; sist0_pend <= 8'd0; sist1_st <= 3'd0; sist1_pend <= 3'd0;
        q_s0 <= 8'd0; q_s1 <= 3'd0; q_ds <= 8'd0;
        latched_phase <= 3'd0; dsa <= 32'd0; temp <= 32'd0; dnad <= 32'd0; dsp <= 32'd0; dsps <= 32'd0;
        scratcha <= 32'd0; scratchb <= 32'd0; adder <= 32'd0;
        ctest0 <= 8'd0; ctest3_w <= 8'd0; ctest4 <= 8'd0; ctest5 <= 8'd0; ctest6 <= 8'd0;
        dbc <= 24'd0; dcmd <= 8'd0; dmode <= 8'd0; dien <= 8'd0; sbr <= 8'd0; dcntl <= 8'd0;
        sien0 <= 8'd0; sien1 <= 3'd0;
        slpar <= 8'd0; macntl <= 8'd0; gpcntl <= 8'h0F; stime0 <= 8'd0; stime1 <= 8'd0; respid <= 8'd0;
        stest1 <= 8'd0; stest2 <= 8'd0; stest3_w <= 8'd0; sidl <= 8'd0; sodl <= 8'd0;
        if (reset) srst <= 1'b0;
        sigp <= 1'b0; sem <= 1'b0; intf <= 1'b0; abrt_req <= 1'b0; carry <= 1'b0; con <= 1'b0; target_mode <= 1'b0;
        bsy_q <= 1'b0; gen_on <= 1'b0; gen_cnt <= 32'd0; stepped <= 1'b0;
        sb_atn <= 1'b0; sb_ackhold <= 1'b0; sb_rst <= 1'b0;
        est <= E_IDLE; wb_valid <= 1'b0; rc_valid <= 1'b0; fcnt <= 3'd0;
    end
    if (reset) ;
    else if (srst) begin
        // ISTAT.SRST holds the chip in reset until the host clears it
        if (sel && we && off == 5'h05 && be[0] && !wdata[6]) srst <= 1'b0;
        if (sel && !we) rdata <= {reg_rd({off, 2'd3}), reg_rd({off, 2'd2}), reg_rd({off, 2'd1}), reg_rd({off, 2'd0})};
    end else begin
        // ------------------------------------------------ the host's register access (registered request)
        if (sel) begin
            if (!we) begin
                rdata <= {reg_rd({off, 2'd3}), reg_rd({off, 2'd2}), reg_rd({off, 2'd1}), reg_rd({off, 2'd0})};
                // reads that clear (and unstack)
                if (off == 5'h03 && be[0]) begin dstat_st <= dstat_pend; dstat_pend <= 7'd0; end      // DSTAT (0C)
                if (off == 5'h10 && be[2]) begin sist0_st <= sist0_pend; sist0_pend <= 8'd0; end      // SIST0 (42)
                if (off == 5'h10 && be[3]) begin sist1_st <= sist1_pend; sist1_pend <= 3'd0; end      // SIST1 (43)
                if (off == 5'h06 && be[2]) sigp <= 1'b0;                                              // CTEST2 (1A)
            end else begin
                for (i = 0; i < 4; i = i + 1) if (be[i]) begin
                    a = {off, i[1:0]}; v = wdata[8 * i +: 8];
                    case (a)
                        7'h01: begin
                            scntl1 <= v;
                            sb_rst <= v[3];
                            if (v[3] && !scntl1[3]) set_s0[1] = 1'b1;              // our own RST
                            if (v[4]) con <= 1'b1;
                        end
                        7'h14: begin                                               // ISTAT
                            abrt_req <= v[7];
                            if (v[6]) srst <= 1'b1;
                            sigp <= v[5];
                            sem  <= v[4];
                            if (v[2]) intf <= 1'b0;
                            if (v[7]) begin set_ds[4] = 1'b1; est <= E_IDLE; end
                        end
                        7'h1B: ctest3_w <= v & 8'hFB;                             // CLF reads 0
                        7'h2F: begin
                            dsp[31:24] <= v;
                            if (!dmode[0]) begin est <= E_FETCH; fcnt <= 3'd0; stepped <= 1'b0; end
                        end
                        7'h2C: dsp[7:0] <= v; 7'h2D: dsp[15:8] <= v; 7'h2E: dsp[23:16] <= v;
                        7'h3B: begin
                            dcntl <= v & 8'hFB;
                            if (v[2]) begin est <= E_FETCH; fcnt <= 3'd0; stepped <= 1'b0; end   // STD
                        end
                        7'h49: begin stime1 <= v; gen_cnt <= 32'd0; gen_on <= v[3:0] != 4'd0; end
                        7'h4F: stest3_w <= v & 8'hFD;                             // CSF reads 0
                        default: reg_wr(a, v);
                    endcase
                end
            end
        end
        if (sb_req) latched_phase <= sb_phase;
        bsy_q <= sb_bsy;
        if (bsy_q && !sb_bsy && est == E_IDLE) con <= 1'b0;
        // the general-purpose timer, one shot from the write of STIME1 (gen_hit: the compare, registered)
        if (gen_on) begin
            gen_cnt <= gen_cnt + 32'd1;
            if (gen_hit && gen_cnt != 32'd0) begin gen_on <= 1'b0; set_s1[1] = 1'b1; end
        end

        // ------------------------------------------------ the engine
        case (est)
            E_IDLE: fcnt <= 3'd0;

            // fetch: 2 words (3 for a memory move); single step stops before the next one
            E_FETCH: begin
                if (wb_valid && d_idle) begin
                    wb_out;
                    est <= E_FLUSH; fl_next <= 1'b1;                    // write back, then fetch again
                end else if (fcnt == 3'd0 && stepped && dcntl[4] && d_idle) begin
                    set_ds[3] = 1'b1; stepped <= 1'b0; est <= E_IDLE;   // SSI
                end else if (d_idle) dma_rd(dsp);
                if (d_done && !dm_we) begin
                    w = dm_rdata;
                    case (fcnt)
                        3'd0: begin ins0 <= w; dcmd <= w[31:24]; dbc <= w[23:0]; end
                        3'd1: begin dsps <= w; dnad <= w; end
                        default: mm_dst <= w;                // a memory move's destination
                    endcase
                    dsp <= dsp + 32'd4;
                    fcnt <= fcnt + 3'd1;
                    if ((fcnt == 3'd1 && ins0[31:29] != 3'b110) || fcnt == 3'd2) est <= E_PRE;
                end
            end

            // the decode's arithmetic and comparisons, registered
            E_PRE: begin
                dsa_rel <= dsa + sext24(dsps[23:0]);
                sel_rel <= dsa + sext24(ins0[23:0]);
                // relative: bit 23 for transfer control, bit 26 for the I/O instructions
                jmp_tgt <= ((ins0[31:30] == 2'b10) ? ins0[23] : ins0[26]) ? dsp + sext24(dsps[23:0]) : dsps;
                i_dbc0 <= ins0[23:0] == 24'd0;
                i_mm_sself <= self_hit(dmode[5], dsps);
                i_mm_dself <= self_hit(dmode[4], mm_dst);
                i_mm_iobad <= (dmode[5] && !self_hit(1'b1, dsps)) || (dmode[4] && !self_hit(1'b1, mm_dst));
                i_mm_align <= dsps[1:0] == mm_dst[1:0];
                est <= E_DECODE;
            end

            E_DECODE: begin
                first_byte <= 1'b1;
                fcnt <= 3'd0;
                stepped <= 1'b1;
                case (ins0[31:30])
                    2'b00: begin                                         // block move
                        if (target_mode || !ins0[27]) begin set_ds[0] = 1'b1; est <= E_IDLE; end    // target mode / CHMOV
                        else if (ins0[28] || ins0[29]) begin
                            // table indirect (DSA + offset) or indirect: the count and address
                            dma_rd(ins0[28] ? dsa_rel : dsps);
                            if (ins0[28]) adder <= dsa_rel;
                            est <= E_IND;
                        end else if (i_dbc0) begin set_ds[0] = 1'b1; est <= E_IDLE; end
                        else est <= E_BM_WAIT;
                    end
                    2'b01: begin
                        if (ins0[29:27] >= 3'b101) est <= E_REG_RD;      // register read / write
                        else case (ins0[29:27])
                            3'b000: begin                                   // SELECT
                                if (ins0[25]) begin
                                    // table indirect: SCNTL3, the ID and SXFER from DSA + offset
                                    dma_rd(sel_rel);
                                    adder <= sel_rel;
                                    est <= E_IND;
                                end else begin
                                    sdid <= {4'd0, ins0[19:16]}; est <= E_SEL;
                                end
                            end
                            3'b001: est <= E_WDISC;                         // WAIT DISCONNECT
                            3'b010: est <= E_WRESEL;                        // WAIT RESELECT
                            3'b011, 3'b100: begin                           // SET / CLEAR
                                s = ins0[29:27] == 3'b011;
                                if (ins0[3]) sb_atn <= s;
                                if (ins0[6]) sb_ackhold <= s;
                                if (ins0[9]) target_mode <= s;
                                if (ins0[10]) carry <= s;
                                est <= E_FETCH;
                            end
                            default: begin set_ds[0] = 1'b1; est <= E_IDLE; end
                        endcase
                    end
                    2'b10: begin                                         // transfer control
                        if (ins0[29:27] > 3'b011) begin set_ds[0] = 1'b1; est <= E_IDLE; end
                        else if (ins0[16] && con) est <= E_TC_WAIT;
                        else est <= E_TC_EVAL;
                    end
                    default: begin
                        if (ins0[29]) begin
                            // LOAD (bit 24) / STORE: 1-4 bytes between a register and memory
                            // (absolute, or DSA + offset with bit 28)
                            ma = ins0[28] ? dsa_rel : dsps;
                            if (ins0[2:0] == 3'd0 || ins0[2:0] > 3'd4 || ins0[27:26] != 2'd0) begin
                                set_ds[0] = 1'b1; est <= E_IDLE;
                            end else begin
                                dbc <= {21'd0, ins0[2:0]};
                                if (ins0[24]) begin
                                    dnad <= ma; mm_dst <= {25'd0, reg_adr}; mm_sreg <= 1'b0; mm_dreg <= 1'b1;
                                end else begin
                                    dnad <= {25'd0, reg_adr}; mm_dst <= ma; mm_sreg <= 1'b1; mm_dreg <= 1'b0;
                                end
                                est <= E_MM_RD;
                            end
                        end else if (ins0[28:25] != 4'd0 || !i_mm_align) begin
                            set_ds[0] = 1'b1; est <= E_IDLE;              // memory move: same alignment
                        end else if (i_dbc0) est <= E_FETCH;
                        else if (i_mm_iobad) begin
                            set_ds[5] = 1'b1; est <= E_IDLE;              // other PCI I/O space: a bus fault
                        end else begin
                            dnad <= dsps;
                            mm_sreg <= i_mm_sself;
                            mm_dreg <= i_mm_dself;
                            est <= E_MM_RD;
                        end
                    end
                endcase
            end

            // ---- register instructions: 101 SFBR op data to the register, 110 the register op
            // data to SFBR, 111 read-modify-write; operand, ALU, write in three cycles
            E_REG_RD: begin
                r_src <= ins0[29:27] == 3'b101 ? sfbr : reg_rd(reg_adr);
                est <= E_REG_ALU;
            end
            E_REG_ALU: begin
                sum = {1'b0, r_src} + {1'b0, reg_imm} + {8'd0, ins0[26:24] == 3'b111 && carry};
                c_out = carry;
                case (ins0[26:24])
                    3'b000: res = reg_imm;
                    3'b001: begin res = {r_src[6:0], carry}; c_out = r_src[7]; end      // SHL
                    3'b010: res = r_src | reg_imm;
                    3'b011: res = r_src ^ reg_imm;
                    3'b100: res = r_src & reg_imm;
                    3'b101: begin res = {carry, r_src[7:1]}; c_out = r_src[0]; end      // SHR
                    default: begin res = sum[7:0]; c_out = sum[8]; end                  // ADD, ADC
                endcase
                carry <= c_out;
                r_res <= res;
                est <= E_REG_WR;
            end
            E_REG_WR: begin
                if (ins0[29:27] == 3'b110) sfbr <= r_res;
                else reg_wr_eng(reg_adr, r_res);
                est <= E_FETCH;
            end

            // the indirect fetches: block move {count, address}, select {SCNTL3, ID, SXFER}
            E_IND: if (d_done) begin
                w = dm_rdata;
                if (ins0[31:30] == 2'b01) begin
                    scntl3 <= w[31:24]; sdid <= {4'd0, w[19:16]}; sxfer <= w[15:8]; est <= E_SEL;
                end else if (fcnt == 3'd0 && ins0[28]) begin
                    dbc <= w[23:0]; fcnt <= 3'd1;
                    dma_rd(d_addr + 32'd4);
                end else begin
                    dnad <= w;
                    fcnt <= 3'd0;
                    if (dbc == 24'd0) begin set_ds[0] = 1'b1; est <= E_IDLE; end
                    else est <= E_BM_WAIT;
                end
            end

            // ---- block move: wait for REQ, compare the phase, move the bytes
            E_BM_WAIT: begin
                if (!sb_bsy) begin set_s0[2] = 1'b1; con <= 1'b0; sb_ackhold <= 1'b0; est <= E_FLUSH; fl_next <= 1'b0; end   // UDC
                else if (sb_req) begin
                    if (sb_phase != ins0[26:24]) begin set_s0[7] = 1'b1; est <= E_FLUSH; fl_next <= 1'b0; end      // phase mismatch
                    else begin
                        sb_ackhold <= 1'b0;
                        if (sb_phase[0]) est <= E_BM_BYTE;              // IN
                        else est <= E_BM_RD;                            // OUT: the byte first
                    end
                end
            end
            // IN: the byte into the write buffer
            E_BM_BYTE: begin
                if (wb_valid && wb_addr != dnad[31:2]) begin
                    if (d_idle) wb_out;
                end else if (d_idle) begin
                    b = sb_tdata;
                    wb_put(dnad, b);
                    rc_valid <= 1'b0;
                    sidl <= b;
                    if (first_byte) sfbr <= b;
                    first_byte <= 1'b0;
                    dnad <= dnad + 32'd1; dbc <= dbc - 24'd1;
                    sb_ack <= 1'b1;
                    // the last byte of a MESSAGE IN move keeps ACK asserted
                    if (dbc == 24'd1 && sb_phase == 3'b111) sb_ackhold <= 1'b1;
                    est <= E_BM_END;
                end
            end
            // OUT: the byte (from the read cache), then give it
            E_BM_RD: begin
                if (rc_valid && rc_addr == dnad[31:2]) est <= E_BM_GIVE;
                else if (wb_valid && d_idle) wb_out;
                else if (d_idle && !wb_valid) dma_rd(dnad);
                if (d_done && !dm_we) begin rc_valid <= 1'b1; rc_addr <= dnad[31:2]; rc_data <= dm_rdata; est <= E_BM_GIVE; end
            end
            E_BM_GIVE: begin
                b = rc_data[8 * dnad[1:0] +: 8];
                sb_idata <= b; sodl <= b;
                if (first_byte) sfbr <= b;
                first_byte <= 1'b0;
                // MESSAGE OUT: ATN drops before the last byte
                if (dbc == 24'd1 && sb_phase == 3'b110) sb_atn <= 1'b0;
                dnad <= dnad + 32'd1; dbc <= dbc - 24'd1;
                sb_ack <= 1'b1;
                est <= E_BM_END;
            end
            // after each byte the target drops REQ: then the next byte, or done
            E_BM_END: if (!sb_ack && !sb_req) begin
                if (dbc == 24'd0) begin est <= E_FLUSH; fl_next <= 1'b1; end
                else est <= E_BM_WAIT;
            end

            // ---- SELECT: the target answers, or the time runs out
            E_SEL: begin
                sb_sel <= 1'b1;
                sb_sel_id <= sdid[2:0];
                sb_sel_atn <= ins0[24];
                sto_cnt <= 32'd0;
                est <= E_SEL_WAIT;
            end
            E_SEL_WAIT: begin
                if (sb_sel_done) begin
                    con <= 1'b1;
                    scntl2[7] <= 1'b1;                              // SDU: a disconnect now is unexpected
                    if (ins0[24]) sb_atn <= 1'b1;
                    est <= E_FETCH;
                end else if (sb_sel_fail) est <= E_STO;
            end
            E_STO: begin
                // sto_hit: the compare of the cycle before (sto_cnt is 0 through E_SEL_WAIT)
                sto_cnt <= sto_cnt + 32'd1;
                if (sto_hit) begin set_s1[2] = 1'b1; est <= E_IDLE; end
            end
            E_WDISC: if (!sb_bsy) begin con <= 1'b0; sb_ackhold <= 1'b0; est <= E_FETCH; end
            E_WRESEL: if (sigp) begin
                // SIGP: the alternate address (nothing reselects)
                dsp <= jmp_tgt;
                est <= E_FETCH;
            end

            // ---- transfer control: the condition, then the action
            E_TC_WAIT: begin
                if (!sb_bsy) begin set_s0[2] = 1'b1; con <= 1'b0; est <= E_IDLE; end
                else if (sb_req && !sb_ackhold) est <= E_TC_EVAL;
            end
            E_TC_EVAL: begin
                ph = sb_req ? sb_phase : latched_phase;
                pm = ph == ins0[26:24];
                dm = ((sfbr ^ ins0[7:0]) & ~ins0[15:8]) == 8'd0;
                if (ins0[21]) cnd = carry;
                else if (ins0[17] && ins0[18]) cnd = ins0[19] ? (pm && dm) : (pm || dm);
                else if (ins0[17]) cnd = pm;
                else if (ins0[18]) cnd = dm;
                else cnd = 1'b1;
                take = ins0[19] ? cnd : !cnd;
                if (!ins0[17] && !ins0[18] && !ins0[21]) take = ins0[19];     // no test: bit 19 (the assemblers' "always" sets it)
                tc_take <= take;
                est <= E_TC_DO;
            end
            E_TC_DO: begin
                if (tc_take) case (ins0[29:27])
                    3'b000: begin dsp <= jmp_tgt; est <= E_FETCH; end
                    3'b001: begin temp <= dsp; dsp <= jmp_tgt; est <= E_FETCH; end
                    3'b010: begin dsp <= temp; est <= E_FETCH; end
                    default:
                        if (ins0[20]) begin intf <= 1'b1; est <= E_FETCH; end                 // INTFLY
                        else begin est <= E_FLUSH; fl_next <= 1'b0; set_ds[2] = 1'b1; end      // INT: SIR
                endcase
                else est <= E_FETCH;
            end

            // ---- memory move, LOAD, STORE: a byte at a time through the read cache and the write buffer
            E_MM_RD: begin
                if (mm_sreg) begin mm_byte <= reg_rd(dnad[6:0]); est <= E_MM_WR; end
                else if (rc_valid && rc_addr == dnad[31:2]) begin mm_byte <= rc_data[8 * dnad[1:0] +: 8]; est <= E_MM_WR; end
                else if (wb_valid && d_idle) wb_out;
                else if (d_idle && !wb_valid) dma_rd(dnad);
                if (d_done && !dm_we) begin
                    rc_valid <= 1'b1; rc_addr <= dnad[31:2]; rc_data <= dm_rdata;
                    mm_byte <= dm_rdata[8 * dnad[1:0] +: 8]; est <= E_MM_WR;
                end
            end
            E_MM_WR: begin
                if (mm_dreg) begin
                    reg_wr_eng(mm_dst[6:0], mm_byte);
                    dnad <= dnad + 32'd1; mm_dst <= mm_dst + 32'd1; dbc <= dbc - 24'd1;
                    est <= (dbc == 24'd1) ? E_FLUSH : E_MM_RD; fl_next <= 1'b1;
                end
                else if (wb_valid && wb_addr != mm_dst[31:2]) begin
                    if (d_idle) wb_out;
                end else if (d_idle) begin
                    wb_put(mm_dst, mm_byte);
                    if (rc_addr == mm_dst[31:2]) rc_valid <= 1'b0;     // the read cache is stale
                    dnad <= dnad + 32'd1; mm_dst <= mm_dst + 32'd1; dbc <= dbc - 24'd1;
                    est <= (dbc == 24'd1) ? E_FLUSH : E_MM_RD; fl_next <= 1'b1;
                end
            end

            // write the buffer back; then the next instruction (fl_next) or the halt
            // (its interrupt already raised)
            E_FLUSH: begin
                if (wb_valid && d_idle) wb_out;
                else if (!wb_valid && d_idle) begin
                    rc_valid <= 1'b0;
                    est <= fl_next ? E_FETCH : E_IDLE;
                end
            end
            default: est <= E_IDLE;
        endcase

        // ---------------------------------------- the interrupt status: registered, then stacked
        q_s0 <= set_s0; q_s1 <= set_s1; q_ds <= set_ds;
        if (q_s0 != 8'd0 || q_s1 != 3'd0 || q_ds != 8'd0) begin
            if (sip || dip) begin
                sist0_pend <= sist0_pend | q_s0; sist1_pend <= sist1_pend | q_s1; dstat_pend <= dstat_pend | q_ds[6:0];
            end else begin
                sist0_st <= sist0_st | q_s0; sist1_st <= sist1_st | q_s1; dstat_st <= dstat_st | q_ds[6:0];
            end
        end
`ifdef NCR_TRACE
        // the bench's trace of the SCRIPTS processor
        if (est == E_DECODE)
            $display("ncr %08X: %08X %08X", dsp - (ins0[31:29] == 3'b110 ? 32'd12 : 32'd8), ins0, dsps);
        if (q_s0 != 8'd0 || q_s1 != 3'd0 || q_ds != 8'd0)
            $display("ncr set dstat %02X sist0 %02X sist1 %01X  (irq %0d istat %02X)", q_ds, q_s0, q_s1, irq, istat);
`endif
    end
end

endmodule
