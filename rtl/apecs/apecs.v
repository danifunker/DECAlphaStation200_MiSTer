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
//   1.C000.0000 - 1.DFFF.FFFF  PCI sparse I/O: ISA port = PA<28:5>, size
//                              = PA<4:3> (0 byte; the others are passed as
//                              a byte access of the low lane for now); data
//                              in byte lane port<1:0> of the longword
//   everything else            reads all ones, writes dropped (STUB: PCI
//                              memory/config spaces, IACK; the 21071-DA)
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

    // CPU
    input  wire        c_req,
    input  wire        c_we,
    input  wire [33:3] c_addr,
    input  wire  [7:0] c_be,
    input  wire [63:0] c_wdata,
    output reg         c_ack,
    output reg  [63:0] c_rdata,

    // DRAM (128 MB)
    output reg         d_req,
    output reg         d_we,
    output reg  [26:3] d_addr,
    output reg   [7:0] d_be,
    output reg  [63:0] d_wdata,
    input  wire        d_ack,
    input  wire [63:0] d_rdata,

    // flash + DROM bytes (flashbus offset)
    output reg         f_req,
    output reg         f_we,
    output reg  [20:0] f_addr,
    output reg   [7:0] f_wdata,
    input  wire        f_ack,
    input  wire  [7:0] f_rdata,

    // ISA I/O (through the 82378, later): byte accesses
    output reg         i_req,
    output reg         i_we,
    output reg  [15:0] i_addr,
    output reg   [7:0] i_wdata,
    input  wire        i_ack,
    input  wire  [7:0] i_rdata
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
    localparam S_IDLE = 3'd0, S_DRAM = 3'd1, S_FB = 3'd2, S_ISA = 3'd3, S_LR1 = 3'd4, S_LR2 = 3'd5;
    reg [2:0] st;
    reg [7:0] nvram [0:8191];
    reg [7:0] nv_q;
    always @(posedge clk) begin
        ca_q <= ca[ca_a]; if (ca_we) ca[ca_a] <= ca_wd;
        da_q <= da[da_a]; if (da_we) da[da_a] <= da_wd;
        nv_q <= nvram[nv_a]; if (nv_we) nvram[nv_a] <= nv_wd;
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

    always @(posedge clk) begin
        c_ack <= 1'b0;
        ca_we <= 1'b0; da_we <= 1'b0; nv_we <= 1'b0;
        if (rst) begin
            st <= S_IDLE; d_req <= 1'b0; f_req <= 1'b0; i_req <= 1'b0; leds <= 8'hFF;
            for (k = 0; k < 3; k = k + 1) begin bcnfg[k] <= 9'd0; bbase[k] <= 16'd0; end
        end else case (st)
        S_IDLE: if (c_req && !c_ack) begin
            if (pa[33:32] == 2'd0) begin
                // ---------------------------------------- memory
                if (bank_hit && isz != 28'd0) begin
                    d_req <= 1'b1; d_we <= c_we; d_addr <= doff[26:3];
                    d_be <= c_be; d_wdata <= c_wdata;
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
                da_a <= pa[11:5]; da_we <= c_we;
                da_wd <= pa[11:5] == 7'h00 ? (wlw & 32'hFFFF00FF & ~32'h00000060) : wlw;   // DCSR: error bits RW1C
                lsel <= 2'd1; st <= S_LR1;
            end else if (pa[33:29] == 5'b01110) begin
                // ---------------------------------------- PCI sparse I/O -> ISA
                i_req <= 1'b1; i_we <= c_we; i_addr <= pa[20:5];
                i_wdata <= wlw[8*pa[6:5] +: 8];
                st <= S_ISA;
            end else begin
                c_rdata <= {64{1'b1}}; c_ack <= 1'b1;
            end
        end
        // a CSR/NVRAM write lands at the S_IDLE->S_LR1 edge's next edge; the
        // read (old data for a write, which software does not rely on) arrives in S_LR2
        S_LR1: st <= S_LR2;
        S_LR2: begin
            c_rdata <= lsel == 2'd0 ? lw2q(ca_q) : lsel == 2'd1 ? lw2q(da_q) : lw2q({24'd0, nv_q});
            c_ack <= 1'b1; st <= S_IDLE;
        end
        S_DRAM: if (d_ack) begin
            d_req <= 1'b0;
            c_rdata <= d_rdata; c_ack <= 1'b1; st <= S_IDLE;
        end
        S_FB: if (f_ack) begin
            f_req <= 1'b0;
            c_rdata <= lw2q({24'd0, f_rdata}); c_ack <= 1'b1; st <= S_IDLE;
        end
        S_ISA: if (i_ack) begin
            i_req <= 1'b0;
            c_rdata <= lw2q({4{i_rdata}}); c_ack <= 1'b1; st <= S_IDLE;
        end
        default: st <= S_IDLE;
        endcase
    end
endmodule
