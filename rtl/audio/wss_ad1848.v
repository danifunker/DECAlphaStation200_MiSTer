// The AlphaStation 200's sound card: a Windows Sound System interface with an
// Analog Devices AD1848 codec (docs/design/audio.md). Ported to Verilog-2001
// from the user's IBM RS/6000 core (IBMRS6K7248_cs4232.sv, its WSS codec)
// and reduced to the AD1848: sixteen indirect registers, one format register
// for playback and capture, one sample counter.
//
// Ports (BASE, the card's SW1/SW2 jumpers, 530h by default; EK-PCDSA-TI
// tables 3-6 and 11-3):
//   BASE+0      (W) the WSS command register: bits 5:3 IRQSEL (1 IRQ7, 2 IRQ9,
//               3 IRQ10, 4 IRQ11), 2:0 DMASEL (the AS200 table 11-5), 6 IRQSENS
//   BASE+0..3   (R) ID and status: bit 7 ChannelAvail (0: all channels), 6
//               IrqSense (the codec's interrupt line), 5:0 the version, 04h
//   BASE+4      R0 index: 7 INIT (R/O), 6 MCE, 5 TRD, 3:0 the register
//   BASE+5      R1 indexed data: I0-I15 (I16-I31 alias them)
//   BASE+6      R2 status: 0 INT, 1 PRDY, 4 SOUR, 5 CRDY; a write clears INT
//   BASE+7      R3 PIO data: playback bytes in (PEN and PPIO), capture out
//
// I8 (clock and data format) takes writes only while MCE is set, I9 only its
// PEN and CEN bits outside MCE. I11 is the read-only test register (DRS,
// ACI, PUR, COR), I12 the ID (0Ah, revision C, no MODE2). Leaving MCE with
// ACAL set runs a short autocalibration (ACI). After reset INIT reads 1 for
// INIT_US.
//
// Playback (PEN, not PPIO): the DMA channel DMASEL names (8-bit, through the
// 82378's 8237 on the xio bus) fills a 16-byte FIFO while it has room; at
// the rate I8 selects (two crystals, eight divisors) a frame comes out of it:
// 8-bit unsigned, mu-law, 16-bit little-endian or A-law, mono or stereo,
// through the DAC's mute and attenuation (I6/I7, 1.5 dB steps). The sample
// counter (I15 then I14; a write of I14 loads it) counts the frames down;
// past 0, INT (and IRQ with IEN) and it reloads. An empty FIFO repeats the
// last frame and sets PUR.
//
// Capture (CEN, not CPIO; the MiSTer has no input): at the same rate a frame
// of silence in I8's format is offered on the capture channel (the playback
// one with SDC); the counter counts captured frames when playback is off.
//
// The xio bus (sio.md 1): one-cycle strobes, the whole port on io_addr,
// claim and io_dout combinational from io_addr and registers.
module wss_ad1848 #(
    parameter        CLK_HZ  = 100000000,
    parameter [15:0] BASE    = 16'h0530,
    parameter        INIT_US = 20,           // INIT after reset
    parameter        ACAL_US = 200           // ACI after MCE with ACAL
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output wire        claim,
    output reg   [7:0] io_dout,

    output reg   [7:0] dreq,                 // the 8237's request lines
    input  wire        dack,                 // a transfer done (dack_ch's)
    input  wire  [2:0] dack_ch,
    input  wire  [7:0] dack_data,            // a playback byte from memory
    output reg   [7:0] cap_byte,             // the capture byte for a write transfer

    output reg  [15:0] irq,                  // ISA IRQ lines (one of 7, 9, 10, 11)
    output reg  signed [15:0] pcm_l,
    output reg  signed [15:0] pcm_r
);
    localparam [31:0] INIT_C32  = CLK_HZ / 1000000 * INIT_US;
    localparam [31:0] ACAL_C32  = CLK_HZ / 1000000 * ACAL_US;
    localparam [23:0] INIT_CLKS = INIT_C32[23:0];
    localparam [23:0] ACAL_CLKS = ACAL_C32[23:0];
    localparam [27:0] XT1 = 28'd24576000;     // the AD1848's two crystals
    localparam [27:0] XT2 = 28'd16934400;
    localparam [27:0] CLKV = CLK_HZ;

    assign claim = io_addr[15:3] == BASE[15:3];
    wire [2:0] off = io_addr[2:0];
    wire wr = io_wr && claim;
    wire rd = io_rd && claim;

    // ---------------------------------------------------------------- registers
    reg  [6:0] cfg;                           // the WSS command register
    reg        init;
    reg [23:0] init_cnt;
    reg        mce, trd;
    reg  [3:0] ia;
    reg  [7:0] r [0:15];                      // I0-I15 (I11, I12 synthesised)
    reg        aci;
    reg [23:0] aci_cnt;
    reg        pur, cor;
    reg        int_st;
    reg [15:0] cnt;                           // the sample counter
    reg  [7:0] dq;                            // r[ia] as read
    reg  [4:0] f_n;                           // playback FIFO bytes (below)
    wire       cap_ovr;                       // capture: a frame with no room (below)

    wire [7:0] i6 = r[6], i7 = r[7], i8 = r[8], i9 = r[9], i10 = r[10];
    wire       pen  = i9[0], cen = i9[1], sdc = i9[2], acal = i9[3];
    wire       ppio = i9[6], cpio = i9[7];
    wire       ien  = i10[1];
    wire [1:0] fmt  = i8[6:5];               // 00 8-bit unsigned, 01 mu-law, 10 16-bit LE, 11 A-law
    wire       st   = i8[4];
    wire       w16  = fmt == 2'b10;
    wire [2:0] fbytes = w16 ? (st ? 3'd4 : 3'd2) : (st ? 3'd2 : 3'd1);
    wire       irq_line = int_st && ien;

    // the AS200's DMA selection (EK-PCDSA-TI table 11-5)
    wire [2:0] dsel = cfg[2:0];
    wire       play_on = dsel != 3'd0 && dsel != 3'd4;
    wire [2:0] play_ch = (dsel == 3'd1 || dsel == 3'd5) ? 3'd0 : (dsel == 3'd2 || dsel == 3'd6) ? 3'd1 : 3'd3;
    wire       capt_on = dsel[2];
    wire [2:0] capt_ch = (dsel == 3'd4 || dsel == 3'd5) ? 3'd0 : 3'd1;
    wire       cap_on  = sdc ? play_on : capt_on;
    wire [2:0] cap_ch  = sdc ? play_ch : capt_ch;

    // write masks (reserved bits read 0)
    function [7:0] wmask;
        input [3:0] n;
        case (n)
            4'd0, 4'd1:             wmask = 8'hEF;
            4'd2, 4'd3, 4'd4, 4'd5: wmask = 8'h9F;
            4'd6, 4'd7:             wmask = 8'hBF;
            4'd8:                   wmask = 8'h7F;
            4'd9:                   wmask = 8'hCF;
            4'd10:                  wmask = 8'hC2;
            4'd11, 4'd12:           wmask = 8'h00;
            4'd13:                  wmask = 8'hFD;
            default:                wmask = 8'hFF;
        endcase
    endfunction
    function [7:0] rdef;
        input [3:0] n;
        case (n)
            4'd2, 4'd3, 4'd4, 4'd5: rdef = 8'h88;
            4'd6, 4'd7:             rdef = 8'h80;
            4'd9:                   rdef = 8'h08;
            default:                rdef = 8'h00;
        endcase
    endfunction

    // the engines' events (below)
    reg        took;                          // a playback frame taken
    reg        under;                         // a frame period with too few bytes
    reg        ctick;                         // a capture frame period
    wire       cap_run  = cen && !cpio && !(sdc && pen);
    wire       evt      = pen ? took : (cap_run && ctick);
    wire       cnt_end  = evt && cnt == 16'd0;

    integer i;
    always @(posedge clk) begin
        if (init) begin
            if (init_cnt == 24'd0) init <= 1'b0; else init_cnt <= init_cnt - 24'd1;
        end
        if (aci) begin
            if (aci_cnt == 24'd0) aci <= 1'b0; else aci_cnt <= aci_cnt - 24'd1;
        end
        if (wr) begin
            case (off)
                3'd0: cfg <= io_din[6:0];
                3'd4: if (!init) begin
                    mce <= io_din[6]; trd <= io_din[5]; ia <= io_din[3:0];
                    if (mce && !io_din[6] && acal) begin aci <= 1'b1; aci_cnt <= ACAL_CLKS; end
                end
                3'd5: if (!init) begin
                    if (ia == 4'd8) begin
                        if (mce) r[8] <= io_din & 8'h7F;
                    end else if (ia == 4'd9) begin
                        if (mce) r[9] <= io_din & 8'hCF;
                        else     r[9] <= {r[9][7:2], io_din[1:0]};
                    end else
                        r[ia] <= io_din & wmask(ia);
                end
                3'd6: int_st <= 1'b0;
                default: ;
            endcase
        end
        if (rd && off == 3'd6) begin pur <= 1'b0; cor <= 1'b0; end
        // the counter: I14's write loads it; a period past 0 ends it (INT) and reloads
        if (evt) cnt <= cnt == 16'd0 ? {r[14], r[15]} : cnt - 16'd1;
        if (wr && off == 3'd5 && !init && ia == 4'd14) cnt <= {io_din, r[15]};
        if (cnt_end) int_st <= 1'b1;
        if (pen && under) pur <= 1'b1;
        if (cap_ovr) cor <= 1'b1;
        if (rst) begin
            cfg <= 7'd0; init <= 1'b1; init_cnt <= INIT_CLKS; mce <= 1'b1; trd <= 1'b0; ia <= 4'd0;
            aci <= 1'b0; aci_cnt <= 24'd0; pur <= 1'b0; cor <= 1'b0; int_st <= 1'b0; cnt <= 16'd0;
            for (i = 0; i < 16; i = i + 1) r[i] <= rdef(i[3:0]);
        end
    end

    // reads: dq follows ia (a read comes at least a clock after the index's write)
    always @(posedge clk) begin
        case (ia)
            4'd11:   dq <= {cor, pur, aci, |dreq, 4'h0};
            4'd12:   dq <= 8'h0A;
            default: dq <= r[ia];
        endcase
    end
    wire prdy = pen && ppio && f_n <= 5'd12;
    wire crdy = cen && cpio;
    always @* begin
        case (off)
            3'd4:    io_dout = init ? 8'h80 : {1'b0, mce, trd, 1'b0, ia};
            3'd5:    io_dout = dq;
            3'd6:    io_dout = {2'b00, crdy, pur | cor, 2'b00, prdy, int_st};
            3'd7:    io_dout = cap_byte;
            default: io_dout = {1'b0, irq_line, 6'h04};
        endcase
    end

    // ---------------------------------------------------------------- the sample clock
    // a crystal tick by phase accumulation, then the divisor
    reg  [27:0] xacc;
    reg         xtick, ftick;
    reg  [11:0] dcnt, div_m1;
    wire [27:0] xa1 = xacc + (i8[0] ? XT2 : XT1);
    wire [27:0] xa2 = xa1 - CLKV;
    always @(posedge clk) begin
        case (i8[3:1])
            3'd0: div_m1 <= 12'd3071;  3'd1: div_m1 <= 12'd1535;
            3'd2: div_m1 <= 12'd895;   3'd3: div_m1 <= 12'd767;
            3'd4: div_m1 <= 12'd447;   3'd5: div_m1 <= 12'd383;
            3'd6: div_m1 <= 12'd511;   default: div_m1 <= 12'd2559;
        endcase
        xtick <= !xa2[27];
        xacc  <= xa2[27] ? xa1 : xa2;
        ftick <= 1'b0;
        if (xtick) begin
            if (dcnt >= div_m1) begin dcnt <= 12'd0; ftick <= 1'b1; end
            else dcnt <= dcnt + 12'd1;
        end
        if (!(pen || cen) || mce || rst) begin dcnt <= 12'd0; ftick <= 1'b0; end
        if (rst) begin xacc <= 28'd0; xtick <= 1'b0; end
    end

    // ---------------------------------------------------------------- playback
    reg  [7:0] fifo [0:15];
    reg  [3:0] f_w, f_r;
    wire       pdma = pen && !ppio && play_on;
    wire       push = (dack && dack_ch == play_ch && pdma) || (wr && off == 3'd7 && pen && ppio);
    wire [7:0] push_d = dack ? dack_data : io_din;
    wire       take = ftick && pen && f_n >= {2'b00, fbytes};
    wire [4:0] f_n_nxt = f_n + (push && f_n != 5'd16 ? 5'd1 : 5'd0) - (take ? {2'b00, fbytes} : 5'd0);
    reg  [7:0] b0, b1, b2, b3;
    reg        dec_go, att_go;
    reg signed [15:0] sl, sr;
    always @(posedge clk) begin
        took <= take; under <= ftick && pen && !take;
        if (push && f_n != 5'd16) begin fifo[f_w] <= push_d; f_w <= f_w + 4'd1; end
        if (take) begin
            b0 <= fifo[f_r]; b1 <= fifo[f_r + 4'd1]; b2 <= fifo[f_r + 4'd2]; b3 <= fifo[f_r + 4'd3];
            f_r <= f_r + {1'b0, fbytes};
        end
        f_n <= f_n_nxt;
        if (!pen || rst) begin f_w <= 4'd0; f_r <= 4'd0; f_n <= 5'd0; end
    end

    // mu-law and A-law (G.711) to 16 bits
    function [15:0] ulaw;
        input [7:0] b;
        reg [7:0] u; reg [15:0] m;
        begin
            u = ~b;
            m = (({9'd0, u[3:0], 3'b000} + 16'h0084) << u[6:4]) - 16'h0084;
            ulaw = u[7] ? (16'd0 - (m << 2)) : (m << 2);
        end
    endfunction
    function [15:0] alaw;
        input [7:0] b;
        reg [7:0] a; reg [15:0] m;
        begin
            a = b ^ 8'h55;
            if (a[6:4] == 3'd0) m = {8'd0, a[3:0], 4'h8};
            else                m = ({8'd0, a[3:0], 4'h0} + 16'h0108) << (a[6:4] - 3'd1);
            alaw = a[7] ? (m << 3) : (16'd0 - (m << 3));
        end
    endfunction
    function [15:0] dec8;
        input [1:0] f; input [7:0] b;
        case (f)
            2'b01:   dec8 = ulaw(b);
            2'b11:   dec8 = alaw(b);
            default: dec8 = {~b[7], b[6:0], 8'h00};
        endcase
    endfunction

    // the DAC's attenuation: 1.5 dB steps, 6 dB as a shift and the rest as a multiply
    function [16:0] frac;
        input [1:0] k;
        case (k)
            2'd0: frac = 17'd32768; 2'd1: frac = 17'd27554; 2'd2: frac = 17'd23170; default: frac = 17'd19484;
        endcase
    endfunction
    reg signed [31:0] pl, pr;
    reg  [7:0] a6, a7;
    always @(posedge clk) begin
        dec_go <= took; att_go <= dec_go;
        if (dec_go) begin
            if (w16) begin
                sl <= {b1, b0};
                sr <= st ? {b3, b2} : {b1, b0};
            end else begin
                sl <= dec8(fmt, b0);
                sr <= dec8(fmt, st ? b1 : b0);
            end
        end
        a6 <= i6; a7 <= i7;
        pl <= sl * $signed(frac(a6[1:0]));
        pr <= sr * $signed(frac(a7[1:0]));
        pcm_l <= (a6[7] || !pen) ? 16'sd0 : ($signed(pl[30:15]) >>> a6[5:2]);
        pcm_r <= (a7[7] || !pen) ? 16'sd0 : ($signed(pr[30:15]) >>> a7[5:2]);
        if (rst) begin sl <= 16'sd0; sr <= 16'sd0; pcm_l <= 16'sd0; pcm_r <= 16'sd0; end
    end

    // ---------------------------------------------------------------- capture (silence)
    reg  [4:0] c_pend;                        // bytes offered, not yet taken
    assign     cap_ovr = cap_run && ftick && c_pend > 5'd12;
    wire       cpop = (dack && dack_ch == cap_ch && cap_run && cap_on && c_pend != 5'd0 &&
                       !(pdma && cap_ch == play_ch)) ||
                      (rd && off == 3'd7 && cen && cpio && c_pend != 5'd0);
    wire [4:0] c_pend_nxt = c_pend + ((cap_run || (cen && cpio)) && ftick && c_pend <= 5'd12 ? {2'b00, fbytes} : 5'd0)
                                   - (cpop ? 5'd1 : 5'd0);
    always @(posedge clk) begin
        ctick  <= ftick;
        c_pend <= c_pend_nxt;
        if (!cen || rst) c_pend <= 5'd0;
        case (fmt)
            2'b00: cap_byte <= 8'h80; 2'b01: cap_byte <= 8'hFF; 2'b11: cap_byte <= 8'hD5; default: cap_byte <= 8'h00;
        endcase
    end

    // ---------------------------------------------------------------- DMA requests, IRQ
    // from the next state, so a request drops the clock after its last dack
    wire int_nxt = (int_st && !(wr && off == 3'd6)) || cnt_end;
    wire hold    = trd && int_nxt;
    wire pdrq    = pdma && f_n_nxt <= 5'd12 && !hold && !rst;
    wire cdrq    = cap_run && cap_on && c_pend_nxt != 5'd0 && !hold && !(pdma && cap_ch == play_ch) && !rst;
    always @(posedge clk) begin
        dreq <= (pdrq ? (8'd1 << play_ch) : 8'd0) | (cdrq ? (8'd1 << cap_ch) : 8'd0);
        case (cfg[5:3])
            3'd1:    irq <= irq_line ? 16'h0080 : 16'h0000;
            3'd2:    irq <= irq_line ? 16'h0200 : 16'h0000;
            3'd3:    irq <= irq_line ? 16'h0400 : 16'h0000;
            3'd4:    irq <= irq_line ? 16'h0800 : 16'h0000;
            default: irq <= 16'h0000;
        endcase
        if (rst) begin dreq <= 8'd0; irq <= 16'd0; end
    end

    initial begin
        for (i = 0; i < 16; i = i + 1) fifo[i] = 8'h00;
    end
endmodule
