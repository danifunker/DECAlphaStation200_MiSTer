//============================================================================
//
//  DEC AlphaStation 200 - the SCSI devices on the 53C810's bus: hard disks at
//  ID 0 (dka0) and ID 1 (dka100), a CD-ROM at ID 4 (dka400)
//
//  Ported to Verilog-2001 from the user's IBM RS/6000 7248 core
//  (rtl/machine/IBMRS6K7248_scsitgt.sv, itself the HP 9000/715 core's
//  rtl/scsi/scsi_targets.sv). Changes for this machine:
//    - one clock: hps_io runs on the system clock in this core, so sd_rd /
//      sd_wr / sd_lba go straight out and sd_ack is registered once; the
//      sector buffer is a single-clock true dual-port RAM;
//    - flat ports (no unpacked arrays): slot s of a per-slot bus at
//      [32s+31:32s] (img_blocks, sd_lba) or [6s+5:6s] (sd_blk_cnt); one
//      sd_buff_din for all three slots (the top fans it out);
//    - the CD-ROM's block size: 2048 bytes at reset, 512 after a MODE SELECT
//      whose block descriptor says 512 (DEC's SRM sets 512 on every disk-type
//      unit it opens, and refuses a unit whose READ CAPACITY says otherwise);
//    - INQUIRY with EVPD answers CHECK CONDITION, ILLEGAL REQUEST (SRM asks
//      for pages 0x80 and 0x83);
//    - DEC identification strings; the CD-ROM at ID 4;
//    - no CD audio (later, from the HP 9000/715 core's cd_audio.sv): PLAY
//      AUDIO and the rest are accepted and do nothing, READ SUB-CHANNEL
//      reports no audio status; READ TOC comes from the track table Main
//      serves at block C000_0000 of the CD slot, else one data track.
//
//  A byte-level model of the bus (no REQ/ACK timing, no parity, no
//  arbitration); one device is connected at a time and it never disconnects
//  in the middle of a command (so the initiator never sees a reselection).
//
//  The bus, as the initiator (ncr53c810.v) drives it:
//    sel/sel_id/sel_atn  select a target (pulse); sel_done = it answered,
//                        sel_fail = nobody at that ID (the initiator times out)
//    bsy                 a target is connected
//    req, phase, tdata   the target requests a byte in phase {MSG, C/D, I/O};
//                        tdata is the byte for IN phases
//    ack, idata          the initiator took (IN) or gave (OUT) the byte
//    ackhold             the initiator holds ACK after a MESSAGE IN byte
//                        (until its CLEAR ACK); the target waits for it to drop
//    atn                 ATN; the target goes to MESSAGE OUT when it can
//    brst                bus reset
//
//  Commands: TEST UNIT READY, REZERO, REQUEST SENSE, FORMAT UNIT, READ/WRITE
//  (6/10), SEEK, INQUIRY, MODE SELECT/SENSE (6/10) (pages 1, 3, 4, 8; 0E on
//  the CD), RESERVE/RELEASE, START STOP, SEND DIAGNOSTIC, PREVENT ALLOW,
//  READ CAPACITY, VERIFY, SYNCHRONIZE CACHE; the CD adds READ TOC (formats
//  0 and 1, LBA or M:S:F). Anything else: CHECK CONDITION, ILLEGAL REQUEST.
//  SDTR is answered with the same period and offset (at most 8).
//
//============================================================================

