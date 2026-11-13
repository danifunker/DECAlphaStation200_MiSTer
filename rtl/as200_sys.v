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
    parameter SIM_FAST = 0,             // 1 (simulation only): the TOY's seconds run fast
    parameter BC_LB = 13                // the board cache's lines, log2 (rtl/apecs/bcache.v): 13 = 256 KB
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clk_audio,       // 24.576 MHz (the FM synthesiser)
    input  wire  [1:0] cfg_mem,
    input  wire        halt,            // the HALT button (CPU IRQ5, with the 8242's KBRST)         // Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB
    input  wire  [7:0] jumpers,
    input  wire        bc_en,           // the board cache (static: latched at reset)
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
    output wire        d_line,          // a 32-byte line read (4 quadwords, one d_ack each)
    output wire [26:3] d_addr,
    output wire [31:0] d_be,            // a write is a line (d_addr[26:5]) with 32 byte enables
    output wire [255:0] d_wdata,
    input  wire        d_ack,
    input  wire [63:0] d_rdata,

    // flash + DROM bytes (flashbus offset), after the 28F020 command layer
    input  wire        flash_wp,        // J6 flash write disabled
    output wire        f_req,
    output wire        f_we,
    output wire [20:0] f_addr,
    output wire  [7:0] f_wdata,
    input  wire        f_ack,
    input  wire  [7:0] f_rdata,

    // the TGA (ZLXp-E1): its VRAM port and display fetch (to the DDR3 arbiter), video
    output wire        vr_req,
    output wire        vr_we,
    output wire [17:0] vr_addr,
    output wire  [4:0] vr_len,
    output wire  [7:0] vr_be,
    output wire [63:0] vr_wdata,
    input  wire        vr_ack,
    input  wire        vr_rvalid,
    input  wire [63:0] vr_rdata,
    output wire        sc_req,
    output wire [17:0] sc_addr,
    output wire  [5:0] sc_len,
    input  wire        sc_ack,
    input  wire        sc_rvalid,
    input  wire [63:0] sc_rdata,
    input  wire        tdbg_stall,       // the TGA trace throttle (dbg_trace full)
    input  wire        clk_pix,
    output wire        tga_ce, tga_hs, tga_vs, tga_de, tga_hb, tga_vb,
    output wire  [7:0] tga_r, tga_g, tga_b,
    output wire        tga_on,

    // the 21040's Ethernet ID ROM address, link, and the LAN mailbox with Main
    // (DDR3 byte 0x1FF0_0000; docs/design/ethernet.md)
    input  wire [47:0] enet_mac,
    input  wire        enet_link_up,
    output wire        nb_req,
    output wire        nb_we,
    output wire [12:0] nb_addr,
    output wire [63:0] nb_wdata,
    input  wire        nb_ack,
    input  wire [63:0] nb_rdata,
    output wire [47:0] nb_pmac,
    output wire        nb_pmac_ok,
    output wire        nb_link,

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
    // the floppy (hps_io slot 3; the 82077AA in the SIO, docs/design/floppy.md)
    input  wire        fd_mounted,
    input  wire        fd_readonly,
    input  wire [63:0] fd_size,
    output wire [31:0] fd_lba,
    output wire  [5:0] fd_blk_cnt,
    output wire        fd_rd,
    output wire        fd_wr,
    input  wire        fd_ack,
    output wire  [7:0] fd_buff_din,
    output wire        fd_led,

    // keyboard and mouse (hps_io), the TOY's time (hps_io RTC) and year override
    input  wire [10:0] ps2_key,
    input  wire [24:0] ps2_mouse,
    input  wire [64:0] rtc,
    input  wire        year_ovr_en,
    input  wire  [6:0] year_ovr,
    input  wire  [1:0] console_mode,    // OSD Console: 0 NVRAM file, 1 SRM, 2 ARC (TOY CMOS 3Fh, rtl/sio/isa_rtc.v)
    input  wire  [1:0] srm_con_mode,    // OSD SRM console: 0 Graphics, 1 Serial, 2 NVRAM file (TOY CMOS 17h)
    input  wire  [6:0] cm_addr,         // the TOY CMOS's save port (rtl/mister/nvsave.v)
    input  wire        cm_we,
    input  wire  [7:0] cm_wdata,
    output wire  [7:0] cm_rdata,
    output wire        cm_dirty,
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
    output wire  [3:0] dbg_msize,
    output wire        dbg_pal,
    output wire  [5:0] dbg_irqh,
    output wire        dbg_dm_req,      // a PCI master's DMA is pending (the board's memory write watch)
    output wire        dbg_ent,         // the CPU's PAL entries (ev4_core dbg_ent*)
    output wire [13:0] dbg_ent_off,
    output wire [31:0] dbg_ent_ir,
    output wire [63:0] dbg_exc_addr,
    output wire [63:0] dbg_va,
    output wire [14:0] dbg_mm_csr,
    output wire [10:0] dbg_dtb_pr,
    output wire        dbg_psw,
    output wire  [7:0] dbg_psv,
    // the TGA's debug taps (rtl/tga/tga.v dbg_*)
    output wire        tdbg_rq,
    output wire        tdbg_rw,
    output wire  [7:0] tdbg_ri,
    output wire [31:0] tdbg_rd,
    output wire        tdbg_fw,
    output wire [20:0] tdbg_fa,
    output wire [31:0] tdbg_fd,
    output wire  [3:0] tdbg_fbe,
    output wire  [7:0] tdbg_mode,
    output wire [319:0] tdbg_st,
    output wire        ndbg_stb,        // the SCRIPTS trace (ncr53c810.v)
    output wire  [3:0] ndbg_tag,
    output wire [31:0] ndbg_a,
    output wire [31:0] ndbg_b
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
    assign irq_h = {sio_kbrst | halt, sio_toy, sio_nmi, sio_intr, 2'b00};
    assign dbg_irqh = irq_h;
`ifdef SIM_PCILOG
    reg [5:0] irq_h_q;
    always @(posedge clk) begin
        irq_h_q <= irq_h;
        if ($test$plusargs("iolog") && irq_h_q != irq_h) $display("IRQH %b", irq_h);
    end
`endif
    wire        c_req, c_we, c_ist, c_ack, c_line;
    wire [33:3] c_addr;
    wire  [7:0] c_be;
    wire [63:0] c_wdata, c_rdata;
    wire [31:0] c_wmask;
    wire [255:0] c_wline;

    ev4_core cpu (
        .clk(clk), .rst(rst),
        .icmode(1'b0), .srom_addr(srom_addr), .srom_data(srom_q),
        .sl_xmit(srom_txd), .sl_rcv(srom_rxd),
        .irq_h(irq_h),
        .dinv(dinv), .dinv_idx(dinv_idx),
        .mem_req(c_req), .mem_we(c_we), .mem_istream(c_ist), .mem_line(c_line), .mem_addr(c_addr),
        .mem_be(c_be), .mem_wdata(c_wdata), .mem_wmask(c_wmask), .mem_wline(c_wline), .mem_ack(c_ack), .mem_rdata(c_rdata),
        .dbg_retire(dbg_retire), .dbg_pc(dbg_pc), .dbg_insn(dbg_insn), .dbg_rwr(dbg_rwr),
        .dbg_rnum(dbg_rnum), .dbg_rval(dbg_rval), .dbg_mwr(dbg_mwr), .dbg_maddr(dbg_maddr),
        .dbg_mval(dbg_mval), .dbg_msize(dbg_msize), .dbg_pal(dbg_pal),
        .dbg_ent(dbg_ent), .dbg_ent_off(dbg_ent_off), .dbg_ent_ir(dbg_ent_ir), .dbg_exc_addr(dbg_exc_addr), .dbg_va(dbg_va), .dbg_mm_csr(dbg_mm_csr), .dbg_dtb_pr(dbg_dtb_pr), .dbg_psw(dbg_psw), .dbg_psv(dbg_psv)
    );

    // ------------------------------------------------------------ 21071
    wire        pt_req, pt_we;
    wire  [1:0] pt_cmd;
    wire  [4:0] pt_dev;
    wire [31:0] pt_addr, pt_wdata;
    wire  [3:0] pt_be;
    wire        pt_claim, pt_ack;
    wire [31:0] pt_rdata;

    // the flashROMs' command interface (rtl/apecs/flash28f020.v)
    wire        fu_req, fu_we, fu_ack;
    wire [20:0] fu_addr;
    wire  [7:0] fu_wdata, fu_rdata;
    flash28f020 flash_cmd (
        .clk(clk), .rst(rst), .wp(flash_wp),
        .u_req(fu_req), .u_we(fu_we), .u_addr(fu_addr), .u_wdata(fu_wdata), .u_ack(fu_ack), .u_rdata(fu_rdata),
        .f_req(f_req), .f_we(f_we), .f_addr(f_addr), .f_wdata(f_wdata), .f_ack(f_ack), .f_rdata(f_rdata)
    );

    // the board cache sits on the 21071's DRAM port (write-back: it sends the memory its own
    // writes of dirty lines, so d_* are its outputs)
    wire         a_req, a_ack, a_we, a_line;
    wire [26:3]  a_addr;
    wire [31:0]  a_be;
    wire [255:0] a_wdata;
    wire [63:0]  a_rdata;
    bcache #(.LB(BC_LB)) bcache (
        .clk(clk), .rst(rst), .en(bc_en),
        .d_req(a_req), .d_we(a_we), .d_line(a_line), .d_addr(a_addr), .d_be(a_be), .d_wdata(a_wdata),
        .d_ack(a_ack), .d_rdata(a_rdata),
        .s_req(d_req), .s_we(d_we), .s_line(d_line), .s_addr(d_addr), .s_be(d_be), .s_wdata(d_wdata),
        .s_ack(d_ack), .s_rdata(d_rdata)
    );

    apecs core_logic (
        .clk(clk), .rst(rst), .cfg_mem(cfg_mem), .jumpers(jumpers), .leds(leds),
        .nvb_addr(nvb_addr), .nvb_we(nvb_we), .nvb_wdata(nvb_wdata), .nvb_rdata(nvb_rdata), .nv_dirty(nv_dirty),
        .c_req(c_req), .c_we(c_we), .c_line(c_line), .c_addr(c_addr), .c_be(c_be), .c_wdata(c_wdata), .c_wmask(c_wmask), .c_wline(c_wline),
        .c_ack(c_ack), .c_rdata(c_rdata),
        .d_req(a_req), .d_we(a_we), .d_line(a_line), .d_addr(a_addr), .d_be(a_be), .d_wdata(a_wdata),
        .d_ack(a_ack), .d_rdata(a_rdata),
        .f_req(fu_req), .f_we(fu_we), .f_addr(fu_addr), .f_wdata(fu_wdata),
        .f_ack(fu_ack), .f_rdata(fu_rdata),
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
    wire        sb_resel, sb_resel_ok, sb_resel_ack;
    wire [2:0]  sb_resel_id;
    wire  [2:0] sb_sel_id, sb_phase;
    wire  [7:0] sb_tdata, sb_idata;
    wire [12:0] tgt_st;
    scsi_targets #(.DISK0_ID(3'd0), .DISK1_ID(3'd1), .CD_ID(3'd4)) targets (
        .clk(clk), .rst(rst),
        .sel(sb_sel), .sel_id(sb_sel_id), .sel_atn(sb_sel_atn), .sel_done(sb_sel_done), .sel_fail(sb_sel_fail),
        .bsy(sb_bsy), .req(sb_req), .phase(sb_phase), .tdata(sb_tdata),
        .ack(sb_ack), .idata(sb_idata), .ackhold(sb_ackhold), .atn(sb_atn), .brst(sb_rst),
        .resel(sb_resel), .resel_id(sb_resel_id), .resel_ok(sb_resel_ok), .resel_ack(sb_resel_ack),
        .img_present(img_present), .img_blocks(img_blocks),
        .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr),
        .cd_change(cd_change), .cd_audio_l(cd_audio_l), .cd_audio_r(cd_audio_r), .cd_audio_stb(cd_audio_stb),
        .dbg_st(tgt_st)
    );
    // DMA masters: the 53C810 and the SIO's 8237s, fixed priority, the owner
    // kept until its transfer is acknowledged
    // the masters' request, muxed (dmm_*) and registered (dm_*) on its way to the 21071
    // (timing: a master's address ran through the mux and the DMA windows into d_addr);
    // a master holds its request's address and data until the acknowledge
    wire        dmm_req, dmm_we, dm_ack;
    wire [31:0] dmm_addr, dmm_wdata, dm_rdata;
    wire  [3:0] dmm_be;
    reg         dm_req, dm_we;
    reg  [31:0] dm_addr, dm_wdata;
    reg   [3:0] dm_be;
    always @(posedge clk) begin
        dm_req <= !rst && dmm_req;
        dm_we <= dmm_we; dm_addr <= dmm_addr; dm_be <= dmm_be; dm_wdata <= dmm_wdata;
    end
    assign dbg_dm_req = dm_req;
    wire        scsi_dm_req, scsi_dm_we;
    wire [31:0] scsi_dm_addr, scsi_dm_wdata;
    wire  [3:0] scsi_dm_be;
    wire        enet_dm_req, enet_dm_we;
    wire [31:0] enet_dm_addr, enet_dm_wdata;
    wire  [3:0] enet_dm_be;
    wire        tga_dm_req, tga_dm_we;
    wire [31:0] tga_dm_addr, tga_dm_wdata;
    wire  [3:0] tga_dm_be;
    reg   [1:0] dm_own;                 // 0 the 53C810, 1 the SIO, 2 the 21040, 3 the TGA
    reg         dm_busy;
    always @(posedge clk) begin
        if (rst) begin dm_busy <= 1'b0; dm_own <= 2'd0; end
        else if (!dm_busy) begin
            if (scsi_dm_req) begin dm_own <= 2'd0; dm_busy <= 1'b1; end
            else if (sio_dm_req) begin dm_own <= 2'd1; dm_busy <= 1'b1; end
            else if (enet_dm_req) begin dm_own <= 2'd2; dm_busy <= 1'b1; end
            else if (tga_dm_req) begin dm_own <= 2'd3; dm_busy <= 1'b1; end
        end else if (dm_ack) dm_busy <= 1'b0;
    end
    assign dmm_req   = dm_busy && (dm_own == 2'd3 ? tga_dm_req : dm_own == 2'd2 ? enet_dm_req :
                                  dm_own == 2'd1 ? sio_dm_req : scsi_dm_req) && !dm_ack;
    assign dmm_we    = dm_own == 2'd3 ? tga_dm_we    : dm_own == 2'd2 ? enet_dm_we    : dm_own == 2'd1 ? sio_dm_we    : scsi_dm_we;
    assign dmm_addr  = dm_own == 2'd3 ? tga_dm_addr  : dm_own == 2'd2 ? enet_dm_addr  : dm_own == 2'd1 ? sio_dm_addr  : scsi_dm_addr;
    assign dmm_be    = dm_own == 2'd3 ? tga_dm_be    : dm_own == 2'd2 ? enet_dm_be    : dm_own == 2'd1 ? sio_dm_be    : scsi_dm_be;
    assign dmm_wdata = dm_own == 2'd3 ? tga_dm_wdata : dm_own == 2'd2 ? enet_dm_wdata : dm_own == 2'd1 ? sio_dm_wdata : scsi_dm_wdata;
    wire        scsi_dm_ack = dm_ack && dm_own == 2'd0;
    wire        sio_dm_ack  = dm_ack && dm_own == 2'd1;
    wire        enet_dm_ack = dm_ack && dm_own == 2'd2;
    wire        tga_dm_ack  = dm_ack && dm_own == 2'd3;

    // the TGA (ZLXp-E1, PCI slot 1 = device 12, PIRQ1; rtl/tga, docs/design/tga.md)
    wire        tga_claim, tga_ack, tga_inta_n;
    wire [31:0] tga_rdata;
    tga #(.DEVNUM(5'd12)) tga (
        .clk(clk), .rst(rst),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_claim(tga_claim), .pt_ack(tga_ack), .pt_rdata(tga_rdata),
        .dm_req(tga_dm_req), .dm_we(tga_dm_we), .dm_addr(tga_dm_addr), .dm_be(tga_dm_be),
        .dm_wdata(tga_dm_wdata), .dm_ack(tga_dm_ack), .dm_rdata(dm_rdata),
        .inta_n(tga_inta_n), .stall(tdbg_stall),
        .vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_len(vr_len), .vr_be(vr_be), .vr_wdata(vr_wdata),
        .vr_ack(vr_ack), .vr_rvalid(vr_rvalid), .vr_rdata(vr_rdata),
        .sc_req(sc_req), .sc_addr(sc_addr), .sc_len(sc_len), .sc_ack(sc_ack), .sc_rvalid(sc_rvalid), .sc_rdata(sc_rdata),
        .clk_pix(clk_pix), .ce_pix(tga_ce), .hs(tga_hs), .vs(tga_vs), .de(tga_de), .hblank(tga_hb), .vblank(tga_vb),
        .r(tga_r), .g(tga_g), .b(tga_b), .video_on(tga_on),
        .dbg_rq(tdbg_rq), .dbg_rw(tdbg_rw), .dbg_ri(tdbg_ri), .dbg_rd(tdbg_rd), .dbg_fw(tdbg_fw), .dbg_fa(tdbg_fa), .dbg_fd(tdbg_fd), .dbg_fbe(tdbg_fbe), .dbg_mode(tdbg_mode), .dbg_st(tdbg_st)
    );

    // the 21040 Ethernet (device 11, IDSEL AD22, PIRQ0; rtl/net, docs/design/ethernet.md)
    wire        enet_claim, enet_ack, enet_inta_n;
    wire [31:0] enet_rdata;
    tulip21040 #(.DEVNUM(11)) enet (
        .clk(clk), .reset(rst),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_claim(enet_claim), .pt_ack(enet_ack), .pt_rdata(enet_rdata),
        .dm_req(enet_dm_req), .dm_we(enet_dm_we), .dm_addr(enet_dm_addr), .dm_be(enet_dm_be),
        .dm_wdata(enet_dm_wdata), .dm_ack(enet_dm_ack), .dm_rdata(dm_rdata),
        .inta_n(enet_inta_n), .mac(enet_mac), .link_up(enet_link_up),
        .nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata), .nb_ack(nb_ack), .nb_rdata(nb_rdata),
        .nb_pmac(nb_pmac), .nb_pmac_ok(nb_pmac_ok), .nb_link(nb_link)
    );
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
        .sb_ack(sb_ack), .sb_idata(sb_idata), .sb_ackhold(sb_ackhold), .sb_atn(sb_atn), .sb_rst(sb_rst),
        .sb_resel(sb_resel), .sb_resel_id(sb_resel_id), .sb_resel_ok(sb_resel_ok), .sb_resel_ack(sb_resel_ack),
        .tgt_st(tgt_st), .dbg_stb(ndbg_stb), .dbg_tag(ndbg_tag), .dbg_a(ndbg_a), .dbg_b(ndbg_b)
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
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_sub(pt_req && pt_cmd == 2'd1 && !scsi_claim && !enet_claim && !tga_claim),
        .pt_claim(sio_claim), .pt_ack(sio_ack), .pt_rdata(sio_rdata),
        .dm_req(sio_dm_req), .dm_we(sio_dm_we), .dm_addr(sio_dm_addr), .dm_be(sio_dm_be),
        .dm_wdata(sio_dm_wdata), .dm_ack(sio_dm_ack), .dm_rdata(dm_rdata),
        .pirq_n({scsi_inta_n, 1'b1, tga_inta_n, enet_inta_n}), .serr(1'b0), .iochk(1'b0),
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
        .year_ovr_en(year_ovr_en), .year_ovr(year_ovr), .console_mode(console_mode), .srm_con_mode(srm_con_mode),
        .cm_addr(cm_addr), .cm_we(cm_we), .cm_wdata(cm_wdata), .cm_rdata(cm_rdata), .cm_dirty(cm_dirty), .lpt_data(),
        .fd_mounted(fd_mounted), .fd_readonly(fd_readonly), .fd_size(fd_size),
        .fd_lba(fd_lba), .fd_blk_cnt(fd_blk_cnt), .fd_rd(fd_rd), .fd_wr(fd_wr), .fd_ack(fd_ack),
        .fd_buff_addr(sd_buff_addr), .fd_buff_dout(sd_buff_dout), .fd_buff_wr(sd_buff_wr),
        .fd_buff_din(fd_buff_din), .fd_led(fd_led)
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
        .clk(clk), .rst(rst), .clk_audio(clk_audio),
        .xio_addr(xio_addr), .xio_rd(xio_rd), .xio_wr(xio_wr), .xio_wdata(xio_wdata),
        .xio_claim(xio_claim), .xio_rdata(xio_rdata), .xio_irq(xio_irq), .xio_dreq(xio_dreq),
        .xio_dack(xio_dack), .xio_dack_ch(xio_dack_ch), .xio_dack_data(xio_dack_data),
        .xio_dev_data(xio_dev_data), .xio_dma_ch(xio_dma_ch), .xio_tc(xio_tc),
        .speaker(speaker), .cd_audio_l(cd_audio_l), .cd_audio_r(cd_audio_r), .cd_audio_stb(cd_audio_stb),
        .mute(4'd0), .aud_l(aud_l), .aud_r(aud_r), .aud_tgl(aud_tgl)
    );
    assign pt_claim = scsi_claim | sio_claim | enet_claim | tga_claim;
    assign pt_ack   = scsi_ack | sio_ack | enet_ack | tga_ack;
    assign pt_rdata = scsi_rdata | enet_rdata | tga_rdata | (sio_ack ? sio_rdata : 32'd0);
endmodule
