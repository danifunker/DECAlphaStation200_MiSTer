// The AlphaStation 200's audio (docs/design/audio.md): the sound card (WSS
// with an AD1848 at 530h, its FM synthesiser at 388h) on the 82378's xio
// ISA bus, and the mix with the PC speaker and the CD-ROM's audio.
//
// The xio side is sio82378's (sio.md 1) port for port: claim and rdata are
// combinational from xio_addr and registers; the DMA requests and the IRQ
// lines are registered. The 8237 transfers are 8-bit (channels 0, 1, 3).
// aud_l/aud_r/aud_tgl go to audio_cdc.v in the MiSTer top.
module as200_audio #(
    parameter        CLK_HZ   = 100000000,
    parameter [15:0] WSS_BASE = 16'h0530
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clk_audio,             // 24.576 MHz: the FM synthesiser's clock

    // the 82378's xio bus
    input  wire [15:0] xio_addr,
    input  wire        xio_rd,
    input  wire        xio_wr,
    input  wire  [7:0] xio_wdata,
    output wire        xio_claim,
    output wire  [7:0] xio_rdata,
    output wire [15:0] xio_irq,
    output wire  [7:0] xio_dreq,
    input  wire        xio_dack,
    input  wire  [2:0] xio_dack_ch,
    input  wire [15:0] xio_dack_data,
    output wire [15:0] xio_dev_data,
    input  wire  [2:0] xio_dma_ch,
    input  wire        xio_tc,

    input  wire        speaker,               // sio82378's spk
    input  wire [15:0] cd_audio_l,            // signed, 44.1 kHz
    input  wire [15:0] cd_audio_r,
    input  wire        cd_audio_stb,
    input  wire  [3:0] mute,                  // 0 WSS, 1 FM, 2 CD, 3 speaker

    output wire [15:0] aud_l,                 // signed, held a 48 kHz period
    output wire [15:0] aud_r,
    output wire        aud_tgl                // toggles with each new pair
);
    wire        wss_claim, opl_claim;
    wire  [7:0] wss_q, opl_q, cap_byte;
    wire [15:0] pcm_l, pcm_r, fm_l, fm_r;

    assign xio_claim    = wss_claim || opl_claim;
    assign xio_rdata    = wss_claim ? wss_q : opl_q;
    assign xio_dev_data = {8'h00, cap_byte};

    wss_ad1848 #(.CLK_HZ(CLK_HZ), .BASE(WSS_BASE)) u_wss (
        .clk(clk), .rst(rst),
        .io_addr(xio_addr), .io_rd(xio_rd), .io_wr(xio_wr), .io_din(xio_wdata),
        .claim(wss_claim), .io_dout(wss_q),
        .dreq(xio_dreq), .dack(xio_dack), .dack_ch(xio_dack_ch), .dack_data(xio_dack_data[7:0]),
        .cap_byte(cap_byte), .irq(xio_irq), .pcm_l(pcm_l), .pcm_r(pcm_r)
    );

    opl_isa #(.CLK_HZ(CLK_HZ)) u_opl (
        .clk(clk), .rst(rst), .clk_audio(clk_audio),
        .io_addr(xio_addr), .io_rd(xio_rd), .io_wr(xio_wr), .io_din(xio_wdata),
        .claim(opl_claim), .io_dout(opl_q), .snd_l(fm_l), .snd_r(fm_r)
    );

    audio_mix #(.CLK_HZ(CLK_HZ)) u_mix (
        .clk(clk), .rst(rst),
        .wss_l(pcm_l), .wss_r(pcm_r), .opl_l(fm_l), .opl_r(fm_r),
        .cd_l(cd_audio_l), .cd_r(cd_audio_r), .cd_stb(cd_audio_stb),
        .spk(speaker), .mute(mute),
        .out_l(aud_l), .out_r(aud_r), .out_tgl(aud_tgl)
    );
endmodule
