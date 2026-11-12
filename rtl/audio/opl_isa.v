// The sound card's FM synthesiser at 388h-38Bh (docs/design/audio.md): the
// manual's "YMF562" (most likely a YMF262 OPL3), here Greg Taylor's OPL3 FPGA
// (rtl/audio/opl3_fpga, LGPL-3, SystemVerilog, as in ao486_MiSTer 628ddbc,
// unchanged) behind the card's ports.
//
//   388h  index (W), status (R)     389h  data (W)
//   38Ah  bank 1 index (W)          38Bh  bank 1 data (W)
//
// The status is the OPL3's (bits 2:1 clear), so software finds an OPL3 and
// uses both banks: 18 two-operator voices or six of four operators, stereo.
// Reads of 389h-38Bh give FFh.
//
// The chip runs in clk_audio (24.576 MHz, a sample every 494 clocks: 49.7
// kHz). Writes go into its own 64-entry queue between the clocks and it takes
// one per clock of its own, so they need no pacing here. Its status comes
// back through synchronisers.
//
// The chip's samples are joined by straight lines on the way out, so the mix
// takes its 48 kHz from between them: held samples put images of every
// partial 1.7 kHz to either side of it (measured on the board with the OPL2
// that was here before, -20 dB at 4.7 kHz).
module opl_isa #(
    parameter CLK_HZ = 100000000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clk_audio,                      // 24.576 MHz

    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output wire        claim,
    output wire  [7:0] io_dout,

    output reg  signed [15:0] snd_l,
    output reg  signed [15:0] snd_r
);
    assign claim = io_addr[15:2] == 14'h00E2;          // 388h-38Bh
    wire wr = io_wr && claim;

    // An OPL3 that has not been switched to its new mode (bank 1, register 05h, bit 0) is an
    // OPL2 at either register pair: an index written at 38Ah selects the first bank, except
    // 05h itself. NT 4.0's synthesizer driver tells the chips apart by this: it starts timer 1
    // through 38Ah/38Bh, expects the flag at 388h, then sets NEW and expects the same writes
    // to do nothing. The chip below takes 38Ah as bank 1 always, so the bank is chosen here.
    reg       newm, ix_b1, ix_05;
    wire      b1 = io_addr[1] && (newm || io_din == 8'h05);
    always @(posedge clk) begin
        if (wr && !io_addr[0]) begin ix_b1 <= b1; ix_05 <= io_din == 8'h05; end
        if (wr && io_addr[0] && ix_b1 && ix_05) newm <= io_din[0];
        if (rst) begin newm <= 1'b0; ix_b1 <= 1'b0; ix_05 <= 1'b0; end
    end

    wire  [7:0] dout;
    wire        smp;
    wire signed [15:0] smp_l, smp_r;
`ifdef SIM_NOFM
    // the system simulation without the FM synthesizer (speed): an idle OPL3's status, silence
    assign dout = 8'h00; assign smp = 1'b0; assign smp_l = 16'sd0; assign smp_r = 16'sd0;
`else
    // the chip registers its inputs, takes a write at the strobe's start and gives the status
    // while the address it saw a clock before was 0: the address is the bus's for a write only
    opl3 u_opl (
        .clk(clk_audio), .clk_host(clk), .clk_dac(1'b0), .ic_n(!rst),
        .cs_n(!claim), .rd_n(!io_rd), .wr_n(!io_wr),
        .address(wr ? {b1, io_addr[0]} : 2'b00), .din(io_din), .dout(dout),
        .sample_valid(smp), .sample_l(smp_l), .sample_r(smp_r), .led(), .irq_n()
    );
`endif

    reg       wr_q;
    reg [7:0] st_q;
    always @(posedge clk) begin
        wr_q <= wr;
        if (!wr_q) st_q <= dout;
    end
    assign io_dout = io_addr[1:0] == 2'b00 ? st_q : 8'hFF;

    // the samples into clk: held with a toggle in clk_audio, taken two clocks after the
    // toggle is seen
    reg               a_tgl;
    reg signed [15:0] a_l, a_r;
    always @(posedge clk_audio) if (smp) begin
        a_tgl <= !a_tgl;
        a_l   <= smp_l;
        a_r   <= smp_r;
    end
    reg [2:0] tg;
    always @(posedge clk) tg <= {tg[1:0], a_tgl};
    wire nw = tg[2] ^ tg[1];

    // the line from the sample before (s0) to the newest (s0 + ds); ph runs 0 to 2^28 over the
    // chip's sample period
    localparam [63:0] PINC64 = (64'd24576000 << 28) / (64'd494 * CLK_HZ);
    localparam [28:0] PINC = PINC64[28:0];
    reg signed [15:0] l0, l1, l0_q, r0, r1, r0_q;
    reg signed [16:0] dl, dr;
    reg        [28:0] ph;
    reg signed [28:0] pl, pr;
    wire       [10:0] frac = ph[28] ? 11'h7FF : ph[27:17];
    wire signed [17:0] ln_l = {{2{l0_q[15]}}, l0_q} + pl[28:11];
    wire signed [17:0] ln_r = {{2{r0_q[15]}}, r0_q} + pr[28:11];
    always @(posedge clk) begin
        if (nw) begin
            l0 <= l1; l1 <= a_l; dl <= {a_l[15], a_l} - {l1[15], l1};
            r0 <= r1; r1 <= a_r; dr <= {a_r[15], a_r} - {r1[15], r1};
            ph <= 29'd0;
        end else if (!ph[28]) ph <= ph + PINC;
        pl    <= dl * $signed({1'b0, frac});
        pr    <= dr * $signed({1'b0, frac});
        l0_q  <= l0;
        r0_q  <= r0;
        snd_l <= ln_l[15:0];
        snd_r <= ln_r[15:0];
        if (rst) begin
            l0 <= 16'sd0; l1 <= 16'sd0; dl <= 17'sd0; r0 <= 16'sd0; r1 <= 16'sd0; dr <= 17'sd0; ph <= 29'd0;
        end
    end
endmodule
