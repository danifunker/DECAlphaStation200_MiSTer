//============================================================================
//
//  DEC AlphaStation 200 - the DECchip 21040 "Tulip" Ethernet LAN controller
//  (on the riser: PCI device 11 = IDSEL AD22, INTA -> PIRQ0), with its
//  Ethernet ID ROM, as DEC's 21040 Hardware Reference Manual (EC-N0752-72)
//  describes it. docs/design/ethernet.md has the design, what SRM's ewa
//  driver and the OS drivers use, and the gaps.
//
//    - PCI header: 1011/0002, class 02 00 00, revision REV (pass 2.x:
//      SRM's ew_driver and NetBSD take rev >= 0x20 as pass 2), CBIO (I/O,
//      128 bytes) and CBMA (memory, 128 bytes) both decode CSR0-CSR15 at
//      offset 8 * n, CFIT (INTA), CFDA (the driver's byte);
//    - CSR0-CSR15: bus mode (SWR, DSL, BLE for data buffers, TAP), poll
//      demands, the list bases, status / interrupt summary / mask (NIS and
//      AIS are the ORs of the unmasked bits; INTA = NIS & NIM | AIS & AIM),
//      operation mode (start/stop, PR, PM, PB, the loopback modes; HP, HO
//      and IF read-only, set by the setup frame's filtering type), missed
//      frames, the address ROM through CSR9 (one byte per read once DN
//      clears, the pointer reset by a write), CSR11, and the SIA (CSR12
//      reports 10BASE-T link pass while the SIA is out of reset and link_up);
//    - the descriptor processes: rings and chains, DSL, two buffers per
//      descriptor, frames over several descriptors, setup frames (perfect
//      16 addresses, 512-bit hash + 1, inverse, hash-only), the transmit
//      padding and CRC, receive descriptor prefetch, RU/TU suspension, the
//      missed frame counter, internal and external loopback (both looped
//      inside the chip: the frame with its CRC into the receive list);
//    - the wire is Main_MiSTer's mailbox (tulip_nb.v, nb_*).
//
//  Frames are stored whole (2 KB transmit and receive buffers); the engine
//  runs one descriptor job at a time over the DMA port (one longword per
//  request). Store-and-forward means no underflow/overflow, collisions,
//  jabber or watchdog conditions; those status bits stay 0.
//
//============================================================================

module tulip21040 #(
    parameter DEVNUM   = 11,            // PCI device number (IDSEL AD22)
    parameter [7:0] REV = 8'h23,        // CFRV<7:0>: step 2, revision 3
    parameter CLK_MHZ  = 100,           // for the transmit automatic poll
    parameter ROM_WAIT = 32,            // clocks per serial ROM byte (DN set meanwhile)
    parameter POLL     = 4096           // mailbox RXW poll period, clocks
) (
    input  wire        clk,
    input  wire        reset,

    // the PCI target bus (docs/design/pci.md 2)
    input  wire        pt_req,
    input  wire  [1:0] pt_cmd,          // 0 configuration, 1 I/O, 2 memory
    input  wire  [4:0] pt_dev,
    input  wire [31:0] pt_addr,
    input  wire  [3:0] pt_be,
    input  wire        pt_we,
    input  wire [31:0] pt_wdata,
    output wire        pt_claim,
    output reg         pt_ack,
    output wire [31:0] pt_rdata,        // valid with pt_ack, else 0

    // DMA (docs/design/pci.md 3): one longword, held until dm_ack
    output reg         dm_req,
    output reg         dm_we,
    output reg  [31:0] dm_addr,
    output reg   [3:0] dm_be,
    output reg  [31:0] dm_wdata,
    input  wire        dm_ack,
    input  wire [31:0] dm_rdata,

    output reg         inta_n,

    // the Ethernet ID ROM's station address, first byte in 47:40
    input  wire [47:0] mac,
    // the medium: 10BASE-T link pass (and AUI carrier)
    input  wire        link_up,

    // Main_MiSTer's mailbox in DDR3 (tulip_nb.v; docs/design/ethernet.md 5)
    output wire        nb_req,
    output wire        nb_we,
    output wire [12:0] nb_addr,
    output wire [63:0] nb_wdata,
    input  wire        nb_ack,
    input  wire [63:0] nb_rdata,
    output wire [47:0] nb_pmac,         // Main's address for the ROM (mailbox word 7)
    output wire        nb_pmac_ok,
    output wire        nb_link          // Main's bridge is up
);

// ==== PCI configuration header ================================================================
reg   [8:0] pci_cmd;                    // bits 8 (SERR), 6 (parity), 2 (master), 1 (memory), 0 (I/O)
reg   [3:0] pci_sts;                    // bits 31-28, write 1 to clear
reg         pci_dpr;                    // bit 24
reg   [7:0] cflt;                       // latency timer
reg  [31:7] cbio, cbma;
reg   [7:0] intl, cfda;
wire        io_on  = pci_cmd[0];
wire        mem_on = pci_cmd[1];

wire cfg_hit = pt_cmd == 2'd0 && pt_dev == DEVNUM[4:0] && pt_addr[10:8] == 3'd0;
wire io_hit  = pt_cmd == 2'd1 && io_on  && pt_addr[31:7] == cbio;
wire mem_hit = pt_cmd == 2'd2 && mem_on && pt_addr[31:7] == cbma;
assign pt_claim = pt_req && (cfg_hit || io_hit || mem_hit);

