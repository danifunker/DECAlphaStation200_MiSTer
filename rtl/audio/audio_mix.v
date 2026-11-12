// The audio mix (docs/design/audio.md), in the system clock: the WSS codec's
// PCM, the OPL's FM (stereo), the CD-ROM's audio and the PC speaker, summed and
// saturated to signed 16-bit stereo at 48 kHz.
//
// Every source is held (zero-order) between its own samples: the codec's at
// its rate, the OPL's at 49.7 kHz, the CD's 44.1 kHz strobe. At each output
// period (a 48 kHz phase accumulator) the held values are summed. The
// speaker (one bit, the 8254's counter 2 through port 61h) is averaged over
// the period: the clocks it was high, scaled to 0..SPK_LVL, so its square
// waves come out without the 100 MHz edges aliasing. mute[3:0] silences a
// source (0 WSS, 1 OPL, 2 CD, 3 speaker); all zero is everything on.
//
// out_l/out_r change only at the period, together with out_tgl (toggles), so
// audio_cdc.v can take them into CLK_AUDIO.
module audio_mix #(
    parameter CLK_HZ  = 100000000,
    parameter SPK_LVL = 8192                   // the speaker's full level
) (
    input  wire        clk,
    input  wire        rst,

    input  wire signed [15:0] wss_l,
    input  wire signed [15:0] wss_r,
    input  wire signed [15:0] opl_l,
    input  wire signed [15:0] opl_r,
    input  wire signed [15:0] cd_l,
    input  wire signed [15:0] cd_r,
    input  wire        cd_stb,
    input  wire        spk,
    input  wire  [3:0] mute,

    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r,
    output reg         out_tgl
);
    localparam [27:0] FS    = 28'd48000;
    localparam [27:0] CLKV  = CLK_HZ;
    localparam        PER   = CLK_HZ / 48000;              // clocks per output period
    localparam [31:0] SPK_K = (SPK_LVL * 65536) / PER;      // high clocks to level, Q16

    // the 48 kHz period
    reg  [27:0] ph;
    reg         tick;
    wire [27:0] p1 = ph + FS;
    wire [27:0] p2 = p1 - CLKV;
    always @(posedge clk) begin
        tick <= !p2[27];
        ph   <= p2[27] ? p1 : p2;
        if (rst) begin ph <= 28'd0; tick <= 1'b0; end
    end

    // the held inputs
    reg signed [15:0] cdh_l, cdh_r, wh_l, wh_r, oh_l, oh_r;
    reg               spk_q;
    always @(posedge clk) begin
        if (cd_stb) begin cdh_l <= cd_l; cdh_r <= cd_r; end
        wh_l <= wss_l; wh_r <= wss_r; oh_l <= opl_l; oh_r <= opl_r;
        spk_q <= spk;
        if (rst) begin cdh_l <= 16'sd0; cdh_r <= 16'sd0; end
    end

    // the speaker's average over the period
    reg  [15:0] hi, hi_q;
    reg  [31:0] spk_p;
    always @(posedge clk) begin
        if (tick) begin hi_q <= hi; hi <= {15'd0, spk_q}; end
        else if (spk_q && hi != 16'hFFFF) hi <= hi + 16'd1;
        spk_p <= hi_q * SPK_K;
        if (rst) begin hi <= 16'd0; hi_q <= 16'd0; end
    end
    wire [15:0] spk_lvl = spk_p[31:16] > SPK_LVL ? SPK_LVL : spk_p[31:16];

    // the sum (three clocks after the tick: the speaker's level has settled), then saturation
    reg  [3:0] t;
    reg signed [17:0] sum_l, sum_r;
    always @(posedge clk) begin
        t <= {t[2:0], tick};
        if (t[2]) begin
            sum_l <= (mute[0] ? 18'sd0 : {{2{wh_l[15]}}, wh_l}) + (mute[1] ? 18'sd0 : {{2{oh_l[15]}}, oh_l}) +
                     (mute[2] ? 18'sd0 : {{2{cdh_l[15]}}, cdh_l}) + (mute[3] ? 18'sd0 : {2'b00, spk_lvl});
            sum_r <= (mute[0] ? 18'sd0 : {{2{wh_r[15]}}, wh_r}) + (mute[1] ? 18'sd0 : {{2{oh_r[15]}}, oh_r}) +
                     (mute[2] ? 18'sd0 : {{2{cdh_r[15]}}, cdh_r}) + (mute[3] ? 18'sd0 : {2'b00, spk_lvl});
        end
        if (t[3]) begin
            out_l   <= sum_l > 18'sd32767 ? 16'sh7FFF : sum_l < -18'sd32768 ? 16'sh8000 : sum_l[15:0];
            out_r   <= sum_r > 18'sd32767 ? 16'sh7FFF : sum_r < -18'sd32768 ? 16'sh8000 : sum_r[15:0];
            out_tgl <= !out_tgl;
        end
        if (rst) begin t <= 4'd0; out_l <= 16'sd0; out_r <= 16'sd0; out_tgl <= 1'b0; end
    end
endmodule
