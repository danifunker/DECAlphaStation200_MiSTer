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
// The FDC is a STUB of an 82077AA with one drive that never has a medium,
// enough for the probes the console firmware makes (dva0 shows, a boot from
// it fails cleanly): DOR (with the reset and its interrupt, answered by four
// SENSE INTERRUPTs), MSR/DSR, TDR, DIR (disk changed), CCR, and the command
// FIFO with every command's parameter and result counts: VERSION 90h,
// SPECIFY, CONFIGURE, LOCK, DUMPREG, PERPENDICULAR, SENSE DRIVE STATUS,
// RECALIBRATE and SEEK (completing at once, IRQ6, SENSE INTERRUPT's seek
// end), and READ/WRITE/VERIFY/FORMAT/READ ID/SCAN ending with an abnormal
// termination, missing address mark (no DMA). The real FDC with the floppy
// image comes later (docs/REUSE.md: IBMRS6K7248_fdc.sv).
//
// Bus (pci.md 5): claim is combinational from io_addr (the ports this chip
// decodes as configured, its UARTs excepted); io_rd/io_wr are the SIO's
// one-cycle strobes, already qualified by claim; io_dout combinational, the
// side effects of a read (FIFO results) on the io_rd clock.
module isa_superio (
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
    output wire  [7:0] lpt_data       // the parallel port's data latch (progress codes, if any)
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

    // ---------------------------------------------------------------- FDC stub
    reg  [7:0] dor, tdr, dsr, ccr;
    reg  [4:0] fcmd;                    // the command being collected (low 5 bits)
    reg  [3:0] np;                      // parameter bytes still wanted
    reg  [3:0] nr;                      // result bytes still to read
    reg  [3:0] rp;                      // the next result byte's number
    reg  [2:0] pc;                      // the next parameter's number
    reg  [7:0] prm0, prm1, prm2, prm3, prm4;   // the parameters kept (drive/head, C, H, R, N)
    reg  [7:0] st0, pcn;
    reg  [7:0] cyl;                     // the drive's cylinder
    reg  [2:0] rst_sense;               // SENSE INTERRUPTs owed after a reset (4 .. 0)
    reg        seek_int;                // a seek/recalibrate ended: SENSE INTERRUPT reports it
    reg        fint;                    // the interrupt line's state
    reg        lock;
    reg  [7:0] cfg_fifo, cfg_pre;

    // parameter and result counts by command
    function [7:0] cmd_counts;          // {params, results}
        input [4:0] c;
        case (c)
        5'h02, 5'h05, 5'h06, 5'h09, 5'h0C, 5'h11, 5'h16, 5'h19, 5'h1D: cmd_counts = {4'd8, 4'd7};
        5'h03: cmd_counts = {4'd2, 4'd0};       // SPECIFY
        5'h04: cmd_counts = {4'd1, 4'd1};       // SENSE DRIVE STATUS
        5'h07: cmd_counts = {4'd1, 4'd0};       // RECALIBRATE
        5'h08: cmd_counts = {4'd0, 4'd2};       // SENSE INTERRUPT (1 when nothing is pending)
        5'h0A: cmd_counts = {4'd1, 4'd7};       // READ ID
        5'h0D: cmd_counts = {4'd5, 4'd7};       // FORMAT
        5'h0E: cmd_counts = {4'd0, 4'd10};      // DUMPREG
        5'h0F: cmd_counts = {4'd2, 4'd0};       // SEEK
        5'h10: cmd_counts = {4'd0, 4'd1};       // VERSION
        5'h12: cmd_counts = {4'd1, 4'd0};       // PERPENDICULAR
        5'h13: cmd_counts = {4'd3, 4'd0};       // CONFIGURE
        5'h14: cmd_counts = {4'd0, 4'd1};       // LOCK
        default: cmd_counts = {4'd0, 4'd1};     // invalid: ST0 = 80h
        endcase
    endfunction

    wire       f_busy = np != 4'd0 || nr != 4'd0;
    wire [7:0] msr    = {1'b1, nr != 4'd0, 1'b0, f_busy, 4'h0};
    reg  [7:0] fres;                    // the result byte rp
    always @* begin
        fres = 8'h00;
        case (fcmd)
        5'h08: fres = rp == 4'd0 ? st0 : pcn;
        5'h04: fres = {1'b0, 1'b0, 1'b1, cyl == 8'd0, 1'b1, prm0[2:0]};   // ST3: ready, track 0, two-sided
        5'h10: fres = 8'h90;                                                // VERSION: 82077AA
        5'h14: fres = {3'd0, lock, 4'd0};
        5'h0E: case (rp)                                                    // DUMPREG
            4'd0: fres = cyl; 4'd1: fres = 8'd0; 4'd2: fres = 8'd0; 4'd3: fres = 8'd0;
            4'd4: fres = 8'd0; 4'd5: fres = 8'd0; 4'd6: fres = 8'd0; 4'd7: fres = {lock, 7'd0};
            4'd8: fres = cfg_fifo; default: fres = cfg_pre;
        endcase
        5'h02, 5'h05, 5'h06, 5'h09, 5'h0A, 5'h0C, 5'h0D, 5'h11, 5'h16, 5'h19, 5'h1D:
            case (rp)                                                       // no medium
            4'd0: fres = {2'b01, 3'b000, prm0[2:0]};                        // ST0: abnormal termination
            4'd1: fres = 8'h01;                                             // ST1: missing address mark
            4'd2: fres = 8'h00;                                             // ST2
            4'd3: fres = prm1; 4'd4: fres = prm2; 4'd5: fres = prm3; default: fres = prm4;
            endcase
        default: fres = 8'h80;                                              // invalid
        endcase
    end

    wire [2:0] f_reg  = io_addr[2:0];
    wire       f_wr   = io_wr && fdc_sel;
    wire       f_rd   = io_rd && fdc_sel;
    wire [7:0] cc_now = cmd_counts(io_din[4:0]);
    wire [2:0] rst_drv = 3'd4 - rst_sense;          // the drive the next post-reset SENSE INTERRUPT reports
    assign irq_fdc = fint && dor[3];

    always @* begin
        io_dout = 8'hFF;
        if (cfg_sel) io_dout = io_addr[0] ? cfg_q : index;
        else if (lpt_sel) io_dout = io_addr[1:0] == 2'd0 ? lpt_d : io_addr[1:0] == 2'd1 ? 8'hDF : lpt_ctl;
        else if (fdc_sel) case (f_reg)
            3'd2: io_dout = dor;
            3'd3: io_dout = tdr;
            3'd4: io_dout = msr;
            3'd5: io_dout = nr != 4'd0 ? fres : 8'h00;
            3'd7: io_dout = 8'h80;                                          // DIR: disk changed
            default: io_dout = 8'hFF;
        endcase
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

        // FDC
        if (f_wr) case (f_reg)
            3'd2: begin
                dor <= io_din;
                if (!io_din[2]) begin                                       // held in reset
                    np <= 4'd0; nr <= 4'd0; fint <= 1'b0; seek_int <= 1'b0; rst_sense <= 3'd0;
                end else if (!dor[2]) begin                                 // out of reset: the interrupt
                    fint <= 1'b1; rst_sense <= 3'd4;
                end
            end
            3'd3: tdr <= io_din;
            3'd4: begin
                dsr <= io_din;
                if (io_din[7]) begin fint <= 1'b1; rst_sense <= 3'd4; np <= 4'd0; nr <= 4'd0; end   // software reset
            end
            3'd5: begin
                if (np != 4'd0) begin
                    // a parameter: 0 drive/head, then C, H, R, N for the data commands;
                    // SEEK's cylinder is 1, CONFIGURE's FIFO and precompensation 1 and 2
                    case (pc)
                    3'd0: prm0 <= io_din;
                    3'd1: prm1 <= io_din;
                    3'd2: prm2 <= io_din;
                    3'd3: prm3 <= io_din;
                    3'd4: prm4 <= io_din;
                    default: ;
                    endcase
                    if (pc == 3'd1 && fcmd == 5'h0F) cyl <= io_din;
                    if (pc == 3'd1 && fcmd == 5'h13) cfg_fifo <= io_din;
                    if (pc == 3'd2 && fcmd == 5'h13) cfg_pre <= io_din;
                    pc <= pc + 3'd1;
                    np <= np - 4'd1;
                    if (np == 4'd1) begin
                        // the last parameter: execute
                        rp <= 4'd0;
                        case (fcmd)
                        5'h07: begin cyl <= 8'd0; seek_int <= 1'b1; fint <= 1'b1; st0 <= {2'b00, 1'b1, 2'b00, io_din[2:0]}; end
                        5'h0F: begin seek_int <= 1'b1; fint <= 1'b1; st0 <= {2'b00, 1'b1, 2'b00, prm0[2:0]}; end
                        5'h03, 5'h12, 5'h13: ;
                        5'h04: nr <= 4'd1;
                        5'h0A: begin nr <= 4'd7; fint <= 1'b1; prm0 <= io_din; end
                        default: begin nr <= 4'd7; fint <= 1'b1; end         // the data commands: fail
                        endcase
                    end
                end else if (nr == 4'd0) begin
                    // a command byte
                    fcmd <= io_din[4:0];
                    rp   <= 4'd0;
                    np   <= cc_now[7:4];
                    pc   <= 3'd0;
                    if (cc_now[7:4] == 4'd0) begin
                        if (io_din[4:0] == 5'h08) begin                    // SENSE INTERRUPT
                            fint <= 1'b0;
                            if (rst_sense != 3'd0) begin
                                st0 <= {2'b11, 4'd0, rst_drv[1:0]};
                                pcn <= 8'd0; nr <= 4'd2; rst_sense <= rst_sense - 3'd1;
                            end else if (seek_int) begin
                                pcn <= cyl; nr <= 4'd2; seek_int <= 1'b0;
                            end else begin
                                st0 <= 8'h80; nr <= 4'd1;                  // nothing pending: invalid
                            end
                        end else begin
                            if (io_din[4:0] == 5'h14) lock <= io_din[7];
                            nr <= cc_now[3:0];
                            if (io_din[4:0] != 5'h10 && io_din[4:0] != 5'h14 && io_din[4:0] != 5'h0E)
                                st0 <= 8'h80;
                        end
                    end
                end
            end
            3'd7: ccr <= io_din;
            default: ;
        endcase
        if (f_rd && f_reg == 3'd5 && nr != 4'd0) begin
            nr <= nr - 4'd1; rp <= rp + 4'd1;
            if (fcmd != 5'h08) fint <= 1'b0;                                // the result phase takes the interrupt
        end

        if (rst) begin
            fer <= 8'h0F; far_r <= 8'h10; ptr <= 8'h00; fcr <= 8'h00; pcr <= 8'h00; krr <= 8'h00;
            pmc <= 8'h00; tup <= 8'h00; index <= 8'h00;
            lpt_d <= 8'h00; lpt_ctl <= 8'h0C;
            dor <= 8'h00; tdr <= 8'h00; dsr <= 8'h02; ccr <= 8'h02; fcmd <= 5'd0; pc <= 3'd0; np <= 4'd0; nr <= 4'd0; rp <= 4'd0;
            st0 <= 8'h00; pcn <= 8'h00; cyl <= 8'h00; rst_sense <= 3'd0; seek_int <= 1'b0; fint <= 1'b0;
            lock <= 1'b0; cfg_fifo <= 8'h00; cfg_pre <= 8'h00;
            prm0 <= 8'h00; prm1 <= 8'h00; prm2 <= 8'h00; prm3 <= 8'h00; prm4 <= 8'h00;
        end
    end
endmodule
