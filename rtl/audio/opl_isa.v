// The sound card's FM synthesiser at 388h-38Bh (docs/design/audio.md): the
// manual's "YMF562" (most likely a YMF262 OPL3), here JTOPL's OPL2 (YM3812,
// rtl/audio/jtopl, jotego, GPL-3) behind the OPL3's ports. Ported to
// Verilog-2001 from the user's IBM RS/6000 core (IBMRS6K7248_opl.sv).
//
//   388h  index (W), status (R)     389h  data (W)
//   38Ah  bank 1 index (W)          38Bh  bank 1 data (W)
//
// Bank 0 goes to the OPL2: nine 2-operator voices, rhythm, timers. Bank 1's
// writes (the OPL3's second half) are dropped. The status is the OPL2's
// (bits 2:1 set, jtopl's dout), so OPL3 detection (status & 06h == 0) finds
// an OPL2 and software uses it as one. Reads of 389h/38Bh give FFh.
//
// The chip runs at 3.579545 MHz (a clock enable). Its writes go through a
// 64-entry queue and reach it as it can take them (3.3 us after an index,
// 23 us after data), so software that paces its writes for a slower bus
// loses none.
module opl_isa #(
    parameter CLK_HZ = 100000000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output wire        claim,
    output wire  [7:0] io_dout,

    output reg  signed [15:0] snd
);
    localparam [63:0] INC64 = (64'd3579545 << 32) / CLK_HZ;
    localparam [31:0] INC = INC64[31:0];
    localparam [31:0] GAP_I32 = CLK_HZ / 300000;      // 3.3 us
    localparam [31:0] GAP_D32 = CLK_HZ / 43000;       // 23 us
    localparam [15:0] GAP_IDX = GAP_I32[15:0];
    localparam [15:0] GAP_DAT = GAP_D32[15:0];

    assign claim = io_addr[15:2] == 14'h00E2;          // 388h-38Bh
    wire wr = io_wr && claim && !io_addr[1];           // bank 0 only

    reg [31:0] acc;
    reg        cen;
    always @(posedge clk) {cen, acc} <= {1'b0, acc} + {1'b0, INC};

    // the queue: {a0, byte}
    reg  [8:0] q [0:63];
    reg  [5:0] q_r, q_w;
    reg [15:0] gap;
    reg        w_go, w_a0, pop;
    reg  [7:0] w_d;
    always @(posedge clk) if (wr) q[q_w] <= {io_addr[0], io_din};
    always @(posedge clk) begin
        w_go <= 1'b0;
        pop  <= 1'b0;
        if (wr) q_w <= q_w + 6'd1;
        if (gap != 16'd0) gap <= gap - 16'd1;
        else if (pop) begin
            w_go <= 1'b1;                              // {w_a0, w_d} read last clock
            gap  <= w_a0 ? GAP_DAT : GAP_IDX;
        end else if (q_r != q_w) begin
            {w_a0, w_d} <= q[q_r];
            q_r <= q_r + 6'd1;
            pop <= 1'b1;
        end
        if (rst) begin q_r <= 6'd0; q_w <= 6'd0; gap <= 16'd0; end
    end

    // the chip's reset: at least 6 cen periods
    reg [7:0] rcnt;
    always @(posedge clk) begin
        if (rst) rcnt <= 8'd0;
        else if (cen && !rcnt[7]) rcnt <= rcnt + 8'd1;
    end

    wire [7:0] dout;
    wire signed [15:0] snd_w;
`ifdef SIM_NOFM
    // the system simulation without the FM synthesizer (speed): status 06h-clear, silence
    assign dout = 8'h06; assign snd_w = 16'sd0;
`else
    jtopl2 u_opl (
        .rst(!rcnt[7]), .clk(clk), .cen(cen),
        .din(w_d), .addr(w_a0), .cs_n(!w_go), .wr_n(!w_go),
        .dout(dout), .irq_n(), .snd(snd_w), .sample()
    );
`endif

    reg [7:0] st_q;
    always @(posedge clk) begin
        st_q <= dout;
        snd  <= snd_w;
    end
    assign io_dout = io_addr[0] ? 8'hFF : st_q;
endmodule
