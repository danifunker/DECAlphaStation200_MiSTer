// The PC87332's floppy disk controller: an Intel 82077AA (docs/design/floppy.md)
// in PC-AT mode at 3F0h-3F7h (3F6h is the IDE's), IRQ 6 and ISA DMA channel 2,
// with one 3.5" drive A: whose medium is the OSD's floppy image
// (rtl/sio/isa_fdc_img.v, hps_io slot 3). Drives 1-3 are not connected.
//
// Registers (io_off):
//   0 SRA, 1 SRB  read: the PS/2-mode status registers (INT, TRK0, INDEX, WP,
//                 head, step; drive select, motors)
//   2 DOR         drive select [1:0], /RESET [2], DMA gate [3] (IRQ and DRQ
//                 enable), motors [7:4]; read back
//   3 TDR         tape drive select [1:0]
//   4 MSR / DSR   read: RQM, DIO, NDM, CB, drive busy [3:0]; write: data rate
//                 [1:0], precompensation [4:2], power down [6] (stored), software
//                 reset [7]
//   5 FIFO        commands, results, and the data of a non-DMA transfer
//   7 DIR / CCR   read: DSKCHG [7] (bits 6:0 float high); write: data rate [1:0]
//
// Commands: READ DATA, READ DELETED DATA, READ TRACK, WRITE DATA, WRITE DELETED
// DATA, VERIFY, SCAN EQUAL / LOW OR EQUAL / HIGH OR EQUAL, FORMAT TRACK, READ ID,
// RECALIBRATE, SEEK, RELATIVE SEEK, SENSE INTERRUPT STATUS, SENSE DRIVE
// STATUS, SPECIFY, CONFIGURE, PERPENDICULAR MODE, LOCK, DUMPREG, VERSION (90h);
// anything else is invalid (one result byte, 80h). Implied seeks (CONFIGURE
// EIS), multi-track, skip, DMA (8237 channel 2, the transfer ended by TC) and
// non-DMA (SPECIFY ND: the bytes through the FIFO, RQM and INT for each),
// the disk change line (set by a mount, cleared by a step with a medium in),
// write protect from the image, the data rate checked against the medium.
//
// Timing (all of it SPEED times faster than a real drive): the disk turns at
// 300 rpm, its sectors pass one after the other (the next sector's ID at each
// slot boundary, sector 1 after the index), the data bytes come at the data
// rate (500 kbps: 16 us a byte), steps at SPECIFY's step rate, and a sector or
// ID that is not on the track ends the command after two index pulses. A host
// slower than the data rate holds the transfer (no overrun).
//
// Bus (docs/design/pci.md 5): io_rd / io_wr are the SIO's one-cycle strobes,
// qualified by the decode; io_dout is a mux of registers, a read's side
// effects (FIFO results) on the io_rd clock. Every register's value lags its
// state by a clock (msr_q, fifo_q): two accesses to the FDC are always more
// than a clock apart.
module isa_fdc #(
    parameter CLK_HZ = 100000000,
    parameter SPEED  = 4                // the drive's mechanics and data rate, times real
) (
    input  wire        clk,
    input  wire        rst,

    input  wire  [2:0] io_off,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output reg   [7:0] io_dout,
    output wire        irq,             // IRQ 6

    // DMA channel 2 (rtl/sio/isa_dma.v)
    output reg         dreq,
    output reg   [7:0] dma_q,           // the byte for a write-to-memory transfer (valid with dreq)
    input  wire        dack,            // channel 2's transfer done (a pulse)
    input  wire  [7:0] dack_data,       // a read-from-memory transfer's byte
    input  wire        tc,              // with dack: the count ran out
    output wire        led,             // a command is running

    // the image (hps_io slot 3)
    input  wire        img_mounted,
    input  wire        img_readonly,
    input  wire [63:0] img_size,
    output wire [31:0] sd_lba,
    output wire  [5:0] sd_blk_cnt,
    output wire        sd_rd,
    output wire        sd_wr,
    input  wire        sd_ack,
    input  wire [13:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    input  wire        sd_buff_wr,
    output wire  [7:0] sd_buff_din
);
    // ================================================================ the medium
    wire        med_in, med_ro, med_chg, trk_rdy;
    wire  [5:0] spt;
    wire  [1:0] mrate;
    wire  [6:0] ntrk;
    wire  [7:0] buf_q;
    reg         want;
    reg  [12:0] want_lba;
    reg   [5:0] want_cnt;
    reg  [13:0] buf_a;
    reg         buf_we;
    reg   [7:0] buf_wd;
    reg         dirty_stb;
    reg   [4:0] dirty_slot;

    isa_fdc_img img (
        .clk(clk),
        .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
        .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr), .sd_buff_din(sd_buff_din),
        .med_in(med_in), .med_ro(med_ro), .spt(spt), .mrate(mrate), .ntrk(ntrk), .changed(med_chg),
        .want(want), .want_lba(want_lba), .want_cnt(want_cnt), .trk_rdy(trk_rdy),
        .buf_a(buf_a), .buf_we(buf_we), .buf_wd(buf_wd), .buf_q(buf_q),
        .dirty_stb(dirty_stb), .dirty_slot(dirty_slot)
    );

    // ================================================================ time
    localparam integer US_DIV0 = CLK_HZ / 1000000 / SPEED;
    localparam integer US_DIV  = US_DIV0 < 1 ? 1 : US_DIV0;
    reg  [7:0] pre;
    reg        tick_us;                 // a microsecond (of the drive's time)
    reg  [8:0] hm_cnt;
    reg        tick_hm;                 // half a millisecond
    always @(posedge clk) begin
        tick_us <= 1'b0; tick_hm <= 1'b0;
        if (pre == 8'd0) begin pre <= US_DIV[7:0] - 8'd1; tick_us <= 1'b1; end else pre <= pre - 8'd1;
        if (tick_us) begin
            if (hm_cnt == 9'd0) begin hm_cnt <= 9'd499; tick_hm <= 1'b1; end else hm_cnt <= hm_cnt - 9'd1;
        end
        if (rst) begin pre <= 8'd0; hm_cnt <= 9'd0; end
    end

    // the disk turns: 200 ms a revolution, cut into the medium's sector slots
    wire  [5:0] r_spt = med_in ? spt : 6'd18;
    reg  [14:0] slot_us;
    reg  [14:0] rot_us;
    reg   [5:0] rot_sec;                // the sector whose ID passes the head (at slot_ev)
    reg         slot_ev, idx_ev;
    always @(posedge clk) begin
        case (r_spt)
        6'd36:   slot_us <= 15'd5555;
        6'd21:   slot_us <= 15'd9523;
        6'd15:   slot_us <= 15'd13333;
        6'd9:    slot_us <= 15'd22222;
        default: slot_us <= 15'd11111;
        endcase
        slot_ev <= 1'b0; idx_ev <= 1'b0;
        if (tick_us) begin
            if (rot_us == 15'd0) begin
                rot_us  <= slot_us - 15'd1;
                slot_ev <= 1'b1;
                if (rot_sec + 6'd1 >= r_spt) begin rot_sec <= 6'd0; idx_ev <= 1'b1; end
                else rot_sec <= rot_sec + 6'd1;
            end else rot_us <= rot_us - 15'd1;
        end
        if (rst) begin rot_us <= 15'd100; rot_sec <= 6'd0; end
    end
    wire index_n = !(rot_sec == 6'd0 && rot_us > slot_us - 15'd200);   // SRA's /INDEX: the first 200 us of sector 1's slot

    // ================================================================ registers
    reg  [7:0] dor;
    reg  [1:0] tdr;
    reg  [1:0] rate;                    // DSR/CCR [1:0]
    reg  [4:0] dsr_hi;                  // DSR [6:2] (stored)
    reg  [7:0] spec1, spec2;            // SPECIFY: {SRT, HUT}, {HLT, ND}
    reg  [6:0] confv;                   // CONFIGURE: {EIS, EFIFO, POLL, FIFOTHR}
    reg  [7:0] pretrk;
    reg  [5:0] perp;                    // PERPENDICULAR: {D3..D0, GAP, WGATE}
    reg        lock;
    reg  [7:0] last_eot;                // DUMPREG's SC/EOT
    wire       nd  = spec2[0];
    wire       eis = confv[6];
    reg        dchg = 1'b1;             // drive 0's disk change line (not reset by the machine's reset)

    // byte time and step time
    reg  [5:0] byte_us;
    reg  [6:0] step_hm;
    always @(posedge clk) begin
        case (rate)
        2'd0: byte_us <= 6'd16;         // 500 kbps
        2'd1: byte_us <= 6'd27;         // 300 kbps
        2'd2: byte_us <= 6'd32;         // 250 kbps
        default: byte_us <= 6'd8;       // 1 Mbps
        endcase
        // SRT: 16 - SRT ms at 500 kbps (8 ms units at 250k/300k twice, at 1M half)
        case (rate)
        2'd0:    step_hm <= {2'b00, ~spec1[7:4], 1'b0} + 7'd2;
        2'd3:    step_hm <= {3'b000, ~spec1[7:4]} + 7'd1;
        default: step_hm <= {1'b0, ~spec1[7:4], 2'b00} + 7'd4;
        endcase
    end

    // ================================================================ phases
    localparam P_CMD = 2'd0, P_EXEC = 2'd1, P_RES = 2'd2;
    reg  [1:0] ph;
    reg  [7:0] cmdb [0:8];
    reg  [3:0] ncmd, need;
    reg        disp;                    // the command is complete: dispatch it (next clock)
    reg  [7:0] res [0:9];
    reg  [3:0] nres, rpos;
    reg        int_res;                 // the interrupt of a result phase
    reg        int_sk;                  // the interrupt of a seek end, a reset (SENSE INTERRUPT takes it)
    reg  [2:0] rst_n;                   // SENSE INTERRUPT results owed after a reset
    reg  [3:0] sk_pend;                 // a seek end per drive, for SENSE INTERRUPT
    reg  [7:0] sk_st0 [0:3];
    reg  [7:0] pcn [0:3];
    reg  [6:0] phys;                    // drive 0's head (the cylinder it is on)
    reg        resetting;               // DOR's /RESET low

    function [3:0] cmdlen;              // the bytes of a command, by its first
        input [7:0] c;
        case (c[4:0])
        5'h02, 5'h05, 5'h06, 5'h09, 5'h0C, 5'h11, 5'h16, 5'h19, 5'h1D: cmdlen = 4'd9;
        5'h03, 5'h0F: cmdlen = 4'd3;
        5'h04, 5'h07, 5'h0A, 5'h12: cmdlen = 4'd2;
        5'h0D: cmdlen = 4'd6;
        5'h13: cmdlen = 4'd4;
        default: cmdlen = 4'd1;         // SENSE INTERRUPT, DUMPREG, VERSION, LOCK, invalid
        endcase
    endfunction

    // ================================================================ the seek engine
    reg        sk_busy, sk_impl, sk_recal, sk_out, sk_hds, sk_done;
    reg  [1:0] sk_d;
    reg  [7:0] sk_n;                    // steps left (a recalibrate: steps made)
    reg  [6:0] sk_t;                    // half-milliseconds to the next step
    reg        sk_ec;                   // a recalibrate that found no track 0
    reg        step_ev;                 // a step pulse

    // ================================================================ execution
    localparam K_READ = 3'd0, K_WRITE = 3'd1, K_VERIFY = 3'd2, K_SCAN = 3'd3, K_FMT = 3'd4, K_RID = 3'd5;
    localparam X_IDLE = 5'd0, X_START = 5'd1, X_ISEEK = 5'd2, X_PREP = 5'd3, X_PREP2 = 5'd4, X_PREP3 = 5'd5,
               X_FIND = 5'd6, X_RFETCH = 5'd7, X_RW1 = 5'd8, X_RW2 = 5'd9, X_RHOLD = 5'd10, X_WREQ = 5'd11,
               X_WPAD = 5'd12, X_SECEND = 5'd13, X_RES = 5'd14, X_ERRWAIT = 5'd15, X_RID = 5'd16,
               X_FMT_IDX = 5'd17, X_FMT_ID = 5'd18, X_FMT_FILL = 5'd19, X_FMT_NEXT = 5'd20, X_VWAIT = 5'd21,
               X_SEEKCMD = 5'd22, X_FMT_SLOT = 5'd23;
    reg  [4:0] xs;
    reg  [2:0] xk;                      // the kind
    reg  [4:0] xop;
    reg        x_mt, x_mfm, x_sk, x_rdd, x_rtrk, x_ec;
    reg  [1:0] xd;                      // drive
    reg        hds;                     // the physical head
    reg  [7:0] xc, xh, xr, xn, xeot, xdtl;
    reg  [7:0] x_sc, x_fill;            // FORMAT: sectors, filler
    reg        x_se;                    // an implied seek was made
    reg  [7:0] st1, st2;
    reg        x_ic;                    // abnormal termination
    reg        tc_seen, x_cm;
    reg  [9:0] pos;                     // the byte in the sector
    reg  [5:0] pace;                    // microseconds to the next byte
    reg  [4:0] slot;                    // the sector's slot in the cache
    reg  [1:0] idx_n;                   // index pulses seen
    reg        marks, id_ok;
    reg  [7:0] trk2;                    // cylinder x 2 + head
    reg  [7:0] dbyte;                   // the data byte (to the host, or from the disk for a scan)
    reg        dvalid;                  // a byte for the host is in dbyte
    reg        wreq;                    // a byte from the host is wanted
    reg  [1:0] fb;                      // FORMAT: the ID byte
    reg  [7:0] fid_c, fid_h, fid_r, fid_n;
    reg        fmt_ok;
    reg        sc_eq, sc_le, sc_ge;     // SCAN: the sector's comparisons so far
    reg  [7:0] sc_hits;                 // ST2 scan bits (SH, SN)

    wire f_rd5 = io_rd && io_off == 3'd5;
    wire f_wr5 = io_wr && io_off == 3'd5;
    wire x_xfer = ph == P_EXEC && (xs == X_RHOLD || xs == X_WREQ || xs == X_FMT_ID);
    // a byte moved between the host and the controller
    wire h_dma  = dack && !nd;
    wire take_rd = xs == X_RHOLD && dvalid && ((h_dma) || (f_rd5 && nd));
    wire take_wr = (xs == X_WREQ || xs == X_FMT_ID) && wreq && ((h_dma) || (f_wr5 && nd));
    wire [7:0] host_byte = (f_wr5 && nd) ? io_din : dack_data;
    wire pio_rqm = nd && ((xs == X_RHOLD && dvalid) || ((xs == X_WREQ || xs == X_FMT_ID) && wreq));
    wire pio_dir = xs == X_RHOLD;
    wire irq_raw = int_res || int_sk || (ph == P_EXEC && pio_rqm);

    // the group (track, or half of a 36-sector one) and slot of sector xr
    wire        half2 = spt == 6'd36 && xr > 8'd18;
    reg  [12:0] grp_mul;
    always @* begin
        case (spt)
        6'd9:    grp_mul = {2'b0, trk2, 3'b0} + {5'b0, trk2};
        6'd15:   grp_mul = {1'b0, trk2, 4'b0} - {5'b0, trk2};
        6'd21:   grp_mul = {1'b0, trk2, 4'b0} + {3'b0, trk2, 2'b0} + {5'b0, trk2};
        6'd36:   grp_mul = {trk2, 5'b0} + {3'b0, trk2, 2'b0};
        default: grp_mul = {1'b0, trk2, 4'b0} + {4'b0, trk2, 1'b0};   // 18
        endcase
    end

    integer i;
    always @(posedge clk) begin
        disp <= 1'b0; buf_we <= 1'b0; dirty_stb <= 1'b0; step_ev <= 1'b0; sk_done <= 1'b0;
        if (med_chg) dchg <= 1'b1;
        if (step_ev && sk_d == 2'd0 && med_in) dchg <= 1'b0;
        if (tick_us && pace != 6'd0) pace <= pace - 6'd1;
        if (dack && tc && !nd && ph == P_EXEC) tc_seen <= 1'b1;

        // ------------------------------------------------------------ the bus
        if (io_wr) case (io_off)
            3'd2: begin
                dor <= io_din;
                if (!io_din[2]) resetting <= 1'b1;
                else if (resetting) begin               // out of reset: the polling interrupt
                    resetting <= 1'b0;
                    if (!(lock && confv[4])) begin int_sk <= 1'b1; rst_n <= 3'd4; end
                end
            end
            3'd3: tdr <= io_din[1:0];
            3'd4: begin
                rate <= io_din[1:0]; dsr_hi <= io_din[6:2];
                if (io_din[7] && !resetting && !(lock && confv[4])) begin int_sk <= 1'b1; rst_n <= 3'd4; end
            end
            3'd5: if (ph == P_CMD && !resetting && !disp) begin
                cmdb[ncmd] <= io_din;
                int_res <= 1'b0;
                if (ncmd == 4'd0) need <= cmdlen(io_din);
                if ((ncmd == 4'd0 && cmdlen(io_din) == 4'd1) || (ncmd != 4'd0 && ncmd + 4'd1 == need)) begin
                    ncmd <= 4'd0; ph <= P_EXEC; disp <= 1'b1;
                end else ncmd <= ncmd + 4'd1;
            end
            3'd7: rate <= io_din[1:0];
            default: ;
        endcase
        if (f_rd5 && ph == P_RES) begin
            int_res <= 1'b0;
            if (rpos + 4'd1 == nres) begin ph <= P_CMD; rpos <= 4'd0; end
            else rpos <= rpos + 4'd1;
        end

        // ------------------------------------------------------------ dispatch
        if (disp) begin
            rpos <= 4'd0;
            case (cmdb[0][4:0])
            5'h03: begin spec1 <= cmdb[1]; spec2 <= cmdb[2]; ph <= P_CMD; end                    // SPECIFY
            5'h04: begin                                                                         // SENSE DRIVE STATUS
                if (cmdb[1][1:0] == 2'd0)
                    res[0] <= {1'b0, !med_in || med_ro, 1'b1, phys == 7'd0, 1'b1, cmdb[1][2:0]};
                else
                    res[0] <= {3'b001, pcn[cmdb[1][1:0]] == 8'd0, 1'b0, cmdb[1][2:0]};
                nres <= 4'd1; ph <= P_RES;
            end
            5'h08: begin                                                                         // SENSE INTERRUPT STATUS
                int_sk <= 1'b0;
                if (rst_n != 3'd0) begin
                    res[0] <= {6'b110000, 2'd0 - rst_n[1:0]};
                    res[1] <= pcn[2'd0 - rst_n[1:0]];
                    rst_n <= rst_n - 3'd1; nres <= 4'd2;
                end else if (sk_pend != 4'd0) begin
                    for (i = 3; i >= 0; i = i - 1)
                        if (sk_pend[i]) begin res[0] <= sk_st0[i]; res[1] <= pcn[i]; end
                    sk_pend <= sk_pend & (sk_pend - 4'd1);                // the lowest drive's
                    nres <= 4'd2;
                end else begin
                    res[0] <= 8'h80; nres <= 4'd1;
                end
                ph <= P_RES;
            end
            5'h0E: begin                                                                         // DUMPREG
                res[0] <= pcn[0]; res[1] <= pcn[1]; res[2] <= pcn[2]; res[3] <= pcn[3];
                res[4] <= spec1; res[5] <= spec2; res[6] <= last_eot;
                res[7] <= {lock, 1'b0, perp}; res[8] <= {1'b0, confv}; res[9] <= pretrk;
                nres <= 4'd10; ph <= P_RES;
            end
            5'h10: if (cmdb[0][7:5] == 3'd0) begin res[0] <= 8'h90; nres <= 4'd1; ph <= P_RES; end // VERSION
                   else begin res[0] <= 8'h80; nres <= 4'd1; ph <= P_RES; end
            5'h12: begin                                                                         // PERPENDICULAR MODE
                perp[1:0] <= cmdb[1][1:0];
                if (cmdb[1][7]) perp[5:2] <= cmdb[1][5:2];
                ph <= P_CMD;
            end
            5'h13: begin confv <= cmdb[2][6:0]; pretrk <= cmdb[3]; ph <= P_CMD; end              // CONFIGURE
            5'h14: begin                                                                         // LOCK
                lock <= cmdb[0][7];
                res[0] <= {3'd0, cmdb[0][7], 4'd0}; nres <= 4'd1; ph <= P_RES;
            end
            5'h07, 5'h0F: xs <= X_SEEKCMD;                                                       // RECALIBRATE, SEEK, RELATIVE SEEK
            5'h02, 5'h05, 5'h06, 5'h09, 5'h0A, 5'h0C, 5'h0D, 5'h11, 5'h16, 5'h19, 5'h1D: begin
                xop   <= cmdb[0][4:0];
                x_mt  <= cmdb[0][7]; x_mfm <= cmdb[0][6]; x_sk <= cmdb[0][5];
                x_rdd <= cmdb[0][4:0] == 5'h0C;
                x_rtrk <= cmdb[0][4:0] == 5'h02;
                x_ec  <= cmdb[0][4:0] == 5'h16 && cmdb[1][7];
                xd    <= cmdb[1][1:0]; hds <= cmdb[1][2];
                xc    <= cmdb[2]; xh <= cmdb[3];
                xr    <= cmdb[0][4:0] == 5'h02 ? 8'd1 : cmdb[4];
                xn    <= cmdb[0][4:0] == 5'h0D ? cmdb[2] : cmdb[5];
                xeot  <= cmdb[6]; xdtl <= cmdb[8];
                x_sc  <= cmdb[3]; x_fill <= cmdb[5];
                case (cmdb[0][4:0])
                5'h05, 5'h09: xk <= K_WRITE;
                5'h16:        xk <= K_VERIFY;
                5'h11, 5'h19, 5'h1D: xk <= K_SCAN;
                5'h0D:        xk <= K_FMT;
                5'h0A:        xk <= K_RID;
                default:      xk <= K_READ;
                endcase
                if (cmdb[0][4:0] == 5'h0D) last_eot <= cmdb[3];
                else if (cmdb[0][4:0] != 5'h0A) last_eot <= cmdb[6];
                x_se <= 1'b0; st1 <= 8'h00; st2 <= 8'h00; x_ic <= 1'b0; x_cm <= 1'b0; tc_seen <= 1'b0;
                sc_hits <= 8'h00;
                xs <= X_START;
            end
            default: begin res[0] <= 8'h80; nres <= 4'd1; ph <= P_RES; end                       // invalid
            endcase
        end

        // ------------------------------------------------------------ the seek engine
        if (sk_busy && tick_hm) begin
            if (sk_t != 7'd0) sk_t <= sk_t - 7'd1;
        end
        // each step pulse is followed by the step time; the seek ends after the last one's
        // (a recalibrate on track 0, a seek to where the head is: at once)
        if (sk_busy && sk_t == 7'd0) begin
            if (sk_recal ? (sk_d == 2'd0 && phys == 7'd0) || sk_n == 8'd79 : sk_n == 8'd0) begin
                // done
                sk_busy <= 1'b0; sk_done <= 1'b1;
                if (sk_recal) begin
                    sk_ec <= !(sk_d == 2'd0 && phys == 7'd0);
                    if (sk_d == 2'd0 && phys == 7'd0) pcn[sk_d] <= 8'd0;
                end else sk_ec <= 1'b0;
                if (!sk_impl) begin
                    sk_pend[sk_d] <= 1'b1;
                    sk_st0[sk_d] <= {(sk_recal && !(sk_d == 2'd0 && phys == 7'd0)) ? 2'b01 : 2'b00, 1'b1,
                                     sk_recal && !(sk_d == 2'd0 && phys == 7'd0), 1'b0, sk_hds, sk_d};
                    int_sk <= 1'b1; rst_n <= 3'd0;
                end
            end else begin
                // a step
                step_ev <= 1'b1;
                sk_t <= step_hm;
                if (sk_recal) sk_n <= sk_n + 8'd1; else sk_n <= sk_n - 8'd1;
                if (sk_out) begin
                    pcn[sk_d] <= pcn[sk_d] - 8'd1;
                    if (sk_d == 2'd0 && phys != 7'd0) phys <= phys - 7'd1;
                end else begin
                    pcn[sk_d] <= pcn[sk_d] + 8'd1;
                    if (sk_d == 2'd0 && phys != 7'd83) phys <= phys + 7'd1;
                end
            end
        end

        // ------------------------------------------------------------ execution
        case (xs)
        X_SEEKCMD: if (!sk_busy) begin
            // RECALIBRATE (07), SEEK (0F), RELATIVE SEEK (8F: out to 0, CF: in)
            sk_busy <= 1'b1; sk_impl <= 1'b0; sk_t <= 7'd0;
            sk_d <= cmdb[1][1:0]; sk_hds <= cmdb[1][2];
            if (cmdb[0][4:0] == 5'h07) begin sk_recal <= 1'b1; sk_out <= 1'b1; sk_n <= 8'd0; end
            else if (cmdb[0][7]) begin sk_recal <= 1'b0; sk_out <= !cmdb[0][6]; sk_n <= cmdb[2]; end
            else begin
                sk_recal <= 1'b0;
                sk_out <= cmdb[2] < pcn[cmdb[1][1:0]];
                sk_n <= cmdb[2] < pcn[cmdb[1][1:0]] ? pcn[cmdb[1][1:0]] - cmdb[2] : cmdb[2] - pcn[cmdb[1][1:0]];
            end
            ph <= P_CMD; xs <= X_IDLE;
        end
        X_START: begin
            idx_n <= 2'd0;
            if (xk == K_RID) xs <= X_PREP;
            else if (sk_busy) ;                                                                 // a seek still running
            else if (xd != 2'd0) begin st1 <= 8'h01; xs <= X_ERRWAIT; end                      // no drive: no marks
            else if ((xk == K_WRITE || xk == K_FMT) && (!med_in || med_ro)) begin
                st1 <= 8'h02; x_ic <= 1'b1; xs <= X_RES;                                        // not writable
            end else if (eis && xk != K_FMT && xc != pcn[0]) begin
                // the implied seek
                sk_busy <= 1'b1; sk_impl <= 1'b1; sk_recal <= 1'b0; sk_t <= 7'd0; sk_d <= 2'd0; sk_hds <= hds;
                sk_out <= xc < pcn[0];
                sk_n <= xc < pcn[0] ? pcn[0] - xc : xc - pcn[0];
                x_se <= 1'b1;
                xs <= X_ISEEK;
            end else xs <= X_PREP;
        end
        X_ISEEK: if (sk_done) xs <= X_PREP;
        X_PREP: begin
            // the medium's ID marks on this track, and the sector's ID
            marks <= xd == 2'd0 && med_in && rate == mrate && x_mfm && phys < ntrk;
            id_ok <= xd == 2'd0 && med_in && rate == mrate && x_mfm && phys < ntrk &&
                     xc == {1'b0, phys} && xh == {7'd0, hds} && xn == 8'd2 && xr != 8'd0 && xr <= {2'b00, spt};
            trk2  <= {phys, hds};
            idx_n <= 2'd0;
            xs <= xk == K_RID ? X_RID : xk == K_FMT ? X_FMT_IDX : X_PREP2;
        end
        X_PREP2: begin
            want_lba <= half2 ? grp_mul + 13'd18 : grp_mul;
            want_cnt <= spt == 6'd36 ? 6'd18 : spt;
            want     <= id_ok || (xk == K_FMT && fmt_ok);
            slot     <= half2 ? xr[4:0] - 5'd19 : xr[4:0] - 5'd1;
            xs <= X_PREP3;
        end
        X_PREP3: xs <= xk == K_FMT ? X_FMT_SLOT : X_FIND;      // (trk_rdy follows want_lba a clock late)
        X_FIND: begin
            // the sector's ID, or two index pulses without it
            if (idx_ev && !id_ok) begin
                idx_n <= idx_n + 2'd1;
                if (idx_n == 2'd1) begin
                    st1 <= marks ? 8'h04 : 8'h01;                                               // no data / missing address mark
                    st2 <= marks && xc != {1'b0, phys} ? (xc == 8'hFF ? 8'h02 : 8'h10) : 8'h00;  // bad / wrong cylinder
                    x_ic <= 1'b1;
                    xs <= X_RES;
                end
            end
            if (id_ok && slot_ev && rot_sec == xr[5:0] - 6'd1 && trk_rdy) begin
                pos <= 10'd0; pace <= byte_us; dvalid <= 1'b0; wreq <= 1'b0;
                sc_eq <= 1'b1; sc_le <= 1'b1; sc_ge <= 1'b1;
                if (xk == K_WRITE) xs <= X_WREQ;
                else if (xk == K_VERIFY || (x_rdd && x_sk)) xs <= X_VWAIT;
                else xs <= X_RFETCH;                                        // read, scan
                if (x_rdd) x_cm <= 1'b1;                                    // a regular data mark under READ DELETED
            end
        end
        // ---- a byte from the disk (read, scan)
        X_RFETCH: if (pace == 6'd0 || xk == K_SCAN) begin
            // the bytes come off the disk a byte time apart, however long the host takes each
            buf_a <= {slot, pos[8:0]}; pace <= byte_us; xs <= X_RW1;
        end
        X_RW1: xs <= X_RW2;
        X_RW2: begin
            dbyte <= buf_q;
            if (xk == K_SCAN) begin wreq <= 1'b1; xs <= X_WREQ; end
            else begin dvalid <= 1'b1; xs <= X_RHOLD; end
        end
        X_RHOLD: if (take_rd) begin
            dvalid <= 1'b0;
            if (pos == 10'd511 || (dack && tc)) xs <= X_SECEND;
            else begin pos <= pos + 10'd1; xs <= X_RFETCH; end
        end
        // ---- a byte from the host (write, scan)
        X_WREQ: begin
            if (!wreq && pace == 6'd0) begin wreq <= 1'b1; if (xk != K_SCAN) pace <= byte_us; end
            if (take_wr) begin
                wreq <= 1'b0;
                if (xk == K_SCAN) begin
                    if (host_byte != 8'hFF) begin
                        if (host_byte != dbyte) sc_eq <= 1'b0;
                        if (dbyte > host_byte) sc_le <= 1'b0;
                        if (dbyte < host_byte) sc_ge <= 1'b0;
                    end
                end else begin
                    buf_we <= 1'b1; buf_a <= {slot, pos[8:0]}; buf_wd <= host_byte;
                end
                if (pos == 10'd511) begin
                    if (xk != K_SCAN) begin dirty_stb <= 1'b1; dirty_slot <= slot; end
                    xs <= X_SECEND;
                end else if (dack && tc && !nd) begin
                    pos <= pos + 10'd1;
                    xs <= xk == K_SCAN ? X_SECEND : X_WPAD;
                end else begin
                    pos <= pos + 10'd1;
                    if (xk == K_SCAN) xs <= X_RFETCH;
                end
            end
        end
        X_WPAD: begin                                                       // TC within a sector: zeros to its end
            buf_we <= 1'b1; buf_a <= {slot, pos[8:0]}; buf_wd <= 8'h00;
            pos <= pos + 10'd1;
            if (pos == 10'd511) begin dirty_stb <= 1'b1; dirty_slot <= slot; xs <= X_SECEND; end
        end
        // ---- a sector passing with no transfer (verify; skipped)
        X_VWAIT: if (pace == 6'd0) begin
            pace <= byte_us;
            pos <= pos + 10'd1;
            if (pos == 10'd511) xs <= X_SECEND;
        end
        // ---- the sector's end: the next, or the end of the command
        X_SECEND: begin
            if (xk == K_SCAN && (xop == 5'h11 ? sc_eq : xop == 5'h19 ? sc_le : sc_ge)) begin
                sc_hits <= sc_eq ? 8'h08 : 8'h00;                           // satisfied (SH: equal)
                xr <= xr + 8'd1; xs <= X_RES;
            end else if (tc_seen || (dack && tc && !nd) || (x_rdd && !x_sk) ||
                         (x_ec && xdtl <= 8'd1)) begin
                // ended by TC (or READ DELETED's regular sector, or VERIFY's count): the next sector's address
                if (x_ec) xdtl <= xdtl - 8'd1;
                if (xr == xeot) begin
                    xr <= 8'd1;
                    if (x_mt && !hds) xh <= xh ^ 8'd1;
                    else begin xc <= xc + 8'd1; if (x_mt) xh <= xh ^ 8'd1; end
                end else xr <= xr + 8'd1;
                xs <= X_RES;
            end else if (xr == xeot || (xk == K_SCAN && xr + {6'd0, xdtl[1:0]} > xeot)) begin
                if (x_mt && !hds) begin                                     // multi-track: on to head 1
                    hds <= 1'b1; xh <= xh ^ 8'd1; xr <= 8'd1;
                    if (x_ec) xdtl <= xdtl - 8'd1;
                    xs <= X_PREP;
                end else begin
                    xr <= 8'd1; xc <= xc + 8'd1;
                    if (x_mt) xh <= xh ^ 8'd1;
                    if (xk == K_SCAN) sc_hits <= 8'h04;                     // not satisfied (SN)
                    else if (xk != K_VERIFY) begin st1 <= 8'h80; x_ic <= 1'b1; end   // end of cylinder
                    xs <= X_RES;
                end
            end else begin
                xr <= xk == K_SCAN ? xr + {6'd0, xdtl[1:0]} : xr + 8'd1;
                if (x_ec) xdtl <= xdtl - 8'd1;
                xs <= X_PREP;
            end
        end
        // ---- errors: two index pulses
        X_ERRWAIT: if (idx_ev) begin
            idx_n <= idx_n + 2'd1;
            if (idx_n == 2'd1) begin x_ic <= 1'b1; xs <= X_RES; end
        end
        // ---- READ ID
        X_RID: begin
            if (!marks) begin
                if (idx_ev) begin
                    idx_n <= idx_n + 2'd1;
                    if (idx_n == 2'd1) begin st1 <= 8'h01; x_ic <= 1'b1; xc <= {1'b0, phys}; xh <= {7'd0, hds}; xs <= X_RES; end
                end
            end else if (slot_ev) begin
                xc <= {1'b0, phys}; xh <= {7'd0, hds}; xr <= {2'b00, rot_sec} + 8'd1; xn <= 8'd2;
                xs <= X_RES;
            end
        end
        // ---- FORMAT TRACK: from the index, each sector's ID from the host, the sector filled
        X_FMT_IDX: if (idx_ev) begin fb <= 2'd0; wreq <= 1'b1; xs <= X_FMT_ID; end
        X_FMT_ID: begin
            if (take_wr) begin
                case (fb)
                2'd0: fid_c <= host_byte;
                2'd1: fid_h <= host_byte;
                2'd2: fid_r <= host_byte;
                default: fid_n <= host_byte;
                endcase
                fb <= fb + 2'd1;
                if (dack && tc && !nd) tc_seen <= 1'b1;
                if (fb == 2'd3) begin wreq <= 1'b0; xs <= X_FMT_FILL; end
            end
        end
        X_FMT_FILL: begin
            // the ID's sector stored if the image can hold it (this drive's rate, 512 bytes, in the track)
            fmt_ok <= med_in && rate == mrate && x_mfm && phys < ntrk && xn == 8'd2 && fid_n == 8'd2 &&
                      fid_r != 8'd0 && fid_r <= {2'b00, spt};
            xr <= fid_r; xc <= fid_c; xh <= fid_h; xn <= fid_n;
            trk2 <= {phys, hds};
            pos <= 10'd0;
            xs <= X_PREP2;
        end
        X_FMT_SLOT: begin
            if (!fmt_ok) xs <= X_FMT_NEXT;
            else if (trk_rdy) begin
                buf_we <= 1'b1; buf_a <= {slot, pos[8:0]}; buf_wd <= x_fill;
                pos <= pos + 10'd1;
                if (pos == 10'd511) begin dirty_stb <= 1'b1; dirty_slot <= slot; xs <= X_FMT_NEXT; end
            end
        end
        X_FMT_NEXT: begin
            if (x_sc == 8'd1 || tc_seen) xs <= X_RES;
            else if (slot_ev) begin x_sc <= x_sc - 8'd1; fb <= 2'd0; wreq <= 1'b1; xs <= X_FMT_ID; end
        end
        // ---- the result phase
        X_RES: begin
            res[0] <= {1'b0, x_ic, x_se, 2'b00, hds, xd};
            res[1] <= st1;
            res[2] <= st2 | sc_hits | (x_cm ? 8'h40 : 8'h00);
            res[3] <= xc; res[4] <= xh; res[5] <= xr; res[6] <= xn;
            nres <= 4'd7; ph <= P_RES; int_res <= 1'b1;
            want <= 1'b0; dvalid <= 1'b0; wreq <= 1'b0;
            xs <= X_IDLE;
        end
        default: ;
        endcase

        // ------------------------------------------------------------ reset
        if ((io_wr && io_off == 3'd2 && !io_din[2]) || (io_wr && io_off == 3'd4 && io_din[7])) begin
            ph <= P_CMD; ncmd <= 4'd0; rpos <= 4'd0; disp <= 1'b0; int_res <= 1'b0; sk_pend <= 4'd0;
            sk_busy <= 1'b0; xs <= X_IDLE; want <= 1'b0; dvalid <= 1'b0; wreq <= 1'b0;
            for (i = 0; i < 4; i = i + 1) pcn[i] <= 8'd0;
            if (!lock) begin confv <= 7'h20; pretrk <= 8'd0; end
            if (io_off == 3'd2) begin int_sk <= 1'b0; rst_n <= 3'd0; end
        end
        if (rst) begin
            dor <= 8'h00; tdr <= 2'd0; rate <= 2'd2; dsr_hi <= 5'd0; resetting <= 1'b1;
            spec1 <= 8'h00; spec2 <= 8'h00; confv <= 7'h20; pretrk <= 8'd0; perp <= 6'd0; lock <= 1'b0;
            last_eot <= 8'd0;
            ph <= P_CMD; ncmd <= 4'd0; need <= 4'd1; nres <= 4'd1; rpos <= 4'd0; int_res <= 1'b0; int_sk <= 1'b0;
            rst_n <= 3'd0; sk_pend <= 4'd0; phys <= 7'd0;
            for (i = 0; i < 4; i = i + 1) begin pcn[i] <= 8'd0; sk_st0[i] <= 8'h00; end
            sk_busy <= 1'b0; sk_impl <= 1'b0; sk_recal <= 1'b0; sk_out <= 1'b0; sk_hds <= 1'b0; sk_d <= 2'd0;
            sk_n <= 8'd0; sk_t <= 7'd0; sk_ec <= 1'b0;
            xs <= X_IDLE; xk <= K_READ; want <= 1'b0; want_lba <= 13'd0; want_cnt <= 6'd18;
            dvalid <= 1'b0; wreq <= 1'b0; tc_seen <= 1'b0; pace <= 6'd0; pos <= 10'd0;
            buf_a <= 14'd0; buf_wd <= 8'h00; slot <= 5'd0; dirty_slot <= 5'd0;
            hds <= 1'b0; xd <= 2'd0; x_ic <= 1'b0; x_se <= 1'b0; st1 <= 8'h00; st2 <= 8'h00;
        end
    end

    // ================================================================ outputs (registered)
    reg [7:0] msr_q, fifo_q, sra_q, srb_q, dir_q;
    wire [3:0] dbusy = sk_busy ? (4'b0001 << sk_d) : 4'b0000;
    always @(posedge clk) begin
        if (resetting)          msr_q <= 8'h00;
        else if (ph == P_RES)   msr_q <= {4'b1101, dbusy};
        else if (ph == P_EXEC)  msr_q <= nd ? {pio_rqm, pio_dir, 2'b11, dbusy} : {4'b0001, dbusy};
        else                    msr_q <= {1'b1, 2'b00, ncmd != 4'd0, dbusy};
        fifo_q <= ph == P_RES ? res[rpos] : dbyte;
        dma_q  <= dbyte;
        dreq   <= dor[3] && !nd && ph == P_EXEC && !take_rd && !take_wr &&
                  ((xs == X_RHOLD && dvalid) || ((xs == X_WREQ || xs == X_FMT_ID) && wreq));
        sra_q  <= {irq_raw, 1'b1, step_ev, !(phys == 7'd0), hds, index_n, !(!med_in || med_ro), sk_out};
        srb_q  <= {2'b11, dor[0], 1'b0, 1'b0, ph == P_EXEC && xk == K_WRITE, dor[5], dor[4]};
        dir_q  <= {dor[1:0] == 2'd0 && dchg, 7'h7F};
    end
    assign irq = irq_raw && dor[3];
    assign led = ph == P_EXEC && xs != X_IDLE;

    always @* begin
        case (io_off)
        3'd0: io_dout = sra_q;
        3'd1: io_dout = srb_q;
        3'd2: io_dout = dor;
        3'd3: io_dout = {6'h3F, tdr};
        3'd4: io_dout = msr_q;
        3'd5: io_dout = fifo_q;
        3'd7: io_dout = dir_q;
        default: io_dout = 8'hFF;
        endcase
    end
endmodule
