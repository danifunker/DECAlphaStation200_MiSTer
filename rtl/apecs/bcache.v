// The board cache (the AlphaStation 200's 512 KB Bcache), as a block RAM
// cache on the 21071 model's DRAM port (rtl/apecs/apecs.v d_*), in front of
// the memory (rtl/mister/sdram_ctl.v, or the simulation's model): direct
// mapped, 32-byte lines, 2^LB lines (LB = 13: 256 KB), indexed by the DRAM
// offset, so the bank aliasing needs no attention.
//
// Write-back, as the real Bcache: every access to the DRAM passes through
// here (the CPU's and the PCI masters' alike), so the cache's copy of a line
// is the truth and nothing else has to look at it. A write that hits changes
// the line and marks it dirty; a write of a whole line (32 byte enables) that
// misses takes the line, dirty; a partial write that misses goes on to the
// memory and the cache keeps nothing. A line read that hits is answered from
// the block RAM (the first quadword two cycles after the request, then one a
// cycle), one that misses is read from the memory and kept. A single-quadword
// read (DMA, the scatter/gather map) is answered on a hit and passed on,
// without being kept, on a miss. A dirty line that a line read or a
// whole-line write replaces moves to the victim buffer (one line), so the
// read goes to the memory first; the buffer goes back (a whole-line write)
// as soon as the port is idle. A request for the buffered line, and a second
// victim while the buffer is full, write it back first (a guard: the buffer
// goes back in the cycle after the answer that filled it, before the
// requester can ask again, so tb_bcache never reaches either).
// A reset (the machine's: power-up, the OSD) drops the cache's contents, as
// it starts the machine from nothing. Software cannot see any of it (the
// 21064's BIU_CTL bits are shadows: docs/gaps.md).
//
// d_addr, d_we, d_line, d_be and d_wdata hold while d_req is up (the 21071
// model's rule); s_* are them, or the victim buffer going back (vict). The
// memory takes a request when s_req is up and it has dropped since the last
// answer (rtl/mister/sdram_ctl.v), and copies a write when it acknowledges it.
// en = 0: the port is wired straight through.
//
// After reset the valid bits are swept (2^LB cycles), requests wait.
module bcache #(
    parameter LB = 13
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,             // static (the OSD's setting, latched at reset)

    input  wire         d_req,
    input  wire         d_we,
    input  wire         d_line,
    input  wire [26:3]  d_addr,
    input  wire [31:0]  d_be,
    input  wire [255:0] d_wdata,
    output wire         d_ack,
    output wire [63:0]  d_rdata,

    output wire         s_req,
    output wire         s_we,
    output wire         s_line,
    output wire [26:3]  s_addr,
    output wire [31:0]  s_be,
    output wire [255:0] s_wdata,
    input  wire         s_ack,
    input  wire [63:0]  s_rdata
);
    localparam TW = 22 - LB;            // tag: d_addr[26:LB+5]
    localparam [2:0] S_SWEEP = 3'd0, S_IDLE = 3'd1, S_LOOK = 3'd2, S_HIT = 3'd3, S_RD = 3'd4,
                     S_WR = 3'd5, S_WT = 3'd6, S_VIC = 3'd7;

    reg  [2:0]    st;
    reg  [LB-1:0] sweep;
    reg  [1:0]    beat;
    reg           m_req, b_ack, vict;
    reg  [63:0]   b_rdata;
    // the victim buffer
    reg           vb_v;
    reg  [26:5]   vb_a;
    reg  [255:0]  vb_d;
    wire          vb_hit = vb_v && vb_a == d_addr[26:5];

    wire [LB-1:0] idx = d_addr[LB+4:5];
    wire [TW-1:0] tag = d_addr[26:LB+5];

    // the tags: {valid, dirty, tag}
    (* ramstyle = "no_rw_check" *) reg [TW+1:0] tags [0:(1<<LB)-1];
    reg  [TW+1:0] tq;
    wire          fill_ack = st == S_RD && s_ack && d_line;
    wire          t_we = st == S_SWEEP || (fill_ack && beat == 2'd3) || st == S_WR;
    wire [TW+1:0] t_wd = st == S_SWEEP ? {(TW+2){1'b0}} : {1'b1, st == S_WR, tag};
    always @(posedge clk) begin
        if (t_we) tags[st == S_SWEEP ? sweep : idx] <= t_wd;
        tq <= tags[idx];
    end
    wire          hit   = tq[TW+1] && tq[TW-1:0] == tag;
    wire          dirty = tq[TW+1] && tq[TW];        // the line in the cache now (a victim when !hit)

    // the lines: 32 byte-wide memories
    wire [255:0]  dq;
    genvar b;
    generate for (b = 0; b < 32; b = b + 1) begin : by
        (* ramstyle = "no_rw_check" *) reg [7:0] mem [0:(1<<LB)-1];
        reg  [7:0] q;
        wire       we = (fill_ack && {30'd0, beat} == b / 8) || (st == S_WR && d_be[b]);
        always @(posedge clk) begin
            if (we) mem[idx] <= st == S_RD ? s_rdata[8*(b%8) +: 8] : d_wdata[8*b +: 8];
            q <= mem[idx];
        end
        assign dq[8*b +: 8] = q;
    end endgenerate

    always @(posedge clk) begin
        b_ack <= 1'b0;
        if (rst) begin
            st <= S_SWEEP; sweep <= {LB{1'b0}}; m_req <= 1'b0; vict <= 1'b0; vb_v <= 1'b0;
        end else case (st)
        S_SWEEP: begin
            sweep <= sweep + 1'b1;
            if (&sweep) st <= S_IDLE;
        end
        // b_ack: the requester drops d_req a cycle after the last answer; an idle port writes
        // the victim buffer back
        S_IDLE: if (en && d_req && !b_ack) st <= S_LOOK;
                else if (vb_v) begin vict <= 1'b1; m_req <= 1'b1; st <= S_VIC; end
        // the tag and the line of this index are out of the memories
        S_LOOK: begin
            beat <= d_line ? 2'd1 : 2'd0;
            if (vb_hit || (vb_v && !hit && dirty && (d_line || &d_be))) begin
                vict <= 1'b1; m_req <= 1'b1; st <= S_VIC;   // the buffer first, then here again
            end else if (d_we) begin
                if (hit) st <= S_WR;
                else if (&d_be) begin
                    if (dirty) begin vb_v <= 1'b1; vb_a <= {tq[TW-1:0], idx}; vb_d <= dq; end
                    st <= S_WR;
                end else begin m_req <= 1'b1; st <= S_WT; end
            end else if (hit) begin
                b_ack <= 1'b1;
                b_rdata <= d_line ? dq[63:0] : dq[64*d_addr[4:3] +: 64];
                st <= d_line ? S_HIT : S_IDLE;
            end else begin
                if (d_line && dirty) begin vb_v <= 1'b1; vb_a <= {tq[TW-1:0], idx}; vb_d <= dq; end
                m_req <= 1'b1;
                beat <= 2'd0;
                st <= S_RD;
            end
        end
        S_HIT: begin
            b_ack <= 1'b1;
            b_rdata <= dq[64*beat +: 64];
            beat <= beat + 2'd1;
            if (beat == 2'd3) st <= S_IDLE;
        end
        // the victim buffer goes back (the memory copies it with its answer), then the request
        // that waited for it looks again (the request to the memory drops for that cycle)
        S_VIC: if (s_ack) begin
            vict <= 1'b0; m_req <= 1'b0; vb_v <= 1'b0;
            st <= (en && d_req && !b_ack) ? S_LOOK : S_IDLE;
        end
        // a miss: the memory's answers go back, a line's quadwords into the cache
        S_RD: if (s_ack) begin
            b_ack <= 1'b1;
            b_rdata <= s_rdata;
            beat <= beat + 2'd1;
            if (!d_line || beat == 2'd3) begin m_req <= 1'b0; st <= S_IDLE; end
        end
        // a write into the cache (a hit, or a whole line taken): the bytes and the dirty tag
        S_WR: begin
            b_ack <= 1'b1;
            st <= S_IDLE;
        end
        // a partial write that missed: the memory takes it
        S_WT: if (s_ack) begin b_ack <= 1'b1; m_req <= 1'b0; st <= S_IDLE; end
        default: st <= S_IDLE;
        endcase
    end

    assign s_req   = en ? m_req : d_req;
    assign s_we    = d_we || vict;
    assign s_line  = d_line && !vict;
    assign s_addr  = vict ? {vb_a, 2'b00} : d_addr;
    assign s_be    = vict ? 32'hFFFF_FFFF : d_be;
    assign s_wdata = vict ? vb_d : d_wdata;
    assign d_ack   = en ? b_ack : s_ack;
    assign d_rdata = en ? b_rdata : s_rdata;
endmodule
