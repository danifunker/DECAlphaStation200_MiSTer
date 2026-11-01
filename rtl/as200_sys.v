// The AlphaStation 200 4/100 with its CPU: the 21064 (rtl/cpu/ev4_core.v)
// loading the SROM into its I-cache, the 21071 (rtl/apecs/apecs.v), the
// 53C810 (rtl/scsi/ncr53c810.v, PCI device 6) and the 82378 SIO with the ISA
// devices (rtl/sio/sio82378.v, device 7: 8259s, 8254, 8237s, TOY, 8242,
// PC87332, COM1/COM2). DRAM and the flash/DROM
// bytes are ports: the MiSTer top puts them in SDRAM and DDR3, the Verilator
// system simulation (verilator/system) in C++ models.
//
// This replaces rtl/as200.v (the bring-up stub machine) in the MiSTer top
// once the SDRAM and DDR3 adapters exist.
module as200_sys #(
    parameter SROM_HEX = "srom/build/avanti_srom.bitstream.hex",  // relative to the Quartus project
    parameter SIM_FAST = 0              // 1 (simulation only): the TOY's seconds run fast
) (
    input  wire        clk,
    input  wire        rst,
    input  wire  [1:0] cfg_mem,         // Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB
    input  wire  [7:0] jumpers,
    output wire  [7:0] leds,

    // the flashbus NVRAM's save port (rtl/mister/nvsave.v)
    input  wire [12:0] nvb_addr,
    input  wire        nvb_we,
    input  wire  [7:0] nvb_wdata,
    output wire  [7:0] nvb_rdata,
    output wire        nv_dirty,

    // DRAM (128 MB)
    output wire        d_req,
    output wire        d_we,
    output wire [26:3] d_addr,
    output wire  [7:0] d_be,
    output wire [63:0] d_wdata,
    input  wire        d_ack,
    input  wire [63:0] d_rdata,

    // flash + DROM bytes (flashbus offset)
    output wire        f_req,
    output wire        f_we,
    output wire [20:0] f_addr,
    output wire  [7:0] f_wdata,
    input  wire        f_ack,
    input  wire  [7:0] f_rdata,

    // the 21064's SROM serial port (the DROM's console)
    output wire        srom_txd,
    input  wire        srom_rxd,

    // COM1
    output wire        com1_txd,
    input  wire        com1_rxd,
    output wire        com1_tx_stb,
    output wire  [7:0] com1_tx_byte,
    input  wire        com1_kbd_stb,
    input  wire  [7:0] com1_kbd_byte,
    output wire        com2_txd,
    input  wire        com2_rxd,

    // SCSI images (hps_io block devices: slot 0 disk ID 0, 1 disk ID 1, 2 CD-ROM ID 4)
    input  wire  [2:0] img_present,
    input  wire [95:0] img_blocks,      // 512-byte blocks, slot s at [32s+31:32s]
    output wire [95:0] sd_lba,
    output wire [17:0] sd_blk_cnt,
    output wire  [2:0] sd_rd,
    output wire  [2:0] sd_wr,
    input  wire  [2:0] sd_ack,
    input  wire [13:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,
    input  wire        sd_buff_wr,
    input  wire        cd_change,       // the CD slot's image was (re)mounted (a pulse)

    // keyboard and mouse (hps_io), the TOY's time (hps_io RTC) and year override
    input  wire [10:0] ps2_key,
    input  wire [24:0] ps2_mouse,
    input  wire [64:0] rtc,
    input  wire        year_ovr_en,
    input  wire  [6:0] year_ovr,
    input  wire        console_arc,     // OSD: boot the ARC console (TOY CMOS 3Fh = 1)
    output wire        speaker,
    // audio (signed 16-bit, a new pair each aud_tgl toggle, 48 kHz)
    output wire [15:0] aud_l,
    output wire [15:0] aud_r,
    output wire        aud_tgl,

    // retire trace (simulation)
    output wire        dbg_retire,
    output wire [63:0] dbg_pc,
    output wire [31:0] dbg_insn,
    output wire        dbg_rwr,
    output wire  [4:0] dbg_rnum,
    output wire [63:0] dbg_rval,
    output wire        dbg_mwr,
    output wire [63:0] dbg_maddr,
    output wire [63:0] dbg_mval,
    output wire  [3:0] dbg_msize
);
    // ------------------------------------------------------------ SROM (XC1765D image)
    reg  [7:0] srom [0:8191];
    initial $readmemh(SROM_HEX, srom);
    wire [12:0] srom_addr;
    reg   [7:0] srom_q;
    always @(posedge clk) srom_q <= srom[srom_addr];

    // ------------------------------------------------------------ CPU
    // irq_h (HARDWARE.md 3): 0 errors (STUB), 1 unused, 2 the 8259s, 3 NMI,
    // 4 the TOY's periodic interrupt, 5 HALT | 8242 KBRST
    wire  [5:0] irq_h;
    wire        dinv;                   // DMA write -> D-cache invalidate (dInvReq)
    wire  [7:0] dinv_idx;
    wire        sio_intr, sio_nmi, sio_toy, sio_kbrst;
    assign irq_h = {sio_kbrst, sio_toy, sio_nmi, sio_intr, 2'b00};
    wire        c_req, c_we, c_ist, c_ack;
    wire [33:3] c_addr;
    wire  [7:0] c_be;
    wire [63:0] c_wdata, c_rdata;

    ev4_core cpu (
        .clk(clk), .rst(rst),
        .icmode(1'b0), .srom_addr(srom_addr), .srom_data(srom_q),
        .sl_xmit(srom_txd), .sl_rcv(srom_rxd),
        .irq_h(irq_h),
        .dinv(dinv), .dinv_idx(dinv_idx),
        .mem_req(c_req), .mem_we(c_we), .mem_istream(c_ist), .mem_addr(c_addr),
        .mem_be(c_be), .mem_wdata(c_wdata), .mem_ack(c_ack), .mem_rdata(c_rdata),
        .dbg_retire(dbg_retire), .dbg_pc(dbg_pc), .dbg_insn(dbg_insn), .dbg_rwr(dbg_rwr),
        .dbg_rnum(dbg_rnum), .dbg_rval(dbg_rval), .dbg_mwr(dbg_mwr), .dbg_maddr(dbg_maddr),
        .dbg_mval(dbg_mval), .dbg_msize(dbg_msize)
    );

    // ------------------------------------------------------------ 21071
    wire        pt_req, pt_we;
    wire  [1:0] pt_cmd;
    wire  [4:0] pt_dev;
    wire [31:0] pt_addr, pt_wdata;
    wire  [3:0] pt_be;
    wire        pt_claim, pt_ack;
    wire [31:0] pt_rdata;

    apecs core_logic (
        .clk(clk), .rst(rst), .cfg_mem(cfg_mem), .jumpers(jumpers), .leds(leds),
        .nvb_addr(nvb_addr), .nvb_we(nvb_we), .nvb_wdata(nvb_wdata), .nvb_rdata(nvb_rdata), .nv_dirty(nv_dirty),
        .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_be(c_be), .c_wdata(c_wdata),
        .c_ack(c_ack), .c_rdata(c_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata),
        .d_ack(d_ack), .d_rdata(d_rdata),
        .f_req(f_req), .f_we(f_we), .f_addr(f_addr), .f_wdata(f_wdata),
        .f_ack(f_ack), .f_rdata(f_rdata),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_claim(pt_claim), .pt_ack(pt_ack), .pt_rdata(pt_rdata),
        .dm_req(dm_req), .dm_we(dm_we), .dm_addr(dm_addr), .dm_be(dm_be), .dm_wdata(dm_wdata),
        .dm_ack(dm_ack), .dm_rdata(dm_rdata),
        .dinv(dinv), .dinv_idx(dinv_idx)
    );

    // ------------------------------------------------------------ PCI devices
    // (pci.md 2) claim/ack/rdata of every device ORed; I/O that no device
    // claims is the ISA side's (subtractive)

    // the 53C810 (device 6, IDSEL AD17, PIRQ3) and the targets on its SCSI bus
    wire        sb_sel, sb_sel_atn, sb_sel_done, sb_sel_fail, sb_bsy, sb_req, sb_ack, sb_ackhold, sb_atn, sb_rst;
    wire  [2:0] sb_sel_id, sb_phase;
    wire  [7:0] sb_tdata, sb_idata;
    scsi_targets #(.DISK0_ID(3'd0), .DISK1_ID(3'd1), .CD_ID(3'd4)) targets (
        .clk(clk), .rst(rst),
        .sel(sb_sel), .sel_id(sb_sel_id), .sel_atn(sb_sel_atn), .sel_done(sb_sel_done), .sel_fail(sb_sel_fail),
        .bsy(sb_bsy), .req(sb_req), .phase(sb_phase), .tdata(sb_tdata),
        .ack(sb_ack), .idata(sb_idata), .ackhold(sb_ackhold), .atn(sb_atn), .brst(sb_rst),
        .img_present(img_present), .img_blocks(img_blocks),
        .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr),
        .cd_change(cd_change), .cd_audio_l(cd_audio_l), .cd_audio_r(cd_audio_r), .cd_audio_stb(cd_audio_stb)
    );
    // DMA masters: the 53C810 and the SIO's 8237s, fixed priority, the owner
    // kept until its transfer is acknowledged
    wire        dm_req, dm_we, dm_ack;
    wire [31:0] dm_addr, dm_wdata, dm_rdata;
    wire  [3:0] dm_be;
    wire        scsi_dm_req, scsi_dm_we;
    wire [31:0] scsi_dm_addr, scsi_dm_wdata;
    wire  [3:0] scsi_dm_be;
    reg         dm_own;                 // 0 the 53C810, 1 the SIO
    reg         dm_busy;
    always @(posedge clk) begin
        if (rst) begin dm_busy <= 1'b0; dm_own <= 1'b0; end
        else if (!dm_busy) begin
            if (scsi_dm_req) begin dm_own <= 1'b0; dm_busy <= 1'b1; end
            else if (sio_dm_req) begin dm_own <= 1'b1; dm_busy <= 1'b1; end
        end else if (dm_ack) dm_busy <= 1'b0;
    end
    assign dm_req   = dm_busy && (dm_own ? sio_dm_req : scsi_dm_req) && !dm_ack;
    assign dm_we    = dm_own ? sio_dm_we    : scsi_dm_we;
    assign dm_addr  = dm_own ? sio_dm_addr  : scsi_dm_addr;
    assign dm_be    = dm_own ? sio_dm_be    : scsi_dm_be;
    assign dm_wdata = dm_own ? sio_dm_wdata : scsi_dm_wdata;
    wire        scsi_dm_ack = dm_ack && !dm_own;
    wire        sio_dm_ack  = dm_ack && dm_own;
    wire        scsi_claim, scsi_ack, scsi_inta_n;
    wire [31:0] scsi_rdata;
    ncr53c810 #(.DEVNUM(6)) scsi (
        .clk(clk), .reset(rst),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_claim(scsi_claim), .pt_ack(scsi_ack), .pt_rdata(scsi_rdata),
        .dm_req(scsi_dm_req), .dm_we(scsi_dm_we), .dm_addr(scsi_dm_addr), .dm_be(scsi_dm_be),
        .dm_wdata(scsi_dm_wdata), .dm_ack(scsi_dm_ack), .dm_rdata(dm_rdata),
        .inta_n(scsi_inta_n),
        .sb_sel(sb_sel), .sb_sel_id(sb_sel_id), .sb_sel_atn(sb_sel_atn), .sb_sel_done(sb_sel_done),
        .sb_sel_fail(sb_sel_fail), .sb_bsy(sb_bsy), .sb_req(sb_req), .sb_phase(sb_phase), .sb_tdata(sb_tdata),
        .sb_ack(sb_ack), .sb_idata(sb_idata), .sb_ackhold(sb_ackhold), .sb_atn(sb_atn), .sb_rst(sb_rst)
    );

    // the 82378 SIO (device 7) and everything on ISA: I/O no other device
    // claims is its (subtractive decode)
    wire        sio_claim, sio_ack;
    wire [31:0] sio_rdata;
    wire        sio_dm_req, sio_dm_we;
    wire [31:0] sio_dm_addr, sio_dm_wdata;
    wire  [3:0] sio_dm_be;
    sio82378 #(.CLK_HZ(100000000), .DEVNUM(5'd7), .RTC_FAST(SIM_FAST)) sio (
        .clk(clk), .rst(rst),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_sub(pt_req && pt_cmd == 2'd1 && !scsi_claim),
        .pt_claim(sio_claim), .pt_ack(sio_ack), .pt_rdata(sio_rdata),
        .dm_req(sio_dm_req), .dm_we(sio_dm_we), .dm_addr(sio_dm_addr), .dm_be(sio_dm_be),
        .dm_wdata(sio_dm_wdata), .dm_ack(sio_dm_ack), .dm_rdata(dm_rdata),
        .pirq_n({scsi_inta_n, 3'b111}), .serr(1'b0), .iochk(1'b0),
        .intr(sio_intr), .nmi(sio_nmi), .toy_irq(sio_toy), .kbrst(sio_kbrst), .spk(speaker),
        .xio_addr(xio_addr), .xio_rd(xio_rd), .xio_wr(xio_wr), .xio_wdata(xio_wdata),
        .xio_claim(xio_claim), .xio_rdata(xio_rdata), .xio_irq(xio_irq), .xio_dreq(xio_dreq),
        .xio_dack(xio_dack), .xio_dack_ch(xio_dack_ch), .xio_dack_data(xio_dack_data),
        .xio_dev_data(xio_dev_data), .xio_dma_ch(xio_dma_ch), .xio_tc(xio_tc),
        .com1_txd(com1_txd), .com1_rxd(com1_rxd), .com1_rts_n(), .com1_dtr_n(),
        .com1_cts_n(1'b0), .com1_dsr_n(1'b0), .com1_ri_n(1'b1), .com1_dcd_n(1'b0),
        .com1_tx_stb(com1_tx_stb), .com1_tx_byte(com1_tx_byte),
        .com1_rx_inj_stb(com1_kbd_stb), .com1_rx_inj_byte(com1_kbd_byte),
        .com2_txd(com2_txd), .com2_rxd(com2_rxd), .com2_rts_n(), .com2_dtr_n(),
        .com2_cts_n(1'b0), .com2_dsr_n(1'b0), .com2_ri_n(1'b1), .com2_dcd_n(1'b0),
        .ps2_key(ps2_key), .ps2_mouse(ps2_mouse), .rtc(rtc),
        .year_ovr_en(year_ovr_en), .year_ovr(year_ovr), .console_arc(console_arc), .lpt_data()
    );

    // CD audio (the CD-ROM target's player): not yet
    wire signed [15:0] cd_audio_l, cd_audio_r;
    wire        cd_audio_stb;

    // the AS200 sound card (WSS AD1848 at 530h, OPL at 388h; rtl/audio) on the SIO's ISA expansion bus
    wire [15:0] xio_addr, xio_irq, xio_dack_data, xio_dev_data;
    wire        xio_rd, xio_wr, xio_claim, xio_dack, xio_tc;
    wire  [7:0] xio_wdata, xio_rdata, xio_dreq;
    wire  [2:0] xio_dack_ch, xio_dma_ch;
    as200_audio #(.CLK_HZ(100000000)) audio (
        .clk(clk), .rst(rst),
        .xio_addr(xio_addr), .xio_rd(xio_rd), .xio_wr(xio_wr), .xio_wdata(xio_wdata),
        .xio_claim(xio_claim), .xio_rdata(xio_rdata), .xio_irq(xio_irq), .xio_dreq(xio_dreq),
        .xio_dack(xio_dack), .xio_dack_ch(xio_dack_ch), .xio_dack_data(xio_dack_data),
        .xio_dev_data(xio_dev_data), .xio_dma_ch(xio_dma_ch), .xio_tc(xio_tc),
        .speaker(speaker), .cd_audio_l(cd_audio_l), .cd_audio_r(cd_audio_r), .cd_audio_stb(cd_audio_stb),
        .mute(4'd0), .aud_l(aud_l), .aud_r(aud_r), .aud_tgl(aud_tgl)
    );
    assign pt_claim = scsi_claim | sio_claim;
    assign pt_ack   = scsi_ack | sio_ack;
    assign pt_rdata = scsi_rdata | (sio_ack ? sio_rdata : 32'd0);
endmodule
