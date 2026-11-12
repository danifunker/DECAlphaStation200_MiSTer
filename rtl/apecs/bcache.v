// The board cache (the AlphaStation 200's 512 KB Bcache), as a block RAM
// cache on the 21071 model's DRAM port (rtl/apecs/apecs.v d_*), in front of
// the memory (rtl/mister/sdram_ctl.v, or the simulation's model): direct
// mapped, 32-byte lines, 2^LB lines (LB = 13: 256 KB), indexed by the DRAM
// offset, so the bank aliasing and the DMA's accesses need no attention.
//
// The memory always holds the truth: every write goes on to it, and changes
// the cache's copy of the line when there is one. A line read that hits is
// answered from the block RAM (the first quadword two cycles after the
// request, then one a cycle), one that misses is read from the memory and
// kept. A single-quadword read (DMA, the scatter/gather map) is answered on a
// hit and passed on, without being kept, on a miss. A write of a whole line
// (32 byte enables) that misses takes the line. Software cannot see any of it
// (the 21064's BIU_CTL bits are shadows: docs/gaps.md).
//
// d_addr, d_we, d_line, d_be and d_wdata hold while d_req is up (the 21071
// model's rule), so they go to the memory as they are; only the request and
// the answer pass through here. en = 0: the port is wired straight through.
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
    input  wire         s_ack,
    input  wire [63:0]  s_rdata
);
    localparam TW = 22 - LB;            // tag: d_addr[26:LB+5]
    localparam [2:0] S_SWEEP = 3'd0, S_IDLE = 3'd1, S_LOOK = 3'd2, S_HIT = 3'd3, S_RD = 3'd4, S_WR = 3'd5;

    reg  [2:0]    st;
    reg  [LB-1:0] sweep;
    reg  [1:0]    beat;
    reg           m_req, b_ack, upd, take;
    reg  [63:0]   b_rdata;

    wire [LB-1:0] idx = d_addr[LB+4:5];
    wire [TW-1:0] tag = d_addr[26:LB+5];

    // the tags: {valid, tag}
    (* ramstyle = "no_rw_check" *) reg [TW:0] tags [0:(1<<LB)-1];
    reg  [TW:0]   tq;
    wire          fill_ack = st == S_RD && s_ack && d_line;
    wire          t_we = st == S_SWEEP || (fill_ack && beat == 2'd3) || (st == S_WR && take);
    always @(posedge clk) begin
        if (t_we) tags[st == S_SWEEP ? sweep : idx] <= st == S_SWEEP ? {(TW+1){1'b0}} : {1'b1, tag};
        tq <= tags[idx];
    end
    wire          hit = tq[TW] && tq[TW-1:0] == tag;

    // the lines: 32 byte-wide memories
    wire [255:0]  dq;
    genvar b;
    generate for (b = 0; b < 32; b = b + 1) begin : by
        (* ramstyle = "no_rw_check" *) reg [7:0] mem [0:(1<<LB)-1];
        reg  [7:0] q;
        wire       we = (fill_ack && {30'd0, beat} == b / 8) || (st == S_WR && upd && d_be[b]);
        always @(posedge clk) begin
            if (we) mem[idx] <= st == S_RD ? s_rdata[8*(b%8) +: 8] : d_wdata[8*b +: 8];
            q <= mem[idx];
        end
        assign dq[8*b +: 8] = q;
    end endgenerate

    always @(posedge clk) begin
        b_ack <= 1'b0;
        if (rst) begin
            st <= S_SWEEP; sweep <= {LB{1'b0}}; m_req <= 1'b0;
        end else case (st)
        S_SWEEP: begin
            sweep <= sweep + 1'b1;
            if (&sweep) st <= S_IDLE;
        end
        // b_ack: the requester drops d_req a cycle after the last answer
        S_IDLE: if (en && d_req && !b_ack) begin
            m_req <= d_we;              // a write goes on at once
            st <= S_LOOK;
        end
        // the tag and the line of this index are out of the memories
        S_LOOK: begin
            upd  <= hit || &d_be;
            take <= !hit && &d_be;
            beat <= d_line ? 2'd1 : 2'd0;
            if (d_we) st <= S_WR;
            else if (hit) begin
                b_ack <= 1'b1;
                b_rdata <= d_line ? dq[63:0] : dq[64*d_addr[4:3] +: 64];
                st <= d_line ? S_HIT : S_IDLE;
            end else begin
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
        // a miss: the memory's answers go back, a line's quadwords into the cache
        S_RD: if (s_ack) begin
            b_ack <= 1'b1;
            b_rdata <= s_rdata;
            beat <= beat + 2'd1;
            if (!d_line || beat == 2'd3) begin m_req <= 1'b0; st <= S_IDLE; end
        end
        // a write: the memory takes it; the cache's copy changes in the first cycle here
        S_WR: begin
            upd <= 1'b0; take <= 1'b0;
            if (s_ack) begin b_ack <= 1'b1; m_req <= 1'b0; st <= S_IDLE; end
        end
        default: st <= S_IDLE;
        endcase
    end

    assign s_req   = en ? m_req : d_req;
    assign d_ack   = en ? b_ack : s_ack;
    assign d_rdata = en ? b_rdata : s_rdata;
endmodule