// the request is registered when accepted (cycle 0), done in cycle 1, acked in cycle 2
reg         h_pend, h_cfg, h_we;
reg   [7:2] h_reg;
reg   [3:0] h_be;
reg  [31:0] h_wd, h_rd;
wire        acc = pt_req && pt_claim && !h_pend && !pt_ack;
assign pt_rdata = pt_ack ? h_rd : 32'd0;

// ==== the Ethernet ID ROM (32 bytes, DEC's station address ROM format) ========================
// 0-5 the address, 6-7 the checksum (big-endian, the DEC algorithm: 16-bit words, doubled and
// added mod 65535), 8-15 bytes 7..0 again, 16-23 bytes 0-7, 24-31 FF 00 55 AA FF 00 55 AA.
reg  [18:0] ck_s;
reg  [16:0] ck_f;
reg  [15:0] ck;
reg  [47:0] mac_q;
always @(posedge clk) begin
    mac_q <= mac;
    ck_s  <= {1'b0, mac_q[47:32], 2'b00} + {2'b00, mac_q[31:16], 1'b0} + {3'b000, mac_q[15:0]};
    ck_f  <= {1'b0, ck_s[15:0]} + {14'd0, ck_s[18:16]};
    ck    <= ck_f >= 17'd65535 ? ck_f[15:0] - 16'd65535 : ck_f[15:0];
end
function [7:0] romb;                    // byte i of bytes 0-7
    input [2:0] i; input [47:0] m; input [15:0] c;
    case (i)
        3'd0: romb = m[47:40]; 3'd1: romb = m[39:32]; 3'd2: romb = m[31:24];
        3'd3: romb = m[23:16]; 3'd4: romb = m[15:8];  3'd5: romb = m[7:0];
        3'd6: romb = c[15:8];  default: romb = c[7:0];
    endcase
endfunction
reg   [4:0] rom_ptr;
reg   [5:0] rom_busy;
wire  [7:0] rom_byte = rom_ptr[4:3] == 2'd3 ? (rom_ptr[0] ? (rom_ptr[1] ? 8'hAA : 8'h00) : (rom_ptr[1] ? 8'h55 : 8'hFF))
                     : rom_ptr[4:3] == 2'd1 ? romb(~rom_ptr[2:0], mac_q, ck)
                     : romb(rom_ptr[2:0], mac_q, ck);

// ==== CSRs ====================================================================================
reg  [18:0] csr0;                       // TAP DAS CAL PBL BLE DSL BAR SWR
reg  [31:0] csr3, csr4;
reg  [13:0] sts;                        // CSR5<13:0> (bit 4 reserved)
reg   [2:0] ts, rs;                     // CSR5<22:20>, <19:17>
reg  [17:0] op;                         // CSR6
reg  [16:0] im;                         // CSR7
reg  [15:0] mfc;                        // CSR8
reg         mfo;
reg  [15:0] csr11, csr13, csr14, csr15;
wire        ble = csr0[7];
wire  [4:0] dsl = csr0[6:2];

localparam [2:0] TS_STOP = 3'd0, TS_FETCH = 3'd1, TS_READ = 3'd3, TS_SETUP = 3'd5, TS_SUSP = 3'd6,
                 TS_CLOSE = 3'd7;
localparam [2:0] RS_STOP = 3'd0, RS_FETCH = 3'd1, RS_WAIT = 3'd3, RS_SUSP = 3'd4, RS_CLOSE = 3'd5,
                 RS_QUEUE = 3'd7;

wire [13:0] sts_on = sts & im[13:0];
wire        nis = |(sts_on & 14'h0045);                         // TI TU RI
wire        ais = |(sts_on & 14'h3FAA);                         // TPS TJT UNF RU RPS RWT AT FD LNF SE
wire [31:0] csr5 = {6'h3F, 3'd0, ts, rs, nis, ais, 1'b0, sts[13:5], 1'b0, sts[3:0]};

// the SIA: out of reset when CSR13<0> (SRL) is set or an auto configuration is selected
wire        sia_on = csr13[0] | csr13[1] | csr13[2];
wire        sia_aui = csr13[3] && !csr13[1];
wire        lkf = sia_on && !sia_aui && !link_up;               // 10BASE-T link fail
wire        ncr = sia_on && !link_up;
wire  [7:0] csr12 = sia_on ? {4'b0011, 1'b1, lkf, ncr, 1'b0} : 8'hC4;
wire        tx_fail = op[11:10] == 2'd0 && (!sia_on || !link_up);
reg         lkf_q;

// ==== buffers =================================================================================
// TX: four byte lanes (written a byte at a time by the engine, read a longword at a time)
reg   [7:0] tbm0 [0:511];
reg   [7:0] tbm1 [0:511];
reg   [7:0] tbm2 [0:511];
reg   [7:0] tbm3 [0:511];
reg         tb_we;
reg  [10:0] tb_wa;
reg   [7:0] tb_wd;
wire  [8:0] tb_ra;
reg  [31:0] tb_q;
always @(posedge clk) begin
    if (tb_we && tb_wa[1:0] == 2'd0) tbm0[tb_wa[10:2]] <= tb_wd;
    if (tb_we && tb_wa[1:0] == 2'd1) tbm1[tb_wa[10:2]] <= tb_wd;
    if (tb_we && tb_wa[1:0] == 2'd2) tbm2[tb_wa[10:2]] <= tb_wd;
    if (tb_we && tb_wa[1:0] == 2'd3) tbm3[tb_wa[10:2]] <= tb_wd;
    tb_q <= {tbm3[tb_ra], tbm2[tb_ra], tbm1[tb_ra], tbm0[tb_ra]};
end
// RX: longwords, written by the mailbox side or the loopback copy, read by the engine
reg  [31:0] rbm [0:511];
wire        rb_we;
wire  [8:0] rb_wa;
wire [31:0] rb_wd;
reg   [8:0] rb_ra;
reg  [31:0] rb_q;
always @(posedge clk) begin
    if (rb_we) rbm[rb_wa] <= rb_wd;
    rb_q <= rbm[rb_ra];
end
// the setup frame's low halves (48 x 16): perfect entries e = words 3e..3e+2, or the hash
// table (words 0-31) and the one physical address (words 39-41)
reg  [15:0] srm [0:47];
reg         sr_we;
reg   [5:0] sr_wa, sr_ra;
reg  [15:0] sr_wd, sr_q;
always @(posedge clk) begin
    if (sr_we) srm[sr_wa] <= sr_wd;
    sr_q <= srm[sr_ra];
end

// ==== the mailbox side ========================================================================
wire        nbt_done, nbr_req, nbr_we, nbr_put;
wire  [8:0] nbt_addr, nbr_addr;
wire [31:0] nbr_data;
wire [10:0] nbr_len;
reg         tx_req, tb_busy, lb_req;
reg  [10:0] tx_len, lb_len;
reg         rx_full;
reg  [10:0] rx_len;
reg   [1:0] rb_own;                     // 0 free, 1 the mailbox side, 2 the loopback copy
reg   [8:0] lb_ra, lb_i;
reg   [1:0] lb_ph;
reg         lb_we;
reg   [8:0] lb_wa;
assign tb_ra = rb_own == 2'd2 ? lb_ra : nbt_addr;
assign rb_we = lb_we || (rb_own == 2'd1 && nbr_we);
assign rb_wa = lb_we ? lb_wa : nbr_addr;
assign rb_wd = lb_we ? tb_q  : nbr_data;
wire   nb_rx_ok = !rx_full && rb_own == 2'd0 && !lb_req && op[11:10] == 2'd0;

tulip_nb #(.POLL(POLL)) u_nb (
    .clk(clk), .reset(reset), .mac(mac_q),
    .nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata),
    .nb_ack(nb_ack), .nb_rdata(nb_rdata),
    .pmac(nb_pmac), .pmac_ok(nb_pmac_ok), .link(nb_link),
    .tx_req(tx_req), .tx_len(tx_len), .tx_done(nbt_done), .tbr_addr(nbt_addr), .tbr_data(tb_q),
    .rx_ok(nb_rx_ok), .rx_req(nbr_req), .rx_gnt(rb_own == 2'd1), .rbw_we(nbr_we), .rbw_addr(nbr_addr),
    .rbw_data(nbr_data), .rx_put(nbr_put), .rx_plen(nbr_len)
);

// ==== the engine ==============================================================================
localparam [5:0] S_IDLE = 6'd0,  S_DMAW = 6'd1,  S_RS0  = 6'd2,  S_RS1  = 6'd3,
                 S_TF0  = 6'd4,  S_TF1  = 6'd5,  S_TF2  = 6'd6,  S_TF3  = 6'd7,  S_TF4 = 6'd8,
                 S_SU0  = 6'd9,  S_SU1  = 6'd10, S_SU2  = 6'd11,
                 S_TC0  = 6'd12, S_TC1  = 6'd13, S_TB2  = 6'd14, S_TEND = 6'd15, S_TPAD = 6'd16,
                 S_TSND = 6'd17, S_TFCS = 6'd18, S_TGO  = 6'd19, S_TCLS = 6'd20, S_TADV = 6'd21,
                 S_RX0  = 6'd22, S_RX1  = 6'd23, S_RX2  = 6'd24, S_RX3  = 6'd25, S_RX4 = 6'd26,
                 S_RX5  = 6'd27, S_RX6  = 6'd28, S_RXH1 = 6'd29, S_RXH2 = 6'd30,
                 S_RXP0 = 6'd31, S_RXP1 = 6'd32, S_RXP2 = 6'd33,
                 S_RXD  = 6'd34, S_RXD1 = 6'd35, S_RXD2 = 6'd36, S_RXD3 = 6'd37, S_RXD4 = 6'd38,
                 S_RXW0 = 6'd39, S_RXW1 = 6'd40, S_RXW2 = 6'd41, S_RXW3 = 6'd42, S_RXW4 = 6'd43,
                 S_RXB2 = 6'd44, S_RXE  = 6'd45, S_RXL1 = 6'd46, S_RXL2 = 6'd47, S_RXC = 6'd48,
                 S_RXF1 = 6'd49, S_RXT  = 6'd50, S_RXDROP = 6'd51;

reg   [5:0] st, ret, b_next, c_next;
reg  [31:0] dmr;                        // the longword read
reg  [31:0] tx_cur, tx_nxt, rx_cur, rx_nxt;
reg  [31:0] td1, td2, td3, rd1, rd2, rd3;
reg   [5:0] su_i;
reg  [31:0] c_addr;                     // the transmit buffer being copied
reg  [10:0] c_cnt;
reg  [10:0] tb_len;                     // bytes in the transmit buffer
reg  [31:0] tx_crc, fcs;
reg   [1:0] fcs_i;
reg         padded;
reg  [31:0] tdes0;
reg         rs_ru;                      // RS0: a host-owned descriptor sets RU (a start; not a poll)
reg         tpd, rpd, swr;              // transmit / receive poll demand, software reset pending
reg  [15:0] tap_cnt;
reg   [3:0] tap_t;
// receive
reg  [31:0] w0;
reg  [47:0] da;
reg         ftype;
reg  [31:0] rx_crc;
reg   [2:0] fi;
reg   [5:0] wi;
reg   [1:0] wk;                         // the half of the entry wi is
reg         em, hit;
reg  [10:0] rx_pos, w_end, b_size;
reg  [31:0] b_addr;
reg         rx_fs;
reg         last_rx;                    // round-robin (CSR0<1>)

wire        tx_on = op[13];
wire        tx_elig;                    // a transmit descriptor job can run
wire        rx_on = op[1];
wire        da_mc = da[40];             // the first byte's low bit
wire        hp = op[0], ho = op[2], invf = op[4];
assign      tx_elig = tx_on && ts != TS_STOP && !tb_busy && (ts != TS_SUSP || tpd);
wire  [8:0] hash = rx_crc[8:0];
wire [31:0] nxt_inc = {25'd0, dsl, 2'b00} + 32'd16;
wire [10:0] rem = rx_len - rx_pos;
wire [10:0] cap = rem <= b_size ? rem : {b_size[10:2], 2'b00};
wire [31:0] rb_sw = ble ? {rb_q[7:0], rb_q[15:8], rb_q[23:16], rb_q[31:24]} : rb_q;
wire [10:0] rx_pos4 = rx_pos + 11'd4;
wire  [3:0] be_v = rx_pos4 <= w_end ? 4'hF : w_end[1:0] == 2'd1 ? 4'h1 : w_end[1:0] == 2'd2 ? 4'h3 : 4'h7;
wire  [3:0] be_sw = ble ? {be_v[0], be_v[1], be_v[2], be_v[3]} : be_v;
wire        rx_tl = rx_len > 11'd1518;
wire        rx_rf = rx_len < 11'd64;
wire [31:0] rdes0_last = {1'b0, 4'd0, rx_len, rx_tl | rx_rf, 1'b0, op[11:10], rx_rf, da_mc, rx_fs, 1'b1,
                          rx_tl, 1'b0, ftype && rx_len >= 11'd14, 5'd0};
wire [15:0] tap_200us = CLK_MHZ * 200;
wire  [3:0] tap_n = csr0[18:17] == 2'd1 ? 4'd1 : csr0[18:17] == 2'd2 ? 4'd4 : 4'd8;

function [31:0] crc8;                   // one byte into the reflected IEEE 802.3 CRC
    input [31:0] c; input [7:0] d;
    integer i; reg [31:0] x;
    begin
        x = c;
        for (i = 0; i < 8; i = i + 1) x = (x[0] ^ d[i]) ? (x >> 1) ^ 32'hEDB88320 : (x >> 1);
        crc8 = x;
    end
endfunction

task dma_rd;
    input [31:0] a; input [5:0] r;
    begin dm_req <= 1'b1; dm_we <= 1'b0; dm_addr <= {a[31:2], 2'b00}; dm_be <= 4'hF; ret <= r; st <= S_DMAW; end
endtask
task dma_wr;
    input [31:0] a; input [31:0] d; input [3:0] be; input [5:0] r;
    begin dm_req <= 1'b1; dm_we <= 1'b1; dm_addr <= {a[31:2], 2'b00}; dm_be <= be; dm_wdata <= d; ret <= r; st <= S_DMAW; end
endtask
// a byte into the transmit buffer (and the CRC)
task tb_put;
    input [7:0] b;
    begin
        if (tb_len < 11'd2040) begin
            tb_we <= 1'b1; tb_wa <= tb_len; tb_wd <= b; tb_len <= tb_len + 11'd1; tx_crc <= crc8(tx_crc, b);
        end
    end
endtask

reg  [13:0] s_set, s_clr;               // CSR5 bits set by the engine / cleared by the host this cycle
reg  [7:0]  c_byte;
integer k;

always @(posedge clk) begin
    s_set = 14'd0; s_clr = 14'd0;
    tb_we <= 1'b0; sr_we <= 1'b0; lb_we <= 1'b0;
    inta_n <= !((nis && im[16]) || (ais && im[15]));

    // ---- the host's accesses: registered in cycle 0, done in cycle 1, acked in cycle 2
    h_pend <= acc;
    if (acc) begin
        h_cfg <= cfg_hit; h_we <= pt_we; h_reg <= pt_cfg_reg(pt_addr, cfg_hit);
        h_be <= pt_be; h_wd <= pt_wdata;
    end
    pt_ack <= h_pend;
    if (h_pend && h_cfg) begin
        if (h_we) case (h_reg)
            6'h01: begin
                if (h_be[0]) pci_cmd[7:0] <= h_wd[7:0] & 8'h47;
                if (h_be[1]) pci_cmd[8]   <= h_wd[8];
                if (h_be[3]) begin pci_sts <= pci_sts & ~h_wd[31:28]; pci_dpr <= pci_dpr & ~h_wd[24]; end
            end
            6'h03: if (h_be[1]) cflt <= h_wd[15:8];
            6'h04: begin
                if (h_be[0]) cbio[7] <= h_wd[7];
                for (k = 1; k < 4; k = k + 1) if (h_be[k]) cbio[8 * k +: 8] <= h_wd[8 * k +: 8];
            end
            6'h05: begin
                if (h_be[0]) cbma[7] <= h_wd[7];
                for (k = 1; k < 4; k = k + 1) if (h_be[k]) cbma[8 * k +: 8] <= h_wd[8 * k +: 8];
            end
            6'h0F: if (h_be[0]) intl <= h_wd[7:0];
            6'h10: if (h_be[1]) cfda <= h_wd[15:8];
            default: ;
        endcase
        case (h_reg)
            6'h00:   h_rd <= 32'h0002_1011;                                         // 21040, DEC
            6'h01:   h_rd <= {pci_sts, 1'b0, 2'b01, pci_dpr, 1'b1, 14'd0, pci_cmd};    // medium DEVSEL, FBB
            6'h02:   h_rd <= {24'h02_0000, REV};                                    // Ethernet controller
            6'h03:   h_rd <= {16'd0, cflt, 8'd0};
            6'h04:   h_rd <= {cbio, 7'h01};                                         // I/O, 128 bytes
            6'h05:   h_rd <= {cbma, 7'h00};                                         // memory, 128 bytes
            6'h0F:   h_rd <= {16'd0, 8'h01, intl};                                  // INTA
            6'h10:   h_rd <= {16'd0, cfda, 8'd0};
            default: h_rd <= 32'd0;
        endcase
    end
    if (h_pend && !h_cfg) begin
        // CSRn at offset 8n; the odd longwords read 0 and ignore writes
        if (h_we && !h_reg[2]) case (h_reg[6:3])
            4'd0: begin csr0 <= h_wd[18:0] & 19'h7FFFE; if (h_wd[0]) swr <= 1'b1; end
            4'd1: tpd <= 1'b1;
            4'd2: rpd <= 1'b1;
            4'd3: begin csr3 <= {h_wd[31:2], 2'b00}; rx_cur <= {h_wd[31:2], 2'b00}; end
            4'd4: begin csr4 <= {h_wd[31:2], 2'b00}; tx_cur <= {h_wd[31:2], 2'b00}; end
            4'd5: s_clr = h_wd[13:0] & 14'h3FEF;
            4'd6: op <= {h_wd[17:5], op[4], h_wd[3], op[2], h_wd[1], op[0]};
            4'd7: im <= h_wd[16:0] & 17'h1BFEF;
            4'd9: begin rom_ptr <= 5'd0; rom_busy <= ROM_WAIT[5:0]; end
            4'd11: csr11 <= h_wd[15:0];
            4'd13: csr13 <= h_wd[15:0];
            4'd14: csr14 <= h_wd[15:0];
            4'd15: csr15 <= h_wd[15:0];
            default: ;
        endcase
        if (h_reg[2]) h_rd <= 32'd0;
        else case (h_reg[6:3])
            4'd0:  h_rd <= {13'h1FFF, csr0};
            4'd3:  h_rd <= csr3;
            4'd4:  h_rd <= csr4;
            4'd5:  h_rd <= csr5;
            4'd6:  h_rd <= {14'h3FFF, op};
            4'd7:  h_rd <= {15'h7FFF, im};
            4'd8:  begin
                h_rd <= {15'h7FFF, mfo, mfc};
                if (!h_we) begin mfc <= 16'd0; mfo <= 1'b0; end
            end
            4'd9:  begin
                if (rom_busy != 6'd0 || h_we) h_rd <= 32'h8000_0000;
                else begin
                    h_rd <= {24'd0, rom_byte};
                    rom_ptr <= rom_ptr + 5'd1; rom_busy <= ROM_WAIT[5:0];
                end
            end
            4'd11: h_rd <= {16'hFFFF, csr11};
            4'd12: h_rd <= {24'hFF_FFFF, csr12};
            4'd13: h_rd <= {16'hFFFF, csr13};
            4'd14: h_rd <= {16'hFFFF, csr14};
            4'd15: h_rd <= {16'hFFFF, csr15};
            default: h_rd <= 32'hFFFF_FFFF;                 // CSR1, CSR2 (write-only), CSR10
        endcase
    end
    if (rom_busy != 6'd0 && !(h_pend && !h_cfg && h_reg[6:3] == 4'd9 && !h_reg[2])) rom_busy <= rom_busy - 6'd1;

    // ---- the link (10BASE-T): a link fail while the SIA runs sets CSR5<12>
    lkf_q <= lkf;
    if (lkf && !lkf_q) s_set[12] = 1'b1;

    // ---- transmit automatic polling while suspended (CSR0<18:17>)
    if (ts != TS_SUSP || csr0[18:17] == 2'd0) begin tap_cnt <= 16'd0; tap_t <= 4'd0; end
    else if (tap_cnt == tap_200us - 16'd1) begin
        tap_cnt <= 16'd0;
        if (tap_t + 4'd1 >= tap_n) begin tap_t <= 4'd0; tpd <= 1'b1; end
        else tap_t <= tap_t + 4'd1;
    end else tap_cnt <= tap_cnt + 16'd1;

    // ---- the frame buffers' handshakes (not touched by a software reset)
    if (nbt_done) begin tx_req <= 1'b0; tb_busy <= 1'b0; end
    if (rb_own == 2'd0 && !rx_full) begin
        if (lb_req) begin rb_own <= 2'd2; lb_i <= 9'd0; lb_ph <= 2'd0; end
        else if (nbr_req) rb_own <= 2'd1;
    end
    if (rb_own == 2'd1 && nbr_put) begin rx_full <= 1'b1; rx_len <= nbr_len; rb_own <= 2'd0; end
    if (rb_own == 2'd2) begin
        // the loopback copy: the transmit buffer (frame + CRC) into the receive buffer
        lb_ph <= lb_ph + 2'd1;
        if (lb_ph == 2'd0) lb_ra <= lb_i;
        if (lb_ph == 2'd2) begin
            lb_we <= 1'b1; lb_wa <= lb_i; lb_ph <= 2'd0; lb_i <= lb_i + 9'd1;
            if ({lb_i, 2'b11} >= lb_len - 11'd1 || lb_len == 11'd0) begin
                rx_full <= 1'b1; rx_len <= lb_len; rb_own <= 2'd0; lb_req <= 1'b0; tb_busy <= 1'b0;
            end
        end
    end

    // ---- the engine
    case (st)
        S_DMAW: if (dm_ack) begin dm_req <= 1'b0; dmr <= dm_rdata; st <= ret; end

        S_IDLE: begin
            if (!rx_on && rs != RS_STOP) begin rs <= RS_STOP; s_set[8] = 1'b1; end            // RPS
            if (!tx_on && ts != TS_STOP) begin ts <= TS_STOP; s_set[1] = 1'b1; end            // TPS
            if (tx_on && ts == TS_STOP) ts <= TS_FETCH;
            if (rs != RS_SUSP) rpd <= 1'b0;
            if (rx_on && rs == RS_STOP) begin
                rs <= RS_FETCH; rs_ru <= 1'b1; dma_rd(rx_cur, S_RS1);
            end else if (rx_full && !(csr0[1] && last_rx && tx_elig)) begin
                last_rx <= 1'b1; st <= S_RX0;
            end else if (rpd && rs == RS_SUSP) begin
                rpd <= 1'b0; rs_ru <= 1'b0; dma_rd(rx_cur, S_RS1);
            end else if (tx_elig) begin
                tpd <= 1'b0; last_rx <= 1'b0; st <= S_TF0;
            end else if (ts != TS_SUSP) tpd <= 1'b0;
        end

        // ---- the receive process starts or is polled: is the current descriptor ours?
        S_RS1: begin
            if (dmr[31]) rs <= RS_WAIT;
            else begin if (rs_ru) s_set[7] = 1'b1; rs <= RS_SUSP; end
            st <= S_IDLE;
        end

        // ---- transmit: the descriptor at tx_cur
        S_TF0: dma_rd(tx_cur, S_TF1);
        S_TF1: if (!dmr[31]) begin
            if (ts != TS_SUSP) s_set[2] = 1'b1;                                     // TU
            ts <= TS_SUSP; st <= S_IDLE;
        end else begin
            ts <= TS_FETCH; dma_rd(tx_cur + 32'd4, S_TF2);
        end
        S_TF2: begin td1 <= dmr; dma_rd(tx_cur + 32'd8, S_TF3); end
        S_TF3: begin td2 <= dmr; dma_rd(tx_cur + 32'd12, S_TF4); end
        S_TF4: begin
            td3 <= dmr;
            tx_nxt <= td1[25] ? csr4 : td1[24] ? dmr : tx_cur + nxt_inc;
            if (td1[27]) begin ts <= TS_SETUP; su_i <= 6'd0; st <= S_SU0; end
            else begin
                ts <= TS_READ;
                if (td1[29]) begin tb_len <= 11'd0; tx_crc <= 32'hFFFF_FFFF; end
                c_addr <= td2; c_cnt <= td1[10:0]; c_next <= S_TB2;
                st <= td1[10:0] != 11'd0 ? S_TC0 : S_TB2;
            end
        end
        // the setup frame: 48 longwords, the low halves into the setup RAM
        S_SU0: dma_rd(td2 + {24'd0, su_i, 2'b00}, S_SU1);
        S_SU1: begin
            sr_we <= 1'b1; sr_wa <= su_i; sr_wd <= ble ? {dmr[23:16], dmr[31:24]} : dmr[15:0];
            su_i <= su_i + 6'd1;
            st <= su_i == 6'd47 ? S_SU2 : S_SU0;
        end
        S_SU2: begin
            // the filtering type (TDES1<28,22>): 00 perfect, 01 hash, 10 inverse, 11 hash-only
            op[0] <= !td1[28] && td1[22];
            op[2] <= td1[28] && td1[22];
            op[4] <= td1[28] && !td1[22];
            if (td1[31]) s_set[0] = 1'b1;
            ts <= TS_CLOSE; dma_wr(tx_cur, 32'h7FFF_FFFF, 4'hF, S_TADV);
        end
        // a buffer into the transmit buffer, byte by byte
        S_TC0: dma_rd(c_addr, S_TC1);
        S_TC1: begin
            case (c_addr[1:0] ^ {2{ble}})
                2'd0: c_byte = dmr[7:0];
                2'd1: c_byte = dmr[15:8];
                2'd2: c_byte = dmr[23:16];
                default: c_byte = dmr[31:24];
            endcase
            tb_put(c_byte);
            c_addr <= c_addr + 32'd1; c_cnt <= c_cnt - 11'd1;
            if (c_cnt == 11'd1) st <= c_next;
            else if (c_addr[1:0] == 2'd3) st <= S_TC0;
        end
        S_TB2: begin
            c_addr <= td3; c_cnt <= td1[21:11]; c_next <= S_TEND;
            st <= (!td1[24] && td1[21:11] != 11'd0) ? S_TC0 : S_TEND;
        end
        S_TEND: begin
            if (!td1[30]) begin ts <= TS_CLOSE; dma_wr(tx_cur, 32'd0, 4'hF, S_TADV); end   // not the last: release it
            else begin padded <= 1'b0; st <= S_TPAD; end
        end
        // pad a short frame to 60 bytes (unless TDES1<23>); a padded frame always gets its CRC
        S_TPAD: if (!td1[23] && tb_len < 11'd60) begin tb_put(8'h00); padded <= 1'b1; end
        else st <= S_TSND;
        S_TSND: begin
            tdes0 <= 32'd0;
            fcs <= ~tx_crc; fcs_i <= 2'd0;
            if (op[11:10] != 2'd0) begin
                // loopback: the frame with its CRC into the receive list
                if (padded || !td1[26]) st <= S_TFCS;
                else st <= S_TGO;
            end else if (tx_fail) begin
                tdes0 <= {16'd0, 1'b1, 3'd0, 2'b11, 7'd0, !sia_aui, 2'd0};               // ES LO NC (LF)
                st <= S_TCLS;
            end else st <= S_TGO;
        end
        S_TFCS: begin
            tb_we <= 1'b1; tb_wa <= tb_len; tb_wd <= fcs[7:0]; tb_len <= tb_len + 11'd1;
            fcs <= {8'd0, fcs[31:8]}; fcs_i <= fcs_i + 2'd1;
            if (fcs_i == 2'd3) st <= S_TGO;
        end
        S_TGO: begin
            tb_busy <= 1'b1;
            if (op[11:10] != 2'd0) begin lb_req <= 1'b1; lb_len <= tb_len; end
            else begin
                tx_req <= 1'b1;
                tx_len <= (td1[26] && !padded && tb_len >= 11'd4) ? tb_len - 11'd4 : tb_len;  // no FCS on the mailbox
            end
            st <= S_TCLS;
        end
        S_TCLS: begin
            if (td1[31]) s_set[0] = 1'b1;                                           // TI
            ts <= TS_CLOSE; dma_wr(tx_cur, tdes0, 4'hF, S_TADV);
        end
        S_TADV: begin tx_cur <= tx_nxt; if (ts != TS_STOP) ts <= TS_FETCH; st <= S_IDLE; end

        // ---- receive: the frame in the receive buffer; the address filter first
        S_RX0: begin
            if (rs == RS_STOP) st <= S_RXDROP;
            else begin rb_ra <= 9'd0; st <= S_RX1; end
        end
        S_RX1: begin rb_ra <= 9'd1; st <= S_RX2; end
        S_RX2: begin w0 <= rb_q; rb_ra <= 9'd3; st <= S_RX3; end
        S_RX3: begin
            da <= {w0[7:0], w0[15:8], w0[23:16], w0[31:24], rb_q[7:0], rb_q[15:8]};
            st <= S_RX4;
        end
        S_RX4: begin
            ftype <= {rb_q[7:0], rb_q[15:8]} > 16'd1500;
            rx_crc <= 32'hFFFF_FFFF; fi <= 3'd0; st <= S_RX5;
        end
        S_RX5: begin
            rx_crc <= crc8(rx_crc, da[47 - 8 * fi -: 8]);
            fi <= fi + 3'd1;
            if (fi == 3'd5) st <= S_RX6;
        end
        S_RX6: begin
            hit <= 1'b0; em <= 1'b0;
            if (rx_rf && !op[3]) st <= S_RXDROP;                                    // a runt
            else if (op[6] || (op[7] && da_mc)) st <= S_RXD;                        // PR, PM
            else if (ho || (hp && da_mc)) begin sr_ra <= {1'b0, hash[8:4]}; st <= S_RXH1; end
            else if (hp) begin wi <= 6'd39; wk <= 2'd0; st <= S_RXP0; end            // the one perfect address
            else begin wi <= 6'd0; wk <= 2'd0; st <= S_RXP0; end
        end
        S_RXH1: st <= S_RXH2;
        S_RXH2: st <= sr_q[hash[3:0]] ? S_RXD : S_RXDROP;
        // the perfect table: three halves an entry
        S_RXP0: begin sr_ra <= wi; st <= S_RXP1; end
        S_RXP1: st <= S_RXP2;
        S_RXP2: begin
            // the setup RAM holds each address as the host wrote it: byte 2k in the low byte
            if (wk == 2'd0) em <= sr_q == da_le3(da, 2'd0);
            else if (wk == 2'd1) em <= em && sr_q == da_le3(da, 2'd1);
            else if (em && sr_q == da_le3(da, 2'd2)) hit <= 1'b1;
            wk <= wk == 2'd2 ? 2'd0 : wk + 2'd1;
            if (wi == 6'd47 || (hp && wi == 6'd41)) st <= S_RXT;
            else begin wi <= wi + 6'd1; st <= S_RXP0; end
        end
        S_RXT: st <= (hit ^ (invf && !hp)) ? S_RXD : S_RXDROP;
        S_RXDROP: begin rx_full <= 1'b0; st <= S_IDLE; end

        // the frame is ours: the current descriptor
        S_RXD: begin rx_pos <= 11'd0; rx_fs <= 1'b1; dma_rd(rx_cur, S_RXD1); end
        S_RXD1: if (!dmr[31]) begin
            // host-owned: suspended, the frame missed
            if (rs != RS_SUSP) s_set[7] = 1'b1;
            rs <= RS_SUSP;
            mfc <= mfc + 16'd1; if (mfc == 16'hFFFF) mfo <= 1'b1;
            st <= S_RXDROP;
        end else begin rs <= RS_QUEUE; dma_rd(rx_cur + 32'd4, S_RXD2); end
        S_RXD2: begin rd1 <= dmr; dma_rd(rx_cur + 32'd8, S_RXD3); end
        S_RXD3: begin rd2 <= dmr; dma_rd(rx_cur + 32'd12, S_RXD4); end
        S_RXD4: begin
            rd3 <= dmr;
            rx_nxt <= rd1[25] ? csr3 : rd1[24] ? dmr : rx_cur + nxt_inc;
            b_addr <= rd2; b_size <= rd1[10:0]; b_next <= S_RXB2; st <= S_RXW0;
        end
        // a buffer: cap bytes of the frame (a multiple of 4 unless the frame ends in it)
        S_RXW0: begin
            if (b_size == 11'd0 || rem == 11'd0) st <= b_next;
            else begin w_end <= rx_pos + cap; st <= S_RXW1; end
        end
        S_RXW1: begin rb_ra <= rx_pos[10:2]; st <= S_RXW2; end
        S_RXW2: st <= S_RXW3;
        S_RXW3: dma_wr(b_addr, rb_sw, be_sw, S_RXW4);
        S_RXW4: begin
            b_addr <= b_addr + 32'd4;
            if (rx_pos4 >= w_end) begin rx_pos <= w_end; st <= b_next; end
            else begin rx_pos <= rx_pos4; st <= S_RXW1; end
        end
        S_RXB2: begin
            b_addr <= rd3; b_size <= rd1[21:11]; b_next <= S_RXE;
            st <= rd1[24] ? S_RXE : S_RXW0;
        end
        S_RXE: begin
            if (rx_pos >= rx_len) begin rs <= RS_CLOSE; dma_wr(rx_cur, rdes0_last, 4'hF, S_RXC); end
            else dma_rd(rx_nxt, S_RXL1);                // more frame: is the next descriptor ours?
        end
        S_RXL1: if (dmr[31]) begin
            // release this one (FS if it was the first), go on in the next
            dma_wr(rx_cur, {22'd0, rx_fs, 9'd0}, 4'hF, S_RXL2);
        end else begin
            // truncated: LS, LE, ES; the receive process suspends
            dma_wr(rx_cur, {1'b0, 4'd0, rx_len, 1'b1, 1'b1, op[11:10], 1'b0, da_mc, rx_fs, 1'b1, 8'd0}, 4'hF, S_RXC);
            s_set[7] = 1'b1;
        end
        S_RXL2: begin rx_cur <= rx_nxt; rx_fs <= 1'b0; dma_rd(rx_nxt, S_RXD1); end
        S_RXC: begin
            s_set[6] = 1'b1;                                                        // RI
            rx_full <= 1'b0; rx_cur <= rx_nxt;
            dma_rd(rx_nxt, S_RXF1);                     // prefetch: the next descriptor ours?
        end
        S_RXF1: begin
            if (dmr[31]) rs <= RS_WAIT;
            else begin if (rs != RS_SUSP) s_set[7] = 1'b1; rs <= RS_SUSP; end
            st <= S_IDLE;
        end

        default: st <= S_IDLE;
    endcase

    sts <= (sts & ~s_clr) | s_set;

    // ---- software reset (CSR0<0>), once no DMA is out; the configuration stays
    if (swr && !dm_req) begin
        swr <= 1'b0; st <= S_IDLE;
        csr0 <= 19'h00000; sts <= 14'd0; ts <= TS_STOP; rs <= RS_STOP;
        op <= 18'h00040; im <= 17'd0; mfc <= 16'd0; mfo <= 1'b0;
        csr11 <= 16'h0000; csr13 <= 16'h0000; csr14 <= 16'hFFFF; csr15 <= 16'h0000;
        tpd <= 1'b0; rpd <= 1'b0; rom_ptr <= 5'd0; rom_busy <= 6'd0;
    end
    if (reset) begin
        pt_ack <= 1'b0; h_pend <= 1'b0; inta_n <= 1'b1;
        pci_cmd <= 9'd0; pci_sts <= 4'd0; pci_dpr <= 1'b0; cflt <= 8'd0;
        cbio <= 25'd0; cbma <= 25'd0; intl <= 8'd0; cfda <= 8'd0;
        dm_req <= 1'b0; dm_we <= 1'b0; st <= S_IDLE; swr <= 1'b0;
        csr0 <= 19'h00000; csr3 <= 32'd0; csr4 <= 32'd0; rx_cur <= 32'd0; tx_cur <= 32'd0;
        sts <= 14'd0; ts <= TS_STOP; rs <= RS_STOP;
        op <= 18'h00040; im <= 17'd0; mfc <= 16'd0; mfo <= 1'b0;
        csr11 <= 16'h0000; csr13 <= 16'h0000; csr14 <= 16'hFFFF; csr15 <= 16'h0000;
        tpd <= 1'b0; rpd <= 1'b0; rom_ptr <= 5'd0; rom_busy <= 6'd0; lkf_q <= 1'b0;
        tx_req <= 1'b0; tb_busy <= 1'b0; lb_req <= 1'b0; rx_full <= 1'b0; rb_own <= 2'd0;
        tb_len <= 11'd0; last_rx <= 1'b0;
    end
end

// the configuration register number (config) or the CSR offset bits 6:2 (I/O, memory)
function [7:2] pt_cfg_reg;
    input [31:0] a; input c;
    pt_cfg_reg = c ? a[7:2] : {1'b0, a[6:2]};
endfunction

// halfword k of the destination as the setup frame stores it (byte 2k in the low byte)
function [15:0] da_le3;
    input [47:0] d; input [1:0] hk;
    case (hk)
        2'd0: da_le3 = {d[39:32], d[47:40]};
        2'd1: da_le3 = {d[23:16], d[31:24]};
        default: da_le3 = {d[7:0], d[15:8]};
    endcase
endfunction

endmodule
