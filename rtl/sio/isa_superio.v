// The National PC87332 Super I/O III's own parts (docs/design/sio.md): its
// configuration registers behind the index (398h) and data (399h) ports,
// the parallel port, and a floppy controller STUB. Its two UARTs are
// rtl/sio/ns16550.v, placed by the SIO top at the addresses this module's
// configuration gives (uart*_on / uart*_base). The configuration and the
// parallel port are ported from the user's IBM RS/6000 core
// (IBMRS6K7248_sio.sv, written there for the PC87312, GPL-2) and extended to
// the PC87332's register set:
//
//   0 FER  function enable: [0] parallel, [1] UART 1, [2] UART 2, [3] FDC,
//          [5] FDC at 370h (else 3F0h), [6] IDE, [7] IDE at 170h
//   1 FAR  function address: [1:0] parallel (378h, 3BCh, 278h), [3:2] UART 1
//          and [5:4] UART 2 (COM1 3F8h, COM2 2F8h, COM3, COM4), [7:6] which
//          addresses COM3/COM4 are
//   2 PTR  power and test   3 FCR function control   4 PCR printer control
//   5 KRR  keyboard and RTC control   6 PMC power management   7 TUP tape,
//          UART and parallel   (3-7 stored, read back)
//   8 SID  identification, read only: 1xh (the PC87332)
//   9+     read 00h
// The index reads back as written (any write takes; the chip's two-writes
// rule is not enforced). Out of reset: FER 0Fh, FAR 10h (parallel 378h,
// UART 1 COM1, UART 2 COM2, FDC 3F0h, IDE off), the rest 00h: the
// AlphaStation's jumper-strapped configuration (assumed; J22/J24).
//
// The parallel port: the data latch read back, a status of "not busy,
// selected, no error" (DFh: nothing attached that ever acknowledges), the
// control register stored. No EPP/ECP, no interrupt.
//
// The FDC is rtl/sio/isa_fdc.v (an 82077AA with drive A: on the OSD's floppy
// image, docs/design/floppy.md) at 3F0h-3F7h (or 370h-377h: FER[5]), less x6
// (the IDE's): IRQ 6 and DMA channel 2 (fdc_dreq/fdc_dack into the SIO's
// 8237), its image on hps_io slot 3 (fd_*).
//
// Bus (pci.md 5): claim is combinational from io_addr (the ports this chip
// decodes as configured, its UARTs excepted); io_rd/io_wr are the SIO's
// one-cycle strobes, already qualified by claim; io_dout combinational, the
// side effects of a read (FIFO results) on the io_rd clock.
module isa_superio #(
    parameter CLK_HZ   = 100000000,
    parameter FD_SPEED = 4             // the floppy drive's speed, times a real one (isa_fdc.v)
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output reg   [7:0] io_dout,
    output wire        claim,

    output wire        uart1_on,
    output wire [15:3] uart1_base,
    output wire        uart2_on,
    output wire [15:3] uart2_base,
    output wire        irq_fdc,       // IRQ6
    output wire        irq_lpt,       // IRQ7 (or 5: PTR[3]); never raised
    output wire  [7:0] lpt_data,      // the parallel port's data latch (progress codes, if any)

    // the FDC's DMA channel 2 (rtl/sio/isa_dma.v)
    output wire        fdc_dreq,
    output wire  [7:0] fdc_dma_q,     // the byte for a write-to-memory transfer
    input  wire        fdc_dack,      // channel 2's transfer done
    input  wire  [7:0] fdc_dack_data,
    input  wire        fdc_tc,
    output wire        fdc_led,

    // drive A:'s image (hps_io slot 3)
    input  wire        fd_mounted,
    input  wire        fd_readonly,
    input  wire [63:0] fd_size,
    output wire [31:0] fd_lba,
    output wire  [5:0] fd_blk_cnt,
    output wire        fd_rd,
    output wire        fd_wr,
    input  wire        fd_ack,
    input  wire [13:0] fd_buff_addr,
    input  wire  [7:0] fd_buff_dout,
    input  wire        fd_buff_wr,
    output wire  [7:0] fd_buff_din
);

    // ---------------------------------------------------------------- configuration
    reg [7:0] fer, far_r, ptr, fcr, pcr, krr, pmc, tup;
    reg [7:0] index;

    function [15:3] uart_at;
        input [1:0] which; input [1:0] com34;
        case (which)
        2'd0: uart_at = 13'h007F;                                   // 3F8
        2'd1: uart_at = 13'h005F;                                   // 2F8
        2'd2: case (com34)                                          // COM3: 3E8, 338, 2E8, 220
            2'd0: uart_at = 13'h007D; 2'd1: uart_at = 13'h0067; 2'd2: uart_at = 13'h005D; default: uart_at = 13'h0044;
        endcase
        default: case (com34)                                       // COM4: 2E8, 238, 2E0, 228
            2'd0: uart_at = 13'h005D; 2'd1: uart_at = 13'h0047; 2'd2: uart_at = 13'h005C; default: uart_at = 13'h0045;
        endcase
        endcase
    endfunction

    assign uart1_on   = fer[1];
    assign uart1_base = uart_at(far_r[3:2], far_r[7:6]);
    assign uart2_on   = fer[2];
    assign uart2_base = uart_at(far_r[5:4], far_r[7:6]);
    wire [15:2] lpt_base = far_r[1:0] == 2'd0 ? 14'h00DE : far_r[1:0] == 2'd1 ? 14'h00EF : 14'h009E;  // 378, 3BC, 278
    wire        fdc_on   = fer[3];
    wire [15:3] fdc_base = fer[5] ? 13'h006E : 13'h007E;          // 370 / 3F0

    wire cfg_sel = io_addr[15:1] == 15'h01CC;                       // 398, 399
    wire lpt_sel = fer[0] && far_r[1:0] != 2'd3 && io_addr[15:2] == lpt_base && io_addr[1:0] != 2'd3;
    wire fdc_sel = fdc_on && io_addr[15:3] == fdc_base && io_addr[2:0] != 3'd6;   // x6: the IDE's
    assign claim = cfg_sel || lpt_sel || fdc_sel;

    reg [7:0] cfg_q;
    always @* begin
        case (index)
        8'd0: cfg_q = fer;   8'd1: cfg_q = far_r; 8'd2: cfg_q = ptr;  8'd3: cfg_q = fcr;
        8'd4: cfg_q = pcr;   8'd5: cfg_q = krr;   8'd6: cfg_q = pmc;  8'd7: cfg_q = tup;
        8'd8: cfg_q = 8'h10;                                        // SID: PC87332
        default: cfg_q = 8'h00;
        endcase
    end

    // ---------------------------------------------------------------- parallel port
    reg [7:0] lpt_d, lpt_ctl;
    assign lpt_data = lpt_d;
    assign irq_lpt  = 1'b0;

    // ---------------------------------------------------------------- FDC
    wire [7:0] fdc_q;
    isa_fdc #(.CLK_HZ(CLK_HZ), .SPEED(FD_SPEED)) fdc (
        .clk(clk), .rst(rst),
        .io_off(io_addr[2:0]), .io_rd(io_rd && fdc_sel), .io_wr(io_wr && fdc_sel), .io_din(io_din), .io_dout(fdc_q),
        .irq(irq_fdc),
        .dreq(fdc_dreq), .dma_q(fdc_dma_q), .dack(fdc_dack), .dack_data(fdc_dack_data), .tc(fdc_tc), .led(fdc_led),
        .img_mounted(fd_mounted), .img_readonly(fd_readonly), .img_size(fd_size),
        .sd_lba(fd_lba), .sd_blk_cnt(fd_blk_cnt), .sd_rd(fd_rd), .sd_wr(fd_wr), .sd_ack(fd_ack),
        .sd_buff_addr(fd_buff_addr), .sd_buff_dout(fd_buff_dout), .sd_buff_wr(fd_buff_wr), .sd_buff_din(fd_buff_din)
    );

    always @* begin
        io_dout = 8'hFF;
        if (cfg_sel) io_dout = io_addr[0] ? cfg_q : index;
        else if (lpt_sel) io_dout = io_addr[1:0] == 2'd0 ? lpt_d : io_addr[1:0] == 2'd1 ? 8'hDF : lpt_ctl;
        else if (fdc_sel) io_dout = fdc_q;
    end

    always @(posedge clk) begin
        // configuration
        if (io_wr && cfg_sel) begin
            if (!io_addr[0]) index <= io_din;
            else case (index)
                8'd0: fer <= io_din;   8'd1: far_r <= io_din; 8'd2: ptr <= io_din; 8'd3: fcr <= io_din;
                8'd4: pcr <= io_din;   8'd5: krr <= io_din;   8'd6: pmc <= io_din; 8'd7: tup <= io_din;
                default: ;
            endcase
        end
        // parallel port
        if (io_wr && lpt_sel) begin
            if (io_addr[1:0] == 2'd0) lpt_d   <= io_din;
            if (io_addr[1:0] == 2'd2) lpt_ctl <= io_din;
        end

        if (rst) begin
            fer <= 8'h0F; far_r <= 8'h10; ptr <= 8'h00; fcr <= 8'h00; pcr <= 8'h00; krr <= 8'h00;
            pmc <= 8'h00; tup <= 8'h00; index <= 8'h00;
            lpt_d <= 8'h00; lpt_ctl <= 8'h0C;
        end
    end
endmodule
