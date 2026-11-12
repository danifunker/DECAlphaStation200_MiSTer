// The Intel 82378IB System I/O (SIO) PCI-to-ISA bridge, PCI device 7 (IDSEL
// AD18), with the ISA devices of the AlphaStation 200 behind it
// (docs/design/sio.md, docs/design/pci.md 2, 4, 5):
//
//   PCI target (pci.md 2)  configuration space of device 7 function 0 (the
//                          82378's header and registers 40h-AFh), the PCI
//                          interrupt acknowledge (pt_cmd 3: the 8259s' vector,
//                          when PCICON IAE is set), and every I/O cycle no other
//                          device claims (pt_sub: the subtractive decode),
//                          split into ISA byte cycles, lowest enabled lane first
//   PCI master (pci.md 3)  the ISA DMA (isa_dma.v)
//   ISA ports              00-0F 80-8F C0-DF 40A 40B 410-43F 481-48B 4D4 4D6 DMA,
//                          20 21 A0 A1 4D0 4D1 PIC, 40-43 61 PIT and NMI status,
//                          60 64 8242 (UBCSA[1]), 70 71 BQ4285 (UBCSA[0]; port 70
//                          bit 7 is the SIO's NMI disable), 92 (UBCSB[6]), the
//                          PC87332 (isa_superio.v: 398 399, parallel port, the
//                          FDC isa_fdc.v on DMA channel 2) and its UARTs
//                          (ns16550.v) where its FER/FAR put them; anything else
//                          goes out on xio_* (sound), and reads 0xFF when nothing
//                          claims it
//   interrupts             8259 pair: 0 PIT, 1 keyboard, 3 COM2, 4 COM1, 6 FDC,
//                          7 parallel, 12 mouse, 13 DMA S/G, plus xio_irq and the
//                          PIRQ0-3 lines routed by registers 60h-63h; ISA IRQ8 is
//                          not connected (the TOY interrupt is CPU IRQ4: toy_irq)
//
// Outputs to the CPU (HARDWARE.md 3): intr (the 8259s' INT, IRQ2), nmi
// (IRQ3: PCI SERR# or ISA IOCHK#, gated by port 61 and port 70 bit 7),
// toy_irq (IRQ4), kbrst (the 8242's reset line, ORed with HALT into IRQ5).
//
// The revision ID is 43h (82378IB/ZB boards in AlphaStations report it; SRM
// V7.0 only checks it against 88h). The class code reads 000000h like the real
// part (Linux's alpha quirk_isa_bridge fixes it up).
module sio82378 #(
    parameter       CLK_HZ   = 100000000,
    parameter       RTC_FAST = 0,
    parameter [4:0] DEVNUM   = 5'd7,
    parameter [7:0] REVID    = 8'h43,
    parameter       FD_SPEED = 4        // the floppy drive's speed, times a real one (rtl/sio/isa_fdc.v)
) (
    input  wire        clk,
    input  wire        rst,

    // PCI target bus (pci.md 2)
    input  wire        pt_req,
    input  wire  [1:0] pt_cmd,         // 0 config, 1 I/O, 2 memory, 3 interrupt acknowledge
    input  wire  [4:0] pt_dev,
    input  wire [31:0] pt_addr,
    input  wire  [3:0] pt_be,
    input  wire        pt_we,
    input  wire [31:0] pt_wdata,
    input  wire        pt_sub,         // an I/O cycle no other device claims
    output wire        pt_claim,
    output reg         pt_ack,
    output reg  [31:0] pt_rdata,

    // PCI master: ISA DMA (pci.md 3)
    output wire        dm_req,
    output wire        dm_we,
    output wire [31:0] dm_addr,
    output wire  [3:0] dm_be,
    output wire [31:0] dm_wdata,
    input  wire        dm_ack,
    input  wire [31:0] dm_rdata,

    // interrupts
    input  wire  [3:0] pirq_n,         // PCI PIRQ0-3, active low
    input  wire        serr,           // PCI SERR# (asserted high here)
    input  wire        iochk,          // ISA IOCHK# (asserted high here)
    output reg         intr,           // CPU IRQ2 (all four from flip-flops)
    output reg         nmi,            // CPU IRQ3
    output reg         toy_irq,        // CPU IRQ4
    output reg         kbrst,          // CPU IRQ5 (with HALT)
    output wire        spk,            // the speaker (8254 counter 2 and port 61)

    // ISA devices outside this module
    output wire [15:0] xio_addr,
    output wire        xio_rd,
    output wire        xio_wr,
    output wire  [7:0] xio_wdata,
    input  wire        xio_claim,      // combinational from xio_addr
    input  wire  [7:0] xio_rdata,
    input  wire [15:0] xio_irq,
    input  wire  [7:0] xio_dreq,
    output wire        xio_dack,
    output wire  [2:0] xio_dack_ch,
    output wire [15:0] xio_dack_data,
    input  wire [15:0] xio_dev_data,
    output wire  [2:0] xio_dma_ch,
    output wire        xio_tc,

    // COM1, COM2 (PC87332 UARTs)
    output wire        com1_txd,
    input  wire        com1_rxd,
    output wire        com1_rts_n,
    output wire        com1_dtr_n,
    input  wire        com1_cts_n,
    input  wire        com1_dsr_n,
    input  wire        com1_ri_n,
    input  wire        com1_dcd_n,
    output wire        com1_tx_stb,
    output wire  [7:0] com1_tx_byte,
    input  wire        com1_rx_inj_stb,
    input  wire  [7:0] com1_rx_inj_byte,
    output wire        com2_txd,
    input  wire        com2_rxd,
    output wire        com2_rts_n,
    output wire        com2_dtr_n,
    input  wire        com2_cts_n,
    input  wire        com2_dsr_n,
    input  wire        com2_ri_n,
    input  wire        com2_dcd_n,

    // keyboard and mouse (hps_io)
    input  wire [10:0] ps2_key,
    input  wire [24:0] ps2_mouse,

    // TOY (hps_io rtc; OSD year override)
    input  wire [64:0] rtc,
    input  wire        year_ovr_en,
    input  wire  [6:0] year_ovr,
    input  wire  [1:0] console_mode,    // OSD Console: 0 NVRAM file, 1 SRM, 2 ARC (rtl/sio/isa_rtc.v)
    input  wire  [1:0] srm_con_mode,    // OSD SRM console: 0 Graphics, 1 Serial, 2 NVRAM file (CMOS 17h)
    input  wire  [6:0] cm_addr,         // the TOY CMOS's save port (rtl/mister/nvsave.v)
    input  wire        cm_we,
    input  wire  [7:0] cm_wdata,
    output wire  [7:0] cm_rdata,
    output wire        cm_dirty,

    // the floppy drive A:'s image: hps_io block device slot 3 (rtl/sio/isa_fdc_img.v)
    input  wire        fd_mounted,      // img_mounted[3]
    input  wire        fd_readonly,     // img_readonly (valid with fd_mounted)
    input  wire [63:0] fd_size,         // img_size (valid with fd_mounted)
    output wire [31:0] fd_lba,          // sd_lba[3]
    output wire  [5:0] fd_blk_cnt,      // sd_blk_cnt[3]
    output wire        fd_rd,           // sd_rd[3]
    output wire        fd_wr,           // sd_wr[3]
    input  wire        fd_ack,          // sd_ack[3]
    input  wire [13:0] fd_buff_addr,    // sd_buff_addr
    input  wire  [7:0] fd_buff_dout,    // sd_buff_dout
    input  wire        fd_buff_wr,      // sd_buff_wr
    output wire  [7:0] fd_buff_din,     // sd_buff_din[3]
    output wire        fd_led,          // a floppy command is running (the disk LED)

    output wire  [7:0] lpt_data
);
    // ================================================================ configuration space
    // registers 40h-AFh, kept in a small array: 40-4F -> 0-15, 54-57 -> 16-19,
    // 60-63 -> 20-23, 80-81 -> 24-25, A0-AF -> 32-47 (82378 data sheet; DEC's
    // i82378_def.h for the defaults of 40, 48, 4C-4F)
    function [6:0] cidx;                // {valid, index}
        input [7:0] o;
        if (o[7:4] == 4'h4)                      cidx = {1'b1, 2'b00, o[3:0]};
        else if (o[7:2] == 6'b010101)            cidx = {1'b1, 4'b0100, o[1:0]};   // 54-57
        else if (o[7:2] == 6'b011000)            cidx = {1'b1, 4'b0101, o[1:0]};   // 60-63
        else if (o[7:1] == 7'b1000000)           cidx = {1'b1, 5'b01100, o[0]};    // 80-81
        else if (o[7:4] == 4'hA)                 cidx = {1'b1, 2'b10, o[3:0]};
        else                                     cidx = 7'd0;
    endfunction
    function [7:0] cdef;                // the value out of reset
        input [5:0] i;
        case (i)
        6'd0:  cdef = 8'h20;            // 40 PCICON: interrupt acknowledge enable
        6'd2:  cdef = 8'h04;            // 42 PAPC
        6'd5:  cdef = 8'h10;            // 45 MCSBOH
        6'd6:  cdef = 8'h0F;            // 46 MCSTOH
        6'd8:  cdef = 8'h01;            // 48 IADCON
        6'd10: cdef = 8'h10;            // 4A IADBOH
        6'd11: cdef = 8'h0F;            // 4B IADTOH
        6'd12: cdef = 8'h56;            // 4C ICRT
        6'd13: cdef = 8'h40;            // 4D ICD
        6'd14: cdef = 8'h07;            // 4E UBCSA: RTC, keyboard, floppy 3F2-3F7
        6'd15: cdef = 8'h4F;            // 4F UBCSB
        6'd20, 6'd21, 6'd22, 6'd23: cdef = 8'h80;   // 60-63 PIRQ route: disabled
        6'd24: cdef = 8'h78;            // 80 BTMR
        6'd32: cdef = 8'h08;            // A0 SMICNTL
        6'd40: cdef = 8'h0F;            // A8 FTMR
        default: cdef = 8'h00;
        endcase
    endfunction
    function [7:0] cmask;               // the writable bits
        input [5:0] i;
        case (i)
        6'd0:  cmask = 8'h7F;
        6'd1:  cmask = 8'h1F;
        6'd3:  cmask = 8'h00;           // 43 reserved
        6'd9:  cmask = 8'hFF;
        6'd20, 6'd21, 6'd22, 6'd23: cmask = 8'h8F;
        6'd24: cmask = 8'hFD;
        6'd33, 6'd41, 6'd45, 6'd47: cmask = 8'h00;  // A1, A9, AD, AF reserved
        default: cmask = i < 6'd26 || (i >= 6'd32 && i < 6'd48) ? 8'hFF : 8'h00;
        endcase
    endfunction

    reg [7:0] cr [0:47];
    reg       sce;                      // PCICMD special cycle enable

    function [7:0] hdr;                 // header bytes 00-3F
        input [5:0] o; input s;
        case (o)
        6'h00: hdr = 8'h86; 6'h01: hdr = 8'h80;         // vendor 8086
        6'h02: hdr = 8'h84; 6'h03: hdr = 8'h04;         // device 0484
        6'h04: hdr = {4'h0, s, 3'b111};                 // PCICMD: I/O, memory, master always on
        6'h07: hdr = 8'h02;                             // PCISTS: DEVSEL medium
        6'h08: hdr = REVID;
        default: hdr = 8'h00;                           // class 000000, header type 0
        endcase
    endfunction

    function [7:0] cbyte;
        input [7:0] o;
        reg [6:0] ci;
        begin
            ci = cidx(o);
            if (o[7:6] == 2'b00) cbyte = hdr(o[5:0], sce);
            else if (ci[6]) cbyte = cr[ci[5:0]];
            else cbyte = 8'h00;
        end
    endfunction

    wire [7:0] cfg_off = {pt_addr[7:2], 2'b00};
    wire [31:0] cfg_rd = {cbyte(cfg_off | 8'd3), cbyte(cfg_off | 8'd2), cbyte(cfg_off | 8'd1), cbyte(cfg_off)};

    wire [7:0] pcicon = cr[0];
    wire [7:0] ubcsa  = cr[14];
    wire [7:0] ubcsb  = cr[15];

    // ================================================================ the PCI target
    wire cfg_hit  = pt_cmd == 2'd0 && pt_dev == DEVNUM && pt_addr[10:8] == 3'd0;
    wire iack_hit = pt_cmd == 2'd3 && pcicon[5];
    wire io_hit   = pt_cmd == 2'd1 && pt_sub;
    assign pt_claim = pt_req && (cfg_hit || iack_hit || io_hit);

    reg        busy;                    // this transaction taken, until pt_req drops
    reg        io_act;                  // ISA byte cycles in progress
    reg  [3:0] lanes;                   // the byte lanes still to do
    wire       start = pt_claim && !busy;
    wire [1:0] lane  = lanes[0] ? 2'd0 : lanes[1] ? 2'd1 : lanes[2] ? 2'd2 : 2'd3;
    wire [3:0] lane_bit = 4'b0001 << lane;

    // the ISA bus
    wire [15:0] io_addr = {pt_addr[15:2], lane};
    wire        io_stb  = io_act && lanes != 4'd0;
    wire        io_rd   = io_stb && !pt_we;
    wire        io_wr   = io_stb && pt_we;
    wire  [7:0] io_din  = pt_wdata[8*lane +: 8];
    reg   [7:0] isa_q;                  // the byte read (below)
    wire        iack    = start && pt_cmd == 2'd3 && !pt_we;
    wire  [7:0] iack_vec;

    integer i;
    always @(posedge clk) begin
        pt_ack <= 1'b0;
        if (!pt_req) busy <= 1'b0;
        if (start) begin
            busy <= 1'b1;
            if (cfg_hit) begin
                pt_rdata <= cfg_rd;
                if (pt_we) begin
                    for (i = 0; i < 4; i = i + 1) if (pt_be[i]) begin : wr_byte
                        reg [7:0] o; reg [6:0] ci;
                        o  = cfg_off | i[7:0];
                        ci = cidx(o);
                        if (ci[6]) cr[ci[5:0]] <= (cr[ci[5:0]] & ~cmask(ci[5:0])) | (pt_wdata[8*i +: 8] & cmask(ci[5:0]));
                        if (o == 8'h04) sce <= pt_wdata[8*i + 3];
                    end
                end
                pt_ack <= 1'b1;
            end else if (pt_cmd == 2'd3) begin
                pt_rdata <= {24'd0, iack_vec};
                pt_ack <= 1'b1;
            end else begin
                pt_rdata <= 32'hFFFFFFFF;
                if (pt_be == 4'd0) pt_ack <= 1'b1;
                else begin io_act <= 1'b1; lanes <= pt_be; end
            end
        end
        if (io_stb) begin
            pt_rdata[8*lane +: 8] <= isa_q;
            lanes <= lanes & ~lane_bit;
            if ((lanes & ~lane_bit) == 4'd0) begin io_act <= 1'b0; pt_ack <= 1'b1; end
        end
        if (rst) begin
            busy <= 1'b0; io_act <= 1'b0; lanes <= 4'd0; sce <= 1'b0;
            for (i = 0; i < 48; i = i + 1) cr[i] <= cdef(i[5:0]);
        end
    end

    // ================================================================ ISA devices
    // the UARTs' 1.8432 MHz
    reg [31:0] baud_acc;
    reg        ce_1m8;
    always @(posedge clk) begin
        if (baud_acc + 32'd1843200 >= CLK_HZ) begin
            baud_acc <= baud_acc + 32'd1843200 - CLK_HZ; ce_1m8 <= 1'b1;
        end else begin
            baud_acc <= baud_acc + 32'd1843200; ce_1m8 <= 1'b0;
        end
        if (rst) begin baud_acc <= 32'd0; ce_1m8 <= 1'b0; end
    end

    wire [15:0] a = io_addr;
    wire        sup_claim;
    wire        uart1_on, uart2_on;
    wire [15:3] uart1_base, uart2_base;

    wire s_dma  = a[15:4] == 12'h000 || a[15:4] == 12'h008 || a[15:5] == 11'h006 ||
                  a == 16'h040A || a == 16'h040B || (a >= 16'h0410 && a <= 16'h043F) ||
                  a[15:4] == 12'h048 || a == 16'h04D4 || a == 16'h04D6;
    wire s_pic  = a == 16'h0020 || a == 16'h0021 || a == 16'h00A0 || a == 16'h00A1 ||
                  a == 16'h04D0 || a == 16'h04D1;
    wire s_pit  = a[15:2] == 14'h0010 || a == 16'h0061;
    wire s_kbc  = ubcsa[1] && (a == 16'h0060 || a == 16'h0064);
    wire s_rtc  = ubcsa[0] && a[15:1] == 15'h0038;
    wire s_p92  = ubcsb[6] && a == 16'h0092;
    wire s_com1 = uart1_on && a[15:3] == uart1_base;
`ifdef AS200_NOCOM2
    wire s_com2 = 1'b0;                 // built without COM2 (below): its ports are not claimed
`else
    wire s_com2 = uart2_on && a[15:3] == uart2_base && !s_com1;
`endif
    wire s_sup  = sup_claim;
    wire s_x    = xio_claim && !(s_dma || s_pic || s_pit || s_kbc || s_rtc || s_p92 || s_com1 || s_com2 || s_sup);

    wire [7:0] q_dma, q_pic, q_pit, q_kbc, q_rtc, q_com1, q_com2, q_sup;
    reg  [7:0] p92;
    always @* begin
        isa_q = 8'hFF;
        if (s_dma)       isa_q = q_dma;
        else if (s_pic)  isa_q = q_pic;
        else if (s_pit)  isa_q = q_pit;
        else if (s_kbc)  isa_q = q_kbc;
        else if (s_rtc)  isa_q = q_rtc;
        else if (s_p92)  isa_q = p92;
        else if (s_com1) isa_q = q_com1;
        else if (s_com2) isa_q = q_com2;
        else if (s_sup)  isa_q = q_sup;
        else if (s_x)    isa_q = xio_rdata;
    end

    assign xio_addr  = a;
    assign xio_rd    = io_rd && s_x;
    assign xio_wr    = io_wr && s_x;
    assign xio_wdata = io_din;

    // ---------------------------------------------------------------- NMI (port 61, port 70 bit 7)
    reg        nmi_dis;                 // port 70 bit 7
    reg        serr_st, iochk_st;
    wire [3:0] p61;
    always @(posedge clk) begin
        if (io_wr && a == 16'h0070) nmi_dis <= io_din[7];
        if (io_wr && s_p92) p92 <= {6'd0, io_din[1:0]};
        serr_st  <= (serr_st  | serr)  & ~p61[2];
        iochk_st <= (iochk_st | iochk) & ~p61[3];
        if (rst) begin nmi_dis <= 1'b1; serr_st <= 1'b0; iochk_st <= 1'b0; p92 <= 8'h00; end
    end
    wire pic_intr, toy_int, kbc_rst;
    // the CPU's interrupt lines come straight from flip-flops (timing: nothing of the
    // 8259's, the TOY's or the 8242's logic reaches the CPU in the same cycle)
    always @(posedge clk) begin
        intr    <= pic_intr && !rst;
        nmi     <= !nmi_dis && (serr_st || iochk_st) && !rst;
        toy_irq <= toy_int && !rst;
        kbrst   <= kbc_rst && !rst;
    end

    // ---------------------------------------------------------------- interrupts
    wire irq0, irq1, irq12, irq_fdc, irq_lpt, sg_irq, com1_irq, com2_irq;
    reg [15:0] pirq_irq;
    always @* begin
        pirq_irq = 16'd0;
        for (i = 0; i < 4; i = i + 1)
            if (!cr[20 + i][7] && !pirq_n[i])
                case (cr[20 + i][3:0])
                4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd9, 4'd10, 4'd11, 4'd12, 4'd14, 4'd15:
                    pirq_irq[cr[20 + i][3:0]] = 1'b1;
                default: ;
                endcase
    end
    // ISA IRQ2 is the cascade, IRQ8 and IRQ13 have no ISA pin (13 is the DMA's S/G interrupt)
    wire [15:0] int_irq = {2'b00, sg_irq, irq12, 3'b000, 1'b0, irq_lpt, irq_fdc, 1'b0, com1_irq, com2_irq, 1'b0, irq1, irq0};
    wire [15:0] isa_irq = int_irq | (xio_irq & 16'hDEFB) | pirq_irq;

    isa_pic pic (
        .clk(clk), .rst(rst),
        .io_addr(a), .io_rd(io_rd && s_pic), .io_wr(io_wr && s_pic), .io_din(io_din), .io_dout(q_pic),
        .iack(iack), .iack_vec(iack_vec),
        .irq(isa_irq), .intr(pic_intr)
    );

    isa_pit #(.CLK_HZ(CLK_HZ)) pit (
        .clk(clk), .rst(rst),
        .io_addr(a), .io_rd(io_rd && s_pit), .io_wr(io_wr && s_pit), .io_din(io_din), .io_dout(q_pit),
        .serr_st(serr_st), .iochk_st(iochk_st), .p61(p61),
        .irq0(irq0), .spk(spk)
    );

    // DMA channel 2 is also the FDC's (the PC87332's DRQ2/DACK2): its request ORed in, its byte
    // in place of xio_dev_data while it requests
    wire       fdc_dreq;
    wire [7:0] fdc_dma_q;
    isa_dma dma (
        .clk(clk), .rst(rst),
        .io_addr(a), .io_rd(io_rd && s_dma), .io_wr(io_wr && s_dma), .io_din(io_din), .io_dout(q_dma),
        .dreq(xio_dreq | {5'd0, fdc_dreq, 2'd0}), .dack(xio_dack), .dack_ch(xio_dack_ch), .dack_data(xio_dack_data),
        .dev_data(fdc_dreq && xio_dma_ch == 3'd2 ? {8'h00, fdc_dma_q} : xio_dev_data),
        .dev_ch(xio_dma_ch), .tc(xio_tc), .sg_irq(sg_irq),
        .dm_req(dm_req), .dm_we(dm_we), .dm_addr(dm_addr), .dm_be(dm_be), .dm_wdata(dm_wdata),
        .dm_ack(dm_ack), .dm_rdata(dm_rdata)
    );

    isa_kbc #(.CLK_HZ(CLK_HZ)) kbc (
        .clk(clk), .rst(rst),
        .io_addr(a), .io_rd(io_rd && s_kbc), .io_wr(io_wr && s_kbc), .io_din(io_din), .io_dout(q_kbc),
        .irq1(irq1), .irq12(irq12), .kbrst(kbc_rst),
        .ps2_key(ps2_key), .ps2_mouse(ps2_mouse)
    );

    isa_rtc #(.CLK_HZ(CLK_HZ), .FAST(RTC_FAST)) toy (
        .clk(clk), .rst(rst),
        .io_addr(a), .io_rd(io_rd && s_rtc), .io_wr(io_wr && s_rtc), .io_din(io_din), .io_dout(q_rtc),
        .irq(toy_int),
        .rtc(rtc), .year_ovr_en(year_ovr_en), .year_ovr(year_ovr), .console_mode(console_mode), .srm_con_mode(srm_con_mode),
        .cm_addr(cm_addr), .cm_we(cm_we), .cm_wdata(cm_wdata), .cm_rdata(cm_rdata), .cm_dirty(cm_dirty)
    );

    isa_superio #(.CLK_HZ(CLK_HZ), .FD_SPEED(FD_SPEED)) superio (
        .clk(clk), .rst(rst),
        .io_addr(a), .io_rd(io_rd && s_sup), .io_wr(io_wr && s_sup), .io_din(io_din), .io_dout(q_sup),
        .claim(sup_claim),
        .uart1_on(uart1_on), .uart1_base(uart1_base), .uart2_on(uart2_on), .uart2_base(uart2_base),
        .irq_fdc(irq_fdc), .irq_lpt(irq_lpt), .lpt_data(lpt_data),
        .fdc_dreq(fdc_dreq), .fdc_dma_q(fdc_dma_q), .fdc_dack(xio_dack && xio_dack_ch == 3'd2),
        .fdc_dack_data(xio_dack_data[7:0]), .fdc_tc(xio_tc), .fdc_led(fd_led),
        .fd_mounted(fd_mounted), .fd_readonly(fd_readonly), .fd_size(fd_size),
        .fd_lba(fd_lba), .fd_blk_cnt(fd_blk_cnt), .fd_rd(fd_rd), .fd_wr(fd_wr), .fd_ack(fd_ack),
        .fd_buff_addr(fd_buff_addr), .fd_buff_dout(fd_buff_dout), .fd_buff_wr(fd_buff_wr), .fd_buff_din(fd_buff_din)
    );

    // the UARTs' interrupt outputs are enabled by their MCR OUT2, as on a PC
    wire com1_out2_n, com2_out2_n, com1_int, com2_int;
    assign com1_irq = com1_int && !com1_out2_n;
    assign com2_irq = com2_int && !com2_out2_n;

    ns16550 com1 (
        .clk(clk), .rst(rst), .ce_1m8(ce_1m8),
        .io_addr(a[2:0]), .io_rd(io_rd && s_com1), .io_wr(io_wr && s_com1), .io_din(io_din), .io_dout(q_com1),
        .irq(com1_int),
        .txd(com1_txd), .rxd(com1_rxd), .rts_n(com1_rts_n), .dtr_n(com1_dtr_n), .out1_n(), .out2_n(com1_out2_n),
        .cts_n(com1_cts_n), .dsr_n(com1_dsr_n), .ri_n(com1_ri_n), .dcd_n(com1_dcd_n),
        .tx_stb(com1_tx_stb), .tx_byte(com1_tx_byte), .rx_inj_stb(com1_rx_inj_stb), .rx_inj_byte(com1_rx_inj_byte)
    );

    // AS200_NOCOM2 (a VERILOG_MACRO in the QSF) builds the machine without COM2: the MiSTer
    // gives it no pins, and the logic is wanted for timing. The benches keep it.
`ifdef AS200_NOCOM2
    assign q_com2 = 8'hFF;
    assign com2_int = 1'b0;
    assign com2_out2_n = 1'b1;
    assign com2_txd = 1'b1;
    assign com2_rts_n = 1'b1;
    assign com2_dtr_n = 1'b1;
`else
    ns16550 com2 (
        .clk(clk), .rst(rst), .ce_1m8(ce_1m8),
        .io_addr(a[2:0]), .io_rd(io_rd && s_com2), .io_wr(io_wr && s_com2), .io_din(io_din), .io_dout(q_com2),
        .irq(com2_int),
        .txd(com2_txd), .rxd(com2_rxd), .rts_n(com2_rts_n), .dtr_n(com2_dtr_n), .out1_n(), .out2_n(com2_out2_n),
        .cts_n(com2_cts_n), .dsr_n(com2_dsr_n), .ri_n(com2_ri_n), .dcd_n(com2_dcd_n),
        .tx_stb(), .tx_byte(), .rx_inj_stb(1'b0), .rx_inj_byte(8'h00)
    );
`endif
endmodule