module scsi_targets #(
    parameter [2:0] DISK0_ID = 3'd0,
    parameter [2:0] DISK1_ID = 3'd1,
    parameter [2:0] CD_ID    = 3'd4
) (
    input  wire        clk,
    input  wire        rst,
    // the bus
    input  wire        sel,
    input  wire  [2:0] sel_id,
    input  wire        sel_atn,
    output reg         sel_done,
    output reg         sel_fail,
    output reg         bsy,
    output reg         req,
    output reg   [2:0] phase,
    output reg   [7:0] tdata,
    input  wire        ack,
    input  wire  [7:0] idata,
    input  wire        ackhold,
    input  wire        atn,
    input  wire        brst,
    // the images: slot 0 disk 0, 1 disk 1, 2 CD-ROM (hps_io block devices,
    // 512-byte blocks, 8-bit); img_* quasi-static
    input  wire  [2:0] img_present,
    input  wire [95:0] img_blocks,          // size in 512-byte blocks, slot s at [32s+31:32s]
    output reg  [95:0] sd_lba,
    output reg  [17:0] sd_blk_cnt,
    output wire  [2:0] sd_rd,
    output wire  [2:0] sd_wr,
    input  wire  [2:0] sd_ack,
    input  wire [13:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,         // the same for every slot
    input  wire        sd_buff_wr,
    input  wire        cd_change,           // the CD slot's image was (re)mounted
    output wire        activity
);
    // INQUIRY identification: vendor (8), product (16), revision (4)
    localparam [223:0] ID_DISK = "DEC     RZ28     (C) DEC442D";
    localparam [223:0] ID_CD   = "DEC     RRD45   (C) DEC 1645";
    localparam [2:0] P_DOUT = 3'b000, P_DIN = 3'b001, P_CMD = 3'b010, P_STAT = 3'b011,
                     P_MOUT = 3'b110, P_MIN = 3'b111;

    // ----------------------------------------------------- sector buffer
    // 2 KB, byte-wide; port A hps_io's, port B the engine's (one clock,
    // written from both ports: a true dual-port M10K)
    /* verilator lint_off MULTIDRIVEN */
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] buf_mem [0:2047];
    /* verilator lint_on MULTIDRIVEN */
    reg  [10:0] b_addr;         // byte address, engine side
    reg         b_we;
    reg  [7:0]  b_wdata, b_q;
    reg  [7:0]  h_q;
    reg  [2:0]  ack_c;
    reg  [2:0]  e_rd, e_wr;
    always @(posedge clk) ack_c <= sd_ack;
    assign sd_rd = e_rd;
    assign sd_wr = e_wr;
    always @(posedge clk) begin           // port A: hps_io
        if (sd_buff_wr && |sd_ack) buf_mem[sd_buff_addr[10:0]] <= sd_buff_dout;
        h_q <= buf_mem[sd_buff_addr[10:0]];
    end
    always @(posedge clk) begin           // port B: the engine, one byte
        if (b_we) buf_mem[b_addr] <= b_wdata;
        b_q <= buf_mem[b_addr];
    end
    assign sd_buff_din = h_q;

    // ----------------------------------------------------------- state
    localparam [3:0] T_FREE = 4'd0, T_MOUT = 4'd1, T_MIN = 4'd2, T_CMD = 4'd3, T_EXEC = 4'd4,
                     T_DIN = 4'd5, T_DOUT = 4'd6, T_FETCH = 4'd7, T_STORE = 4'd8, T_STAT = 4'd9,
                     T_DONE = 4'd10, T_DISC = 4'd11, T_TOC = 4'd12, T_TOCW = 4'd13, T_TOCCP = 4'd14;
    reg  [3:0]  st;
    reg  [1:0]  dev;                     // 0, 1 disks, 2 CD-ROM
    reg  [2:0]  lun;
    reg  [7:0]  cdb [0:11];
    reg  [3:0]  cdb_n, cdb_len;
    reg  [7:0]  msg [0:4];
    reg  [2:0]  msg_n;
    reg         sdtr_reply;
    reg  [7:0]  sdtr_p, sdtr_o;
    reg  [2:0]  min_n, min_len;
    reg  [7:0]  min_b [0:4];
    reg  [3:0]  skey [0:2];
    reg  [7:0]  sasc [0:2];
    reg         cd_512;                  // the CD-ROM's block size is 512 (else 2048)
    // data phase
    reg         din_synth;               // IN data synthesised (INQUIRY ...) rather than from the buffer
    reg  [15:0] d_left;                  // bytes left in the data phase
    reg  [15:0] d_idx;                   // byte index into the synthesised response
    reg  [31:0] x_lba;                   // next block of a READ/WRITE
    reg  [31:0] x_blocks;                // 512-byte blocks left
    reg  [11:0] chunk;                   // bytes left in the buffer chunk
    reg         pending;                 // waiting for the buffer byte
    reg         hold_seen;
    // MODE SELECT: parameter byte, block descriptor length, page, block length's high byte
    reg  [15:0] ms_i;
    reg  [7:0]  ms_bdl, ms_blhi;
    reg  [5:0]  ms_pg;

    // ---------------------------------------------- the CD's track table
    reg         toc_ok, toc_we;
    reg  [6:0]  toc_a_r;
    reg  [63:0] toc_wd, toc_q;
    reg  [7:0]  toc_first, toc_n;
    reg  [10:0] cp_b;                    // the table copy: byte, sub-step
    reg  [1:0]  cp_s;
    reg  [6:0]  rt_first;                // READ TOC: the first entry sent, how many
    reg  [7:0]  rt_nd;
    reg  [7:0]  vol0, vol1;              // MODE page 0E's port volumes (stored only)
    wire [15:0] toc_off = d_idx - 16'd4;
    wire [6:0]  toc_a = (st == T_DIN && cdb[0] == 8'h43) ? rt_first + toc_off[9:3] : toc_a_r;
    reg  [63:0] toc_mem [0:127];
    always @(posedge clk) begin
        if (toc_we) toc_mem[toc_a] <= toc_wd;
        toc_q <= toc_mem[toc_a];
    end

    wire [31:0] blocks = img_blocks[32 * dev +: 32];
    wire        is_cd  = dev == 2'd2;
    wire [3:0]  bshift = (is_cd && !cd_512) ? 4'd2 : 4'd0;   // device block = 2^bshift 512-byte blocks
    wire [31:0] nblk   = blocks >> bshift;
    wire [31:0] last   = nblk - 32'd1;
    wire [7:0]  bl_hi  = (bshift == 4'd2) ? 8'h08 : 8'h02;  // the block length's byte 2 (2048 or 512)

    // a group code's CDB length
    function [3:0] cdb_length;
        input [7:0] op;
        case (op[7:5])
            3'd0: cdb_length = 4'd6;
            3'd1, 3'd2: cdb_length = 4'd10;
            3'd5: cdb_length = 4'd12;
            default: cdb_length = 4'd6;
        endcase
    endfunction

    // the synthesised IN data: INQUIRY, REQUEST SENSE, READ CAPACITY,
    // MODE SENSE, READ TOC, READ SUB-CHANNEL
    reg [7:0] syn;
    always @* begin : synth
        reg [7:0]  op;
        reg [15:0] i, hdr, k, total, len, e, dl, pi, po;
        reg        ms10, msf;
        reg [5:0]  pg;
        reg [7:0]  pcode;
        op = cdb[0]; i = d_idx; syn = 8'd0;
        hdr = 16'd0; k = 16'd0; total = 16'd0; len = 16'd0; e = 16'd0; dl = 16'd0; pi = 16'd0; po = 16'd0;
        ms10 = 1'b0; msf = 1'b0; pg = 6'd0; pcode = 8'd0;
        case (op)
            8'h12: begin                                         // INQUIRY
                if (lun != 3'd0) syn = (i == 16'd0) ? 8'h7F : 8'h00;
                else case (i)
                    16'd0: syn = is_cd ? 8'h05 : 8'h00;
                    16'd1: syn = is_cd ? 8'h80 : 8'h00;
                    16'd2: syn = 8'h02;
                    16'd3: syn = 8'h02;
                    16'd4: syn = 8'd31;
                    16'd7: syn = 8'h10;                           // synchronous transfers
                    default:
                        // vendor (8), product (16), revision (4)
                        if (i >= 16'd8 && i < 16'd36) syn = is_cd ? ID_CD[(35 - i) * 8 +: 8] : ID_DISK[(35 - i) * 8 +: 8];
                endcase
            end
            8'h03: case (i)                                      // REQUEST SENSE
                16'd0: syn = 8'h70;
                16'd2: syn = {4'd0, skey[dev]};
                16'd7: syn = 8'd10;
                16'd12: syn = sasc[dev];
                default: ;
            endcase
            8'h25: case (i)                                      // READ CAPACITY
                16'd0: syn = last[31:24]; 16'd1: syn = last[23:16]; 16'd2: syn = last[15:8]; 16'd3: syn = last[7:0];
                16'd6: syn = bl_hi;
                default: ;
            endcase
            8'h43: begin                                         // READ TOC
                msf = cdb[1][1];
                if (toc_n == 8'd0) begin
                    // no track table: one data track, as the image is long
                    case (i)
                        16'd0: syn = 8'h00; 16'd1: syn = 8'd18; 16'd2: syn = 8'd1; 16'd3: syn = 8'd1;
                        16'd5: syn = 8'h14; 16'd6: syn = 8'd1;
                        16'd13: syn = 8'h14; 16'd14: syn = 8'hAA;
                        16'd16: syn = nblk[31:24]; 16'd17: syn = nblk[23:16]; 16'd18: syn = nblk[15:8]; 16'd19: syn = nblk[7:0];
                        default: ;
                    endcase
                end else begin
                    // header {length, first, last}, then rt_nd entries from rt_first
                    // (format 1: the first track's only), each {0, ADR/control,
                    // track, 0, address}; toc_q is the entry of this byte
                    len = 16'd2 + {5'd0, rt_nd, 3'd0};
                    e = i - 16'd4;
                    if (i < 16'd4) case (i[1:0])
                        2'd0: syn = len[15:8]; 2'd1: syn = len[7:0];
                        2'd2: syn = (cdb[9][7:6] == 2'd1 || cdb[2][3:0] == 4'd1) ? 8'd1 : toc_first;
                        default: syn = (cdb[9][7:6] == 2'd1 || cdb[2][3:0] == 4'd1) ? 8'd1 : toc_first + toc_n - 8'd1;
                    endcase
                    else case (e[2:0])
                        3'd1: syn = toc_q[63:56];
                        3'd2: syn = toc_q[55:48];
                        3'd4: syn = 8'd0;
                        3'd5: syn = msf ? toc_q[47:40] : toc_q[23:16];
                        3'd6: syn = msf ? toc_q[39:32] : toc_q[15:8];
                        3'd7: syn = msf ? toc_q[31:24] : toc_q[7:0];
                        default: syn = 8'd0;
                    endcase
                end
            end
            8'h42: begin                                         // READ SUB-CHANNEL: no audio status
                dl = !cdb[2][6] ? 16'd0 : cdb[3] == 8'd1 ? 16'd12 : 16'd20;
                case (i)
                    16'd0: syn = 8'h00; 16'd1: syn = 8'h15; 16'd2: syn = dl[15:8]; 16'd3: syn = dl[7:0];
                    16'd4: syn = cdb[3];
                    16'd5: syn = cdb[3] == 8'd2 ? 8'h00 : 8'h14;
                    16'd6: syn = (cdb[3] == 8'd1 || cdb[3] == 8'd3) ? 8'd1 : 8'h00;
                    16'd7: syn = cdb[3] == 8'd1 ? 8'd1 : 8'h00;
                    16'd10: syn = (cdb[3] == 8'd1 && cdb[1][1]) ? 8'h02 : 8'h00;   // absolute 00:02:00
                    default: ;
                endcase
            end
            8'h1A, 8'h5A: begin                                  // MODE SENSE(6) / (10)
                ms10 = op == 8'h5A;
                pg = cdb[2][5:0];
                hdr = ms10 ? 16'd8 : 16'd4;
                // header, block descriptor (8), then page 1 (12), 3 (24), 4 (24), 8 (12), 0E (16, CD)
                if (i < hdr) begin
                    total = hdr + 16'd8 + ((pg == 6'h3F) ? (is_cd ? 16'd88 : 16'd72) : (pg == 6'h01 || pg == 6'h08) ? 16'd12 :
                                           (pg == 6'h03 || pg == 6'h04) ? 16'd24 : (pg == 6'h0E) ? 16'd16 : 16'd0);
                    if (!ms10) case (i)
                        16'd0: syn = total[7:0] - 8'd1;
                        16'd2: syn = is_cd ? 8'h80 : 8'h00;       // write protected
                        16'd3: syn = 8'd8;
                        default: ;
                    endcase
                    else case (i)
                        16'd0: syn = 8'd0; 16'd1: syn = total[7:0] - 8'd2;
                        16'd3: syn = is_cd ? 8'h80 : 8'h00;
                        16'd7: syn = 8'd8;
                        default: ;
                    endcase
                end else if (i < hdr + 16'd8) begin
                    k = i - hdr;
                    case (k)
                        16'd1: syn = nblk[23:16]; 16'd2: syn = nblk[15:8]; 16'd3: syn = nblk[7:0];
                        16'd6: syn = bl_hi;
                        default: ;
                    endcase
                end else begin
                    pi = i - hdr - 16'd8;                        // byte within the page list
                    if (pg == 6'h3F) begin
                        if (pi < 16'd12)      begin pcode = 8'h01; po = pi; end
                        else if (pi < 16'd36) begin pcode = 8'h03; po = pi - 16'd12; end
                        else if (pi < 16'd60) begin pcode = 8'h04; po = pi - 16'd36; end
                        else if (pi < 16'd72) begin pcode = 8'h08; po = pi - 16'd60; end
                        else                  begin pcode = 8'h0E; po = pi - 16'd72; end
                    end else begin pcode = {2'b00, pg}; po = pi; end
                    case (pcode)
                        8'h01: case (po) 16'd0: syn = 8'h01; 16'd1: syn = 8'd10; default: ; endcase
                        8'h03: case (po)                          // format: 64 sectors/track, 512 bytes
                            16'd0: syn = 8'h03; 16'd1: syn = 8'd22; 16'd11: syn = 8'd64; 16'd12: syn = 8'h02; default: ;
                        endcase
                        8'h04: case (po)                          // geometry: 16 heads, cylinders = blocks / 1024
                            16'd0: syn = 8'h04; 16'd1: syn = 8'd22;
                            16'd2: syn = {2'b00, nblk[31:26]}; 16'd3: syn = nblk[25:18]; 16'd4: syn = nblk[17:10];
                            16'd5: syn = 8'd16; 16'd20: syn = 8'h1C; 16'd21: syn = 8'h20;    // 7200 rpm
                            default: ;
                        endcase
                        8'h08: case (po) 16'd0: syn = 8'h08; 16'd1: syn = 8'd10; default: ; endcase
                        8'h0E: case (po)                          // CD audio control: IMMED, ports 0/1 = left/right
                            16'd0: syn = 8'h0E; 16'd1: syn = 8'd14; 16'd2: syn = 8'h04;
                            16'd8: syn = 8'h01; 16'd9: syn = vol0; 16'd10: syn = 8'h02; 16'd11: syn = vol1;
                            default: ;
                        endcase
                        default: ;
                    endcase
                end
            end
            default: ;
        endcase
    end

    // the MODE SENSE pages served
    function page_ok;
        input [5:0] pg;
        input       cd;
        page_ok = pg == 6'h00 || pg == 6'h01 || pg == 6'h03 || pg == 6'h04 || pg == 6'h08 || pg == 6'h3F ||
                  (pg == 6'h0E && cd);
    endfunction

    // how many bytes a synthesised response has before the allocation length
    function [15:0] resp_len;
        input [7:0] op;
        input [5:0] pg;
        input       cd;
        case (op)
            8'h12: resp_len = 16'd36;
            8'h03: resp_len = 16'd18;
            8'h25: resp_len = 16'd8;
            8'h1A, 8'h5A: resp_len = ((op == 8'h5A) ? 16'd16 : 16'd12) +
                                 ((pg == 6'h3F) ? (cd ? 16'd88 : 16'd72) : (pg == 6'h01 || pg == 6'h08) ? 16'd12 :
                                  (pg == 6'h03 || pg == 6'h04) ? 16'd24 : (pg == 6'h0E) ? 16'd16 : 16'd0);
            default: resp_len = 16'd0;
        endcase
    endfunction

    // ------------------------------------------------------------- engine
    wire [2:0] id_hit = {img_present[2] && sel_id == CD_ID, img_present[1] && sel_id == DISK1_ID,
                         img_present[0] && sel_id == DISK0_ID};
    reg        sd_busy;
    reg        sd_was_ack;

    assign activity = st != T_FREE;

    task go_status;
        input [7:0] s;
        begin st <= T_STAT; req <= 1'b1; phase <= P_STAT; tdata <= s; end
    endtask
    task check;                          // CHECK CONDITION with sense key / ASC
        input [3:0] key;
        input [7:0] asc;
        begin skey[dev] <= key; sasc[dev] <= asc; go_status(8'h02); end
    endtask
    task good;
        begin skey[dev] <= 4'd0; sasc[dev] <= 8'd0; go_status(8'h00); end
    endtask
    // the synthesised IN data of rl bytes, cut to the allocation length
    task din_start;
        input [15:0] alloc;
        input [15:0] rl;
        begin
            d_left <= (alloc < rl) ? alloc : rl; din_synth <= 1'b1;
            if (((alloc < rl) ? alloc : rl) == 16'd0) go_status(8'h00);
            else begin st <= T_DIN; req <= 1'b0; phase <= P_DIN; pending <= 1'b1; end
        end
    endtask

    integer d;
    always @(posedge clk) begin : eng
        reg [7:0]  m, op, t0, e0, nd;
        reg [31:0] lba, cnt, n;
        reg [15:0] alloc, rl, hl, po;
        reg        last_e;
        sel_done <= 1'b0; sel_fail <= 1'b0; b_we <= 1'b0;
        toc_we <= 1'b0;
        sd_was_ack <= |ack_c;
        if (rst || brst) begin
            st <= T_FREE; bsy <= 1'b0; req <= 1'b0; e_rd <= 3'd0; e_wr <= 3'd0; sd_busy <= 1'b0;
            for (d = 0; d < 3; d = d + 1) begin skey[d] <= 4'd0; sasc[d] <= 8'd0; end
            pending <= 1'b0; cd_512 <= 1'b0;
            if (rst) begin toc_ok <= 1'b0; toc_n <= 8'd0; vol0 <= 8'hFF; vol1 <= 8'hFF; end
        end else begin
            // block device handshake: drop rd/wr when ack rises, done when it falls
            if (|(ack_c & (e_rd | e_wr))) begin e_rd <= 3'd0; e_wr <= 3'd0; end
            if (sd_busy && sd_was_ack && !(|ack_c) && !(|e_rd) && !(|e_wr)) sd_busy <= 1'b0;
            // a new disc: its table is read again at the next command that needs it
            if (cd_change) begin toc_ok <= 1'b0; toc_n <= 8'd0; cd_512 <= 1'b0; end

            case (st)
                T_FREE: if (sel) begin
                    if (id_hit != 3'd0) begin
                        dev <= id_hit[0] ? 2'd0 : id_hit[1] ? 2'd1 : 2'd2;
                        bsy <= 1'b1; sel_done <= 1'b1; lun <= 3'd0; msg_n <= 3'd0; sdtr_reply <= 1'b0;
                        if (sel_atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; end
                        else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 4'd0; end
                    end else sel_fail <= 1'b1;
                end

                // MESSAGE OUT while ATN is asserted
                T_MOUT: if (ack && req) begin
                    m = idata;
                    if (msg_n == 3'd0 && m[7]) lun <= m[2:0];                 // IDENTIFY
                    if (msg_n == 3'd0 && m == 8'h01) msg_n <= 3'd1;           // extended message
                    else if (msg_n != 3'd0) begin
                        msg[msg_n] <= m;
                        msg_n <= msg_n + 3'd1;
                        if (msg_n == 3'd4 && msg[2] == 8'h01) begin           // SDTR complete
                            sdtr_reply <= 1'b1; sdtr_p <= msg[3]; sdtr_o <= m; msg_n <= 3'd0;
                        end else if (msg_n == 3'd4) msg_n <= 3'd0;
                    end
                    req <= 1'b0;
                end else if (!req) begin
                    // the next byte while ATN stays, else the next phase
                    if (atn) req <= 1'b1;
                    else if (sdtr_reply) begin
                        sdtr_reply <= 1'b0; st <= T_MIN; req <= 1'b1; phase <= P_MIN;
                        min_b[0] <= 8'h01; min_b[1] <= 8'h03; min_b[2] <= 8'h01; min_b[3] <= sdtr_p;
                        min_b[4] <= sdtr_o > 8'd8 ? 8'd8 : sdtr_o;
                        min_n <= 3'd0; min_len <= 3'd5; tdata <= 8'h01; hold_seen <= 1'b0;
                    end else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 4'd0; end
                end

                // MESSAGE IN (the SDTR reply), each byte held by the initiator
                T_MIN: begin
                    if (ack && req) begin req <= 1'b0; min_n <= min_n + 3'd1; hold_seen <= 1'b0; end
                    else if (!req) begin
                        if (ackhold) hold_seen <= 1'b1;
                        else if (atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; msg_n <= 3'd0; end
                        else if (min_n < min_len) begin req <= 1'b1; tdata <= min_b[min_n]; end
                        else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 4'd0; end
                    end
                end

                T_CMD: if (ack && req) begin
                    cdb[cdb_n] <= idata;
                    if (cdb_n == 4'd0) cdb_len <= cdb_length(idata);
                    cdb_n <= cdb_n + 4'd1;
                    req <= 1'b0;
                    if (cdb_n != 4'd0 && cdb_n + 4'd1 == cdb_len) st <= T_EXEC;
                end else if (!req) req <= 1'b1;

                T_EXEC: begin
                    op = cdb[0];
                    // block address and count of the READ/WRITE forms
                    if (op[7:5] == 3'd0) begin
                        lba = {11'd0, cdb[1][4:0], cdb[2], cdb[3]};
                        cnt = {24'd0, cdb[4]};
                        if (cnt == 0 && (op == 8'h08 || op == 8'h0A)) cnt = 32'd256;
                    end else begin
                        lba = {cdb[2], cdb[3], cdb[4], cdb[5]};
                        cnt = {16'd0, cdb[7], cdb[8]};
                    end
                    d_idx <= 16'd0; ms_i <= 16'd0; ms_bdl <= 8'd0; ms_pg <= 6'h3F;
                    if (is_cd && !toc_ok && op == 8'h43) begin
                        st <= T_TOC;                                  // the track table first
                    end else if (lun != 3'd0 && op != 8'h12 && op != 8'h03) begin
                        check(4'h5, 8'h25);
                    end else if (!is_cd && (op == 8'h43 || op == 8'h42 || op == 8'h45 || op == 8'h47 ||
                                            op == 8'h48 || op == 8'hA5 || op == 8'h4B || op == 8'h4E)) begin
                        check(4'h5, 8'h20);
                    end else case (op)
                        8'h43: begin                                  // READ TOC
                            alloc = {cdb[7], cdb[8]};
                            t0 = cdb[6];
                            e0 = (t0 == 8'h00 || t0 <= toc_first) ? 8'd0 : t0 == 8'hAA ? toc_n : t0 - toc_first;
                            nd = toc_n + 8'd1 - e0;
                            if (cdb[9][7:6] == 2'd1 || cdb[2][3:0] == 4'd1) begin e0 = 8'd0; nd = 8'd1; end
                            rl = toc_n == 8'd0 ? 16'd20 : 16'd4 + {5'd0, nd, 3'd0};
                            if (toc_n != 8'd0 && t0 != 8'hAA && t0 > toc_first + toc_n - 8'd1) check(4'h5, 8'h24);
                            else begin
                                rt_first <= e0[6:0]; rt_nd <= nd;
                                skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                din_start(alloc, rl);
                            end
                        end
                        8'h42: begin                                  // READ SUB-CHANNEL
                            skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                            din_start({cdb[7], cdb[8]}, !cdb[2][6] ? 16'd4 : cdb[3] == 8'd1 ? 16'd16 : 16'd24);
                        end
                        // PLAY AUDIO (10), (12), MSF, TRACK/INDEX, PAUSE/RESUME, STOP: no player yet
                        8'h45, 8'hA5, 8'h47, 8'h48, 8'h4B, 8'h4E: good;
                        8'h00, 8'h01, 8'h04, 8'h0B, 8'h16, 8'h17, 8'h1B, 8'h1D, 8'h1E, 8'h2B, 8'h2F, 8'h35:
                            good;
                        8'h12, 8'h03, 8'h25, 8'h1A, 8'h5A: begin
                            rl = resp_len(op, cdb[2][5:0], is_cd);
                            alloc = (op == 8'h25) ? 16'd8 : (op == 8'h5A) ? {cdb[7], cdb[8]} : {8'd0, cdb[4]};
                            if ((op == 8'h1A || op == 8'h5A) && !page_ok(cdb[2][5:0], is_cd)) check(4'h5, 8'h24);
                            else if (op == 8'h12 && cdb[1][0]) check(4'h5, 8'h24);          // EVPD: no pages
                            else begin
                                if (op != 8'h03) begin skey[dev] <= 4'd0; sasc[dev] <= 8'd0; end
                                din_start(alloc, rl);
                            end
                        end
                        8'h08, 8'h28: begin                                   // READ
                            if (((lba + cnt) << bshift) > blocks) check(4'h5, 8'h21);
                            else if (cnt == 0) go_status(8'h00);
                            else begin
                                x_lba <= lba << bshift; x_blocks <= cnt << bshift; din_synth <= 1'b0;
                                skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                st <= T_FETCH; phase <= P_DIN; req <= 1'b0;
                            end
                        end
                        8'h0A, 8'h2A, 8'h2E, 8'h15, 8'h55: begin             // WRITE, MODE SELECT
                            if (op == 8'h15 || op == 8'h55) begin
                                // the parameter list: the block length taken (CD), the rest ignored
                                d_left <= (op == 8'h15) ? {8'd0, cdb[4]} : {cdb[7], cdb[8]};
                                x_blocks <= 32'd0;
                                skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                if (((op == 8'h15) ? cdb[4] : cdb[8]) == 8'd0 && (op == 8'h15 || cdb[7] == 8'd0)) go_status(8'h00);
                                else begin st <= T_DOUT; phase <= P_DOUT; req <= 1'b1; chunk <= 12'd0; end
                            end else if (is_cd) check(4'h7, 8'h27);          // write protected
                            else if ((lba + cnt) > blocks) check(4'h5, 8'h21);
                            else if (cnt == 0) go_status(8'h00);
                            else begin
                                x_lba <= lba; x_blocks <= cnt; d_left <= 16'd0;
                                skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                chunk <= (cnt >= 4) ? 12'd2048 : {cnt[2:0], 9'd0};
                                b_addr <= 11'd0;
                                st <= T_DOUT; phase <= P_DOUT; req <= 1'b1;
                            end
                        end
                        default: check(4'h5, 8'h20);
                    endcase
                end

                // read the next chunk (up to 2 KB) from the image
                T_FETCH: if (!sd_busy) begin
                    if (x_blocks == 0) go_status(8'h00);
                    else begin
                        n = (x_blocks >= 4) ? 32'd4 : x_blocks;
                        sd_lba[32 * dev +: 32] <= x_lba; sd_blk_cnt[6 * dev +: 6] <= n[5:0] - 6'd1;
                        e_rd[dev] <= 1'b1; sd_busy <= 1'b1;
                        x_lba <= x_lba + n; x_blocks <= x_blocks - n;
                        chunk <= {n[2:0], 9'd0};
                        b_addr <= 11'd0; pending <= 1'b1;
                        st <= T_DIN;
                    end
                end

                // DATA IN, from the synthesised response or the buffer
                T_DIN: begin
                    if (ack && req) begin
                        req <= 1'b0; pending <= 1'b1;
                        if (din_synth) begin d_idx <= d_idx + 16'd1; d_left <= d_left - 16'd1; end
                        else begin b_addr <= b_addr + 11'd1; chunk <= chunk - 12'd1; end
                    end else if (!req && !sd_busy) begin
                        if (din_synth && d_left == 16'd0) go_status(8'h00);
                        else if (!din_synth && chunk == 12'd0) st <= T_FETCH;
                        else if (pending) pending <= 1'b0;           // b_q / syn valid the cycle after
                        else begin req <= 1'b1; tdata <= din_synth ? syn : b_q; end
                    end
                end

                // DATA OUT into the buffer, written to the image per chunk
                T_DOUT: begin
                    if (ack && req) begin
                        req <= 1'b0;
                        // MODE SELECT's parameter bytes are counted by d_left alone: chunk stays 0
                        if (x_blocks == 0 && d_left != 0) begin
                            d_left <= d_left - 16'd1;
                            hl = (cdb[0] == 8'h15) ? 16'd4 : 16'd8;
                            po = hl + {8'd0, ms_bdl};
                            if (ms_i == hl - 16'd1) ms_bdl <= idata;
                            // the block descriptor's block length: 512 or 2048 on the CD
                            if (ms_bdl != 8'd0 && ms_i == hl + 16'd6) ms_blhi <= idata;
                            if (is_cd && ms_bdl != 8'd0 && ms_i == hl + 16'd7) begin
                                if ({ms_blhi, idata} == 16'h0200) cd_512 <= 1'b1;
                                else if ({ms_blhi, idata} == 16'h0800) cd_512 <= 1'b0;
                            end
                            if (ms_i == po) ms_pg <= idata[5:0];
                            if (is_cd && ms_pg == 6'h0E && ms_i == po + 16'd9) vol0 <= idata;
                            if (is_cd && ms_pg == 6'h0E && ms_i == po + 16'd11) vol1 <= idata;
                            ms_i <= ms_i + 16'd1;
                        end
                        else begin b_we <= 1'b1; b_wdata <= idata; chunk <= chunk - 12'd1; end
                    end else if (!req) begin
                        if (b_we) b_addr <= b_addr + 11'd1;
                        if (x_blocks == 0 && d_left == 0 && chunk == 0 && !b_we) go_status(8'h00);
                        else if (x_blocks == 0 && d_left != 0) req <= 1'b1;
                        else if (chunk == 12'd0 && !b_we) begin
                            n = (x_blocks >= 4) ? 32'd4 : x_blocks;
                            sd_lba[32 * dev +: 32] <= x_lba; sd_blk_cnt[6 * dev +: 6] <= n[5:0] - 6'd1;
                            e_wr[dev] <= 1'b1; sd_busy <= 1'b1;
                            x_lba <= x_lba + n; x_blocks <= x_blocks - n;
                            st <= T_STORE;
                        end else if (!b_we) req <= 1'b1;
                    end
                end
                T_STORE: if (!sd_busy && !(|e_wr)) begin
                    if (x_blocks == 0) go_status(8'h00);
                    else begin
                        st <= T_DOUT; b_addr <= 11'd0; req <= 1'b1;
                        chunk <= (x_blocks >= 4) ? 12'd2048 : {x_blocks[2:0], 9'd0};
                    end
                end

                // the track table: 2 blocks from the window into the buffer, then
                // header bytes 0 (first track) and 1 (n) and n + 1 entries of 8
                // bytes from byte 8 into toc; then the command runs again
                T_TOC: if (!sd_busy) begin
                    sd_lba[64 +: 32] <= 32'hC000_0000; sd_blk_cnt[12 +: 6] <= 6'd1; e_rd[2] <= 1'b1;
                    sd_busy <= 1'b1; st <= T_TOCW;
                end
                T_TOCW: if (!sd_busy) begin cp_b <= 11'd0; cp_s <= 2'd0; st <= T_TOCCP; end
                T_TOCCP: case (cp_s)
                    2'd0: begin b_addr <= cp_b; cp_s <= 2'd1; end
                    2'd1: cp_s <= 2'd2;
                    2'd2: begin
                        n = {21'd0, cp_b} - 32'd8;
                        last_e = cp_b >= 11'd8 && cp_b[2:0] == 3'd7 && n[10:3] == toc_n;
                        if (cp_b == 11'd0) toc_first <= b_q;
                        else if (cp_b == 11'd1) toc_n <= b_q > 8'd99 ? 8'd99 : b_q;
                        else if (cp_b >= 11'd8) begin
                            toc_wd[8 * (7 - cp_b[2:0]) +: 8] <= b_q;
                            if (cp_b[2:0] == 3'd7) begin toc_we <= 1'b1; toc_a_r <= n[9:3]; end
                        end
                        if ((cp_b == 11'd1 && b_q == 8'd0) || last_e) cp_s <= 2'd3;
                        else begin cp_b <= cp_b == 11'd1 ? 11'd8 : cp_b + 11'd1; cp_s <= 2'd0; end
                    end
                    default: begin toc_ok <= 1'b1; st <= T_EXEC; end
                endcase

                T_STAT: if (ack && req) begin
                    req <= 1'b0; st <= T_DONE; hold_seen <= 1'b0;
                end
                // STATUS taken: MESSAGE IN COMMAND COMPLETE (or MESSAGE OUT on ATN)
                T_DONE: if (!req) begin
                    if (atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; msg_n <= 3'd0; end
                    else begin st <= T_DISC; req <= 1'b1; phase <= P_MIN; tdata <= 8'h00; end
                end
                // COMMAND COMPLETE taken; once the initiator releases ACK, free the bus
                T_DISC: begin
                    if (ack && req) begin req <= 1'b0; hold_seen <= 1'b0; end
                    else if (!req) begin
                        if (ackhold) hold_seen <= 1'b1;
                        else if (atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; msg_n <= 3'd0; end
                        else begin st <= T_FREE; bsy <= 1'b0; end
                    end
                end
                default: st <= T_FREE;
            endcase
        end
    end
endmodule
