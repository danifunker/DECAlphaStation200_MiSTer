//============================================================================
//
//  DEC AlphaStation 200 - the SCSI devices on the 53C810's bus: hard disks at
//  ID 0 (dka0) and ID 1 (dka100), a CD-ROM at ID 4 (dka400)
//
//  Ported to Verilog-2001 from the user's IBM RS/6000 7248 core
//  (rtl/machine/IBMRS6K7248_scsitgt.sv, itself the HP 9000/715 core's
//  rtl/scsi/scsi_targets.sv), with the HP core's CD audio. Changes for this
//  machine:
//    - one clock: hps_io runs on the system clock in this core, so sd_rd /
//      sd_wr / sd_lba go straight out and sd_ack is registered once; the
//      sector buffer is a single-clock true dual-port RAM;
//    - flat ports (no unpacked arrays): slot s of a per-slot bus at
//      [32s+31:32s] (img_blocks, sd_lba) or [6s+5:6s] (sd_blk_cnt); one
//      sd_buff_din for all three slots (the top fans it out);
//    - the CD-ROM's block size: 2048 bytes at power-on, 512 after a MODE SELECT
//      whose block descriptor says 512 (DEC's SRM sets 512 on every disk-type
//      unit it opens, and refuses a unit whose READ CAPACITY says otherwise);
//      kept across bus resets and disc changes, as a mode parameter;
//    - the CD drive is always on the bus (CD_ALWAYS): with no image it answers
//      NOT READY, MEDIUM NOT PRESENT; a (re)mount gives UNIT ATTENTION,
//      MEDIUM MAY HAVE CHANGED once;
//    - INQUIRY with EVPD answers CHECK CONDITION, ILLEGAL REQUEST (SRM asks
//      for pages 0x80 and 0x83);
//    - DEC identification strings; the CD-ROM at ID 4;
//    - every synthesised response (INQUIRY, MODE SENSE, READ TOC ...) is
//      addressed by registered cursors and its byte registered (syn_r) before
//      it goes out on tdata: the 10 ns fit (2026-11-01: d_idx compares and
//      adders into tdata failed by 1.1 ns).
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
//  Commands (docs/design/scsi.md 3): TEST UNIT READY, REZERO, REQUEST SENSE,
//  FORMAT UNIT, READ/WRITE (6/10/12), WRITE AND VERIFY, SEEK (6/10), INQUIRY,
//  MODE SELECT/SENSE (6/10) (disks: pages 1, 2, 3, 4, 8, 0A; CD: 1, 2, 0D,
//  0E; current/changeable/default/saved, DBD), RESERVE/RELEASE, START STOP,
//  SEND DIAGNOSTIC, PREVENT ALLOW, READ CAPACITY, VERIFY, SYNCHRONIZE CACHE,
//  READ DEFECT DATA. The CD adds READ TOC (formats 0, 1 and 2, LBA or M:S:F),
//  READ SUB-CHANNEL (formats 1-3), READ CD (user data), and the audio player
//  (cd_audio.v): PLAY AUDIO (10), (12), MSF, TRACK/INDEX, PAUSE/RESUME, STOP
//  PLAY. The track table and the audio frames come from Main_MiSTer's windows
//  on the CD slot (support/decalpha, docs/design/cdrom.md); with a Main that
//  has none the disc is one data track. Anything else: CHECK CONDITION,
//  ILLEGAL REQUEST. SDTR is answered with the same period and an offset of at
//  most 8.
//
//============================================================================

module scsi_targets #(
    parameter [2:0] DISK0_ID  = 3'd0,
    parameter [2:0] DISK1_ID  = 3'd1,
    parameter [2:0] CD_ID     = 3'd4,
    parameter       CD_ALWAYS = 1,          // the CD drive answers selection with no image
    parameter       CLK_HZ    = 100000000,  // for the 44.1 kHz audio sample clock
    parameter       CD_BOOT512 = 0          // the CD's power-on block length: 1 = 512 (as DEC's RRD
                                            // drives are said to start), 0 = 2048; MODE SELECT changes it
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
    input  wire        cd_change,           // the CD slot's image was (re)mounted (a pulse)
    // CD audio: signed 16-bit stereo, a new sample with each cd_audio_stb (44.1 kHz)
    output wire signed [15:0] cd_audio_l,
    output wire signed [15:0] cd_audio_r,
    output wire        cd_audio_stb,
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
    reg         aud_xfer;               // the transfer is the CD player's frame
    always @(posedge clk) ack_c <= sd_ack;
    assign sd_rd = e_rd;
    assign sd_wr = e_wr;
    always @(posedge clk) begin           // port A: hps_io
        if (sd_buff_wr && |sd_ack && !aud_xfer) buf_mem[sd_buff_addr[10:0]] <= sd_buff_dout;
        h_q <= buf_mem[sd_buff_addr[10:0]];
    end
    always @(posedge clk) begin           // port B: the engine, one byte
        if (b_we) buf_mem[b_addr] <= b_wdata;
        b_q <= buf_mem[b_addr];
    end
    assign sd_buff_din = h_q;

    // ----------------------------------------------------------- state
    localparam [4:0] T_FREE = 5'd0, T_MOUT = 5'd1, T_MIN = 5'd2, T_CMD = 5'd3, T_EXEC = 5'd4,
                     T_DIN = 5'd5, T_DOUT = 5'd6, T_FETCH = 5'd7, T_STORE = 5'd8, T_STAT = 5'd9,
                     T_DONE = 5'd10, T_DISC = 5'd11, T_TOC = 5'd12, T_TOCW = 5'd13, T_TOCCP = 5'd14,
                     T_TOCFK = 5'd15, T_TRK = 5'd16, T_PRE1 = 5'd17, T_PRE2 = 5'd18, T_DLEN = 5'd19,
                     T_PLAY = 5'd20;
    reg  [4:0]  st;
    reg  [1:0]  dev;                     // 0, 1 disks, 2 CD-ROM
    reg  [2:0]  lun;
    reg  [7:0]  cdb [0:11];
    reg  [4:0]  cdb_n, cdb_len;
    reg  [7:0]  msg [0:4];
    reg  [2:0]  msg_n;
    reg         sdtr_reply;
    reg  [7:0]  sdtr_p, sdtr_o;
    reg  [2:0]  min_n, min_len;
    reg  [7:0]  min_b [0:4];
    reg  [3:0]  skey [0:2];
    reg  [7:0]  sasc [0:2];
    reg         cd_512;                  // the CD-ROM's block size is 512 (else 2048)
    reg         cd_ua;                   // UNIT ATTENTION (medium changed) pending on the CD
    // data phase
    reg         din_synth;               // IN data synthesised (INQUIRY ...) rather than from the buffer
    reg  [15:0] d_left;                  // bytes left in the data phase
    reg  [10:0] d_idx;                   // byte index into the synthesised response (at most 1126)
    reg  [31:0] x_lba;                   // next block of a READ/WRITE
    reg  [31:0] x_blocks;                // 512-byte blocks left
    reg  [11:0] chunk;                   // bytes left in the buffer chunk
    reg  [1:0]  pend;                    // clocks until the next byte (syn_r / b_q) is valid
    reg         hold_seen;
    // MODE SELECT / FORMAT UNIT parameter list: byte, block descriptor length,
    // the page being read (code, start, length), a high byte
    reg  [9:0]  ms_i, ms_ps;
    reg  [7:0]  ms_bdl, ms_blhi, ms_pl;
    reg  [5:0]  ms_pg;
    // READ CAPACITY / block descriptor values, taken at the command
    reg  [31:0] cap_n, cap_last;
    reg  [7:0]  cap_bl;                  // the block length's byte 2 (0x08 or 0x02)

    // ---------------------------------------------- the CD's track table, audio
    reg         toc_ok, toc_we;
    reg  [6:0]  toc_a_r;
    reg  [63:0] toc_wd;
    wire [63:0] toc_q;
    reg  [7:0]  toc_first, toc_n;
    reg  [7:0]  toc_lsf, toc_nses;      // the last session's first track, the number of sessions
    reg  [23:0] toc_lead;               // the lead-out's LBA
    reg  [10:0] cp_b;                    // the table copy: byte, sub-step
    reg  [1:0]  cp_s;
    reg  [19:0] fk_x;                    // the made-up table's lead-out: frames to M:S:F
    reg  [7:0]  fk_m, fk_s;
    reg  [1:0]  fk_s2;
    reg         a_play, a_pause, a_resume, a_stop, a_stread;
    reg  [18:0] a_start, a_end;          // frames (cd_audio: 19 bits)
    wire [7:0]  a_status, q_ctl, q_track;
    wire [23:0] q_abs_lba, q_rel_lba, q_abs_msf, q_rel_msf;
    wire        fr_req;
    reg         fr_go, fr_done;
    wire [31:0] fr_lba;
    wire        a_playing;
    reg  [7:0]  vol0, vol1;              // MODE page 0E's port 0/1 volume and channel selection
    reg  [3:0]  csel0, csel1;
    reg  [7:0]  rs_status, rs_ctl, rs_track;      // READ SUB-CHANNEL, taken at the command
    reg  [23:0] rs_abs, rs_rel;
    reg  [2:0]  trk_s;
    // the command, decoded over two registered steps before T_EXEC (the 10 ns fit):
    // T_PRE1 the block address and count, capacities, command classes; T_PRE2 the
    // end address and the READ TOC values (again after the track table is read)
    reg  [31:0] lba_r, cnt_r, end_r, capcd;
    reg         cdo_r, ntoc_r, ndisc_r;
    reg  [7:0]  e0_r, tl_r;
    reg         t0bad_r;
    reg  [15:0] rlt2_r;
    reg  [15:0] dal, drl;                // data in: the allocation length, the response's (T_DLEN)
    // PLAY AUDIO's addresses (T_PLAY, a step a clock)
    reg  [2:0]  pl_s;
    reg  [23:0] pm0, pm1;
    reg  [15:0] ps0, ps1;
    reg  [31:0] pt0, pt1, pf0, pf1, p0r, p1r;
    reg         pcur, pbad, pover;

    cd_audio #(.CLK_HZ(CLK_HZ)) u_cda (
        .clk(clk), .rst(rst),
        .toc_we(toc_we), .toc_a(toc_a_r), .toc_wd(toc_wd), .toc_q(toc_q), .toc_first(toc_first), .toc_n(toc_n),
        .play(a_play), .p_start(a_start), .p_end(a_end), .pause(a_pause), .resume(a_resume), .stop(a_stop),
        .a_status(a_status), .status_read(a_stread), .q_ctl(q_ctl), .q_track(q_track),
        .q_abs_lba(q_abs_lba), .q_rel_lba(q_rel_lba), .q_abs_msf(q_abs_msf), .q_rel_msf(q_rel_msf),
        .playing(a_playing),
        .fr_req(fr_req), .fr_lba(fr_lba), .fr_go(fr_go), .fr_done(fr_done),
        .fb_we(sd_buff_wr && sd_ack[2] && aud_xfer), .fb_addr(sd_buff_addr[11:0]), .fb_data(sd_buff_dout),
        .sel_l(csel0), .sel_r(csel1), .vol_l(vol0), .vol_r(vol1),
        .out_l(cd_audio_l), .out_r(cd_audio_r), .out_stb(cd_audio_stb));

    // a play address as a frame: past 2^19 - 1 (116:30, beyond any disc) it is the last
    function [18:0] frame19;
        input [31:0] x;
        frame19 = |x[31:19] ? 19'h7FFFF : x[18:0];
    endfunction

    wire [31:0] blocks = img_blocks[32 * dev +: 32];
    wire        is_cd  = dev == 2'd2;
    wire        cd_in  = img_present[2];                     // a disc is in the drive
    // the image in 2048-byte sectors, at most 2^19 - 1 (116:30)
    wire [18:0] cd_secs = |img_blocks[95:85] ? 19'h7FFFF : img_blocks[84:66];
    wire [3:0]  bshift = (is_cd && !cd_512) ? 4'd2 : 4'd0;   // device block = 2^bshift 512-byte blocks

    // a group code's CDB length
    function [4:0] cdb_length;
        input [7:0] op;
        case (op[7:5])
            3'd0: cdb_length = 5'd6;
            3'd1, 3'd2: cdb_length = 5'd10;
            3'd4: cdb_length = 5'd16;
            3'd5: cdb_length = 5'd12;
            default: cdb_length = 5'd6;
        endcase
    endfunction

    // ------------------------------------------------------ MODE SENSE pages
    // disks 01 02 03 04 08 0A (100 bytes), the CD 01 02 0D 0E (52 bytes)
    function page_ok;
        input [5:0] pg;
        input       cd;
        page_ok = pg == 6'h00 || pg == 6'h01 || pg == 6'h02 || pg == 6'h3F ||
                  (!cd && (pg == 6'h03 || pg == 6'h04 || pg == 6'h08 || pg == 6'h0A)) ||
                  (cd && (pg == 6'h0D || pg == 6'h0E));
    endfunction
    function [4:0] page_last;            // a page's length - 1
        input [5:0] pg;
        case (pg)
            6'h02, 6'h0E: page_last = 5'd15;
            6'h03, 6'h04: page_last = 5'd23;
            6'h0D:        page_last = 5'd7;
            default:      page_last = 5'd11;
        endcase
    endfunction
    function [5:0] page_next;
        input [5:0] pg;
        input       cd;
        case (pg)
            6'h01: page_next = 6'h02;
            6'h02: page_next = cd ? 6'h0D : 6'h03;
            6'h03: page_next = 6'h04;
            6'h04: page_next = 6'h08;
            6'h08: page_next = 6'h0A;
            6'h0D: page_next = 6'h0E;
            default: page_next = 6'h00;
        endcase
    endfunction
    function [7:0] pages_len;
        input [5:0] pg;
        input       cd;
        pages_len = pg == 6'h3F ? (cd ? 8'd52 : 8'd100) : pg == 6'h00 ? 8'd0 : {3'd0, page_last(pg)} + 8'd1;
    endfunction

    // ------------------------------------------------------ the synthesised IN data
    // INQUIRY, REQUEST SENSE, READ CAPACITY, MODE SENSE, READ TOC, READ
    // SUB-CHANNEL, READ DEFECT DATA, from registered cursors only: d_idx for
    // the fixed layouts; MODE SENSE's section, page and offset (ms_sec,
    // ms_cpg, ms_po); READ TOC's header flag and the entry's byte and kind
    // (rt_b, rt_k: 0 A0, 1 A1, 2 A2, 3 a track; toc_q is the entry)
    reg  [1:0]  ms_sec;                  // 0 header, 1 block descriptor, 2 pages
    reg  [5:0]  ms_cpg;
    reg  [4:0]  ms_po;
    reg  [1:0]  ms_pc;                   // page control: 0 current, 1 changeable, 2 default, 3 saved
    reg         ms_10;
    reg  [7:0]  ms_len, ms_bdlen;        // the mode data length byte, the block descriptor length
    reg  [1:0]  rt_fmt;                  // READ TOC: format 0, 1, 2
    reg         rt_msf;
    reg  [3:0]  rt_b;
    reg  [1:0]  rt_k;
    reg  [6:0]  rt_e, rt_ne;             // the entry sent, how many (the TOC's first: rt_first)
    reg  [6:0]  rt_first;
    reg  [15:0] rt_len;                  // the TOC data length (header bytes 0-1)
    reg  [7:0]  rt_h2, rt_h3;
    reg  [7:0]  syn, syn_r;
    always @(posedge clk) syn_r <= syn;

    always @* begin : synth
        reg [7:0] op;
        reg [10:0] i;
        reg [7:0] m, s, f;
        op = cdb[0]; i = d_idx; syn = 8'd0;
        m = toc_q[47:40]; s = toc_q[39:32]; f = toc_q[31:24];
        case (op)
            8'h12: begin                                         // INQUIRY
                if (lun != 3'd0) syn = (i == 11'd0) ? 8'h7F : 8'h00;
                else case (i)
                    11'd0: syn = is_cd ? 8'h05 : 8'h00;
                    11'd1: syn = is_cd ? 8'h80 : 8'h00;
                    11'd2: syn = 8'h02;
                    11'd3: syn = 8'h02;
                    11'd4: syn = 8'd31;
                    11'd7: syn = 8'h10;                           // synchronous transfers
                    default:
                        // vendor (8), product (16), revision (4)
                        if (i >= 11'd8 && i < 11'd36) syn = is_cd ? ID_CD[(35 - i) * 8 +: 8] : ID_DISK[(35 - i) * 8 +: 8];
                endcase
            end
            8'h03: case (i)                                      // REQUEST SENSE
                11'd0: syn = 8'h70;
                11'd2: syn = {4'd0, skey[dev]};
                11'd7: syn = 8'd10;
                11'd12: syn = sasc[dev];
                default: ;
            endcase
            8'h25: case (i)                                      // READ CAPACITY
                11'd0: syn = cap_last[31:24]; 11'd1: syn = cap_last[23:16];
                11'd2: syn = cap_last[15:8];  11'd3: syn = cap_last[7:0];
                11'd6: syn = cap_bl;
                default: ;
            endcase
            8'h37: case (i)                                      // READ DEFECT DATA: an empty list
                11'd1: syn = {3'd0, cdb[2][4:0]};
                default: ;
            endcase
            8'h43: begin                                         // READ TOC
                if (i < 11'd4) case (i[1:0])
                    2'd0: syn = rt_len[15:8];
                    2'd1: syn = rt_len[7:0];
                    2'd2: syn = rt_h2;
                    default: syn = rt_h3;
                endcase
                else if (rt_fmt == 2'd2) case (rt_b)              // full TOC: 11-byte descriptors, session 1
                    4'd0: syn = 8'd1;
                    4'd1: syn = toc_q[63:56];
                    4'd3: syn = rt_k == 2'd0 ? 8'hA0 : rt_k == 2'd1 ? 8'hA1 : rt_k == 2'd2 ? 8'hA2 : toc_q[55:48];
                    4'd8: syn = rt_k == 2'd0 ? toc_first : rt_k == 2'd1 ? toc_q[55:48] : m;
                    4'd9: syn = rt_k[1] ? s : 8'd0;              // A0's disc type: 0 (CD-DA / CD-ROM)
                    4'd10: syn = rt_k[1] ? f : 8'd0;
                    default: syn = 8'd0;
                endcase
                else case (rt_b[2:0])                            // formats 0 and 1: {0, ADR/control, track, 0, address}
                    3'd1: syn = toc_q[63:56];
                    3'd2: syn = toc_q[55:48];
                    3'd5: syn = rt_msf ? m : toc_q[23:16];
                    3'd6: syn = rt_msf ? s : toc_q[15:8];
                    3'd7: syn = rt_msf ? f : toc_q[7:0];
                    default: syn = 8'd0;
                endcase
            end
            8'h42: case (i)                                      // READ SUB-CHANNEL
                11'd1: syn = rs_status;
                11'd3: syn = !cdb[2][6] ? 8'd0 : cdb[3] == 8'd1 ? 8'd12 : 8'd20;
                11'd4: syn = cdb[3];
                11'd5: syn = cdb[3] == 8'd2 ? 8'h00 : rs_ctl;
                11'd6: syn = (cdb[3] == 8'd1 || cdb[3] == 8'd3) ? rs_track : 8'h00;
                11'd7: syn = cdb[3] == 8'd1 ? 8'd1 : 8'h00;
                // the positions: {0, M, S, F} or the LBA, as taken at the command
                11'd9:  syn = cdb[3] == 8'd1 ? rs_abs[23:16] : 8'd0;
                11'd10: syn = cdb[3] == 8'd1 ? rs_abs[15:8] : 8'd0;
                11'd11: syn = cdb[3] == 8'd1 ? rs_abs[7:0] : 8'd0;
                11'd13: syn = cdb[3] == 8'd1 ? rs_rel[23:16] : 8'd0;
                11'd14: syn = cdb[3] == 8'd1 ? rs_rel[15:8] : 8'd0;
                11'd15: syn = cdb[3] == 8'd1 ? rs_rel[7:0] : 8'd0;
                default: ;
            endcase
            8'h1A, 8'h5A: begin                                  // MODE SENSE(6) / (10)
                if (ms_sec == 2'd0) begin
                    if (!ms_10) case (i[1:0])
                        2'd0: syn = ms_len;
                        2'd2: syn = is_cd ? 8'h80 : 8'h00;        // write protected
                        2'd3: syn = ms_bdlen;
                        default: ;
                    endcase
                    else case (i[2:0])
                        3'd1: syn = ms_len;
                        3'd3: syn = is_cd ? 8'h80 : 8'h00;
                        3'd7: syn = ms_bdlen;
                        default: ;
                    endcase
                end else if (ms_sec == 2'd1) case (ms_po[2:0])  // block descriptor
                    3'd1: syn = cap_n[23:16]; 3'd2: syn = cap_n[15:8]; 3'd3: syn = cap_n[7:0];
                    3'd6: syn = cap_bl;
                    default: ;
                endcase
                else if (ms_po == 5'd0) syn = {2'b00, ms_cpg};
                else if (ms_po == 5'd1) syn = {3'd0, page_last(ms_cpg)} - 8'd1;
                else if (ms_pc == 2'd1) begin                    // changeable: page 0E's volume and selection
                    if (ms_cpg == 6'h0E && (ms_po == 5'd8 || ms_po == 5'd10)) syn = 8'h0F;
                    if (ms_cpg == 6'h0E && (ms_po == 5'd9 || ms_po == 5'd11)) syn = 8'hFF;
                end else case (ms_cpg)
                    6'h03: case (ms_po)                          // format: 64 sectors/track, 512 bytes
                        5'd11: syn = 8'd64; 5'd12: syn = 8'h02; default: ;
                    endcase
                    6'h04: case (ms_po)                          // geometry: 16 heads, cylinders = blocks / 1024
                        5'd2: syn = {2'b00, cap_n[31:26]}; 5'd3: syn = cap_n[25:18]; 5'd4: syn = cap_n[17:10];
                        5'd5: syn = 8'd16; 5'd20: syn = 8'h1C; 5'd21: syn = 8'h20;    // 7200 rpm
                        default: ;
                    endcase
                    6'h0D: case (ms_po)                          // CD-ROM: 60 S/M, 75 F/S
                        5'd5: syn = 8'd60; 5'd7: syn = 8'd75; default: ;
                    endcase
                    6'h0E: case (ms_po)                          // CD audio control: IMMED, ports 0/1
                        5'd2: syn = 8'h04;
                        5'd8: syn = {4'd0, ms_pc == 2'd2 ? 4'd1 : csel0}; 5'd9: syn = ms_pc == 2'd2 ? 8'hFF : vol0;
                        5'd10: syn = {4'd0, ms_pc == 2'd2 ? 4'd2 : csel1}; 5'd11: syn = ms_pc == 2'd2 ? 8'hFF : vol1;
                        default: ;
                    endcase
                    default: ;
                endcase
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------- engine
    wire [2:0] id_hit = {(img_present[2] || CD_ALWAYS != 0) && sel_id == CD_ID,
                         img_present[1] && sel_id == DISK1_ID, img_present[0] && sel_id == DISK0_ID};
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
    // the synthesised IN data of rl bytes, cut to the allocation length (in T_DLEN)
    task din_start;
        input [15:0] alloc;
        input [15:0] rl;
        begin
            dal <= alloc; drl <= rl; din_synth <= 1'b1;
            st <= T_DLEN; req <= 1'b0;      // DATA IN only once there are bytes (T_DLEN)
        end
    endtask

    integer d;
    always @(posedge clk) begin : eng
        reg [7:0]  m, op, t0, e0, nd, et;
        reg [31:0] lba, cnt, n;
        reg [15:0] alloc, rl;
        reg [9:0]  hl;
        reg        last_e, needs_disc, needs_toc, cd_only;
        reg [6:0]  ne;
        sel_done <= 1'b0; sel_fail <= 1'b0; b_we <= 1'b0;
        a_play <= 1'b0; a_pause <= 1'b0; a_resume <= 1'b0; a_stop <= 1'b0; a_stread <= 1'b0;
        toc_we <= 1'b0; fr_go <= 1'b0; fr_done <= 1'b0;
        sd_was_ack <= |ack_c;
        if (rst) begin
            e_rd <= 3'd0; e_wr <= 3'd0; sd_busy <= 1'b0; aud_xfer <= 1'b0;
            toc_ok <= 1'b0; toc_n <= 8'd0; toc_first <= 8'd1; toc_lsf <= 8'd1; toc_nses <= 8'd1; toc_lead <= 24'd0;
            vol0 <= 8'hFF; vol1 <= 8'hFF; csel0 <= 4'd1; csel1 <= 4'd2; a_stop <= 1'b1; cd_ua <= 1'b0;
            toc_a_r <= 7'd0;
        end else begin
            // block device handshake (not touched by a bus reset: a transfer in
            // flight completes): drop rd/wr when ack rises, done when it falls
            if (|(ack_c & (e_rd | e_wr))) begin e_rd <= 3'd0; e_wr <= 3'd0; end
            if (sd_busy && sd_was_ack && !(|ack_c) && !(|e_rd) && !(|e_wr)) begin
                sd_busy <= 1'b0;
                if (aud_xfer) begin aud_xfer <= 1'b0; fr_done <= 1'b1; end
            end
            // a new disc: its table is read again at the next command that needs
            // it, the play stops, the next command sees UNIT ATTENTION
            if (cd_change) begin toc_ok <= 1'b0; toc_n <= 8'd0; a_stop <= 1'b1; cd_ua <= 1'b1; end
            // a frame for the CD player, between the engine's own transfers
            if (fr_req && !fr_go && !sd_busy && cd_in &&
                st != T_FETCH && st != T_DOUT && st != T_STORE && st != T_TOC) begin
                sd_lba[64 +: 32] <= fr_lba; sd_blk_cnt[12 +: 6] <= 6'd4; e_rd[2] <= 1'b1; sd_busy <= 1'b1;
                aud_xfer <= 1'b1; fr_go <= 1'b1;
            end
        end
        if (rst || brst) begin
            st <= T_FREE; bsy <= 1'b0; req <= 1'b0;
            for (d = 0; d < 3; d = d + 1) begin skey[d] <= 4'd0; sasc[d] <= 8'd0; end
            pend <= 2'd0;
            // the block length is a mode parameter: only a power-on reset returns it to
            // 2048. SRM selects 512 once, when it opens the unit, and a bus reset (its port
            // init, a command timeout) does not make it select again: with 2048 after one,
            // a 1-block READ sent 2048 bytes into SRM's 512, its script's err104 and flush
            // skipped the status move, and SRM reported "bad SCSI status (b8)" (board, build 13)
            if (rst) cd_512 <= CD_BOOT512 != 0;
        end else begin
            case (st)
                T_FREE: if (sel) begin
                    if (id_hit != 3'd0) begin
                        dev <= id_hit[0] ? 2'd0 : id_hit[1] ? 2'd1 : 2'd2;
                        bsy <= 1'b1; sel_done <= 1'b1; lun <= 3'd0; msg_n <= 3'd0; sdtr_reply <= 1'b0;
                        if (sel_atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; end
                        else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 5'd0; end
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
                    end else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 5'd0; end
                end

                // MESSAGE IN (the SDTR reply), each byte held by the initiator
                T_MIN: begin
                    if (ack && req) begin req <= 1'b0; min_n <= min_n + 3'd1; hold_seen <= 1'b0; end
                    else if (!req) begin
                        if (ackhold) hold_seen <= 1'b1;
                        else if (atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; msg_n <= 3'd0; end
                        else if (min_n < min_len) begin req <= 1'b1; tdata <= min_b[min_n]; end
                        else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 5'd0; end
                    end
                end

                // the CDB (a 16-byte one keeps its first 12)
                T_CMD: if (ack && req) begin
                    if (cdb_n < 5'd12) cdb[cdb_n[3:0]] <= idata;
                    if (cdb_n == 5'd0) cdb_len <= cdb_length(idata);
                    cdb_n <= cdb_n + 5'd1;
                    req <= 1'b0;
                    if (cdb_n != 5'd0 && cdb_n + 5'd1 == cdb_len) st <= T_PRE1;
                end else if (!req) req <= 1'b1;

                T_PRE1: begin
                    op = cdb[0];
                    // block address and count of the READ/WRITE forms
                    if (op[7:5] == 3'd0) begin
                        lba_r <= {11'd0, cdb[1][4:0], cdb[2], cdb[3]};
                        cnt_r <= (cdb[4] == 8'd0 && (op == 8'h08 || op == 8'h0A)) ? 32'd256 : {24'd0, cdb[4]};
                    end else if (op == 8'hBE) begin                          // READ CD: 24-bit count
                        lba_r <= {cdb[2], cdb[3], cdb[4], cdb[5]};
                        cnt_r <= {8'd0, cdb[6], cdb[7], cdb[8]};
                    end else if (op[7:5] == 3'd5) begin
                        lba_r <= {cdb[2], cdb[3], cdb[4], cdb[5]};
                        cnt_r <= {cdb[6], cdb[7], cdb[8], cdb[9]};
                    end else begin
                        lba_r <= {cdb[2], cdb[3], cdb[4], cdb[5]};
                        cnt_r <= {16'd0, cdb[7], cdb[8]};
                    end
                    // the capacity in device blocks, for READ CAPACITY, the block descriptor, range checks
                    cap_n <= blocks >> bshift; cap_last <= (blocks >> bshift) - 32'd1;
                    cap_bl <= (bshift == 4'd2) ? 8'h08 : 8'h02;
                    capcd <= blocks >> 2;
                    // the CD's command classes
                    cdo_r <= op == 8'h43 || op == 8'h42 || op == 8'h45 || op == 8'h47 || op == 8'h48 ||
                             op == 8'hA5 || op == 8'h4B || op == 8'h4E || op == 8'hBE;
                    ntoc_r <= op == 8'h43 || op == 8'h42 || op == 8'h45 || op == 8'h47 || op == 8'h48 || op == 8'hA5;
                    ndisc_r <= !(op == 8'h12 || op == 8'h03 || op == 8'h1A || op == 8'h5A || op == 8'h15 ||
                                 op == 8'h55 || op == 8'h1B || op == 8'h1E || op == 8'h4E);
                    st <= T_PRE2;
                end
                T_PRE2: begin
                    t0 = cdb[6];
                    end_r <= lba_r + cnt_r;
                    tl_r <= toc_first + toc_n - 8'd1;
                    // READ TOC format 0: the first entry sent; a start track past the last
                    e0_r <= (t0 == 8'h00 || t0 <= toc_first) ? 8'd0 : t0 == 8'hAA ? toc_n : t0 - toc_first;
                    t0bad_r <= t0 != 8'hAA && t0 > toc_first + toc_n - 8'd1;
                    // format 2's length: 4 + 11 (n + 3)
                    rlt2_r <= 16'd37 + {5'd0, toc_n, 3'd0} + {7'd0, toc_n, 1'b0} + {8'd0, toc_n};
                    st <= T_EXEC;
                end

                T_EXEC: begin
                    op = cdb[0];
                    lba = lba_r; cnt = cnt_r;
                    d_idx <= 11'd0; ms_i <= 10'd0; ms_bdl <= 8'd0; ms_pg <= 6'h3F; ms_ps <= 10'd0;
                    cd_only = cdo_r; needs_toc = ntoc_r; needs_disc = ndisc_r;
                    if (lun != 3'd0 && op != 8'h12 && op != 8'h03) begin
                        check(4'h5, 8'h25);
                    end else if (is_cd && cd_ua && op != 8'h12 && op != 8'h03) begin
                        cd_ua <= 1'b0; check(4'h6, 8'h28);                 // MEDIUM MAY HAVE CHANGED
                    end else if (is_cd && cd_ua && op == 8'h03) begin
                        // REQUEST SENSE reports the attention and clears it
                        cd_ua <= 1'b0; skey[dev] <= 4'h6; sasc[dev] <= 8'h28;
                        din_start({8'd0, cdb[4]}, 16'd18);
                    end else if (is_cd && !cd_in && needs_disc) begin
                        check(4'h2, 8'h3A);                                // MEDIUM NOT PRESENT
                    end else if (is_cd && !toc_ok && needs_toc) begin
                        st <= T_TOC;                                       // the track table first
                    end else if (!is_cd && cd_only) begin
                        check(4'h5, 8'h20);
                    end else case (op)
                        8'h43: begin                                       // READ TOC
                            alloc = {cdb[7], cdb[8]};
                            rt_msf <= cdb[1][1];
                            // the format: MMC's byte 2, or the SCSI-2 vendor bits of byte 9
                            if (cdb[2][3:0] == 4'd1 || cdb[9][7:6] == 2'd1) begin
                                // the last session's first track
                                rt_fmt <= 2'd1; rt_first <= toc_lsf[6:0] - toc_first[6:0]; rt_ne <= 7'd1;
                                rt_len <= 16'd10; rt_h2 <= 8'd1; rt_h3 <= toc_nses;
                                toc_a_r <= toc_lsf[6:0] - toc_first[6:0];
                                good; din_start(alloc, 16'd12);
                            end else if (cdb[2][3:0] == 4'd2 || cdb[9][7:6] == 2'd2) begin
                                // the full TOC: A0, A1, A2, then the tracks
                                rt_fmt <= 2'd2; rt_ne <= toc_n[6:0] + 7'd3;
                                rt_len <= rlt2_r - 16'd2; rt_h2 <= 8'd1; rt_h3 <= 8'd1;
                                toc_a_r <= 7'd0;
                                good; din_start(alloc, rlt2_r);
                            end else if (cdb[2][3:0] != 4'd0 || cdb[9][7:6] == 2'd3) begin
                                check(4'h5, 8'h24);
                            end else if (t0bad_r) begin
                                check(4'h5, 8'h24);
                            end else begin
                                e0 = e0_r;
                                nd = toc_n + 8'd1 - e0;
                                rt_fmt <= 2'd0; rt_first <= e0[6:0]; rt_ne <= nd[6:0];
                                rt_len <= 16'd2 + {5'd0, nd, 3'd0}; rt_h2 <= toc_first; rt_h3 <= tl_r;
                                toc_a_r <= e0[6:0];
                                good; din_start(alloc, 16'd4 + {5'd0, nd, 3'd0});
                            end
                            rt_b <= 4'd0; rt_e <= 7'd0; rt_k <= 2'd0;
                        end
                        8'h42: begin                                       // READ SUB-CHANNEL
                            rs_status <= a_status; rs_ctl <= q_ctl; rs_track <= q_track;
                            rs_abs <= cdb[1][1] ? q_abs_msf : q_abs_lba;
                            rs_rel <= cdb[1][1] ? q_rel_msf : q_rel_lba;
                            a_stread <= 1'b1;
                            if (cdb[2][6] && (cdb[3] == 8'd0 || cdb[3] > 8'd3)) check(4'h5, 8'h24);
                            else begin
                                good;
                                din_start({cdb[7], cdb[8]}, !cdb[2][6] ? 16'd4 : cdb[3] == 8'd1 ? 16'd16 : 16'd24);
                            end
                        end
                        8'h45, 8'hA5, 8'h47: begin pl_s <= 3'd0; st <= T_PLAY; end      // PLAY AUDIO (10), (12), MSF
                        8'h48: begin                                       // PLAY AUDIO TRACK/INDEX
                            if (toc_n == 8'd0 || cdb[4] < toc_first || cdb[4] > tl_r) check(4'h5, 8'h24);
                            else begin
                                // the start of the first track, the start of the one after the last
                                toc_a_r <= cdb[4][6:0] - toc_first[6:0]; trk_s <= 3'd0; st <= T_TRK;
                            end
                        end
                        8'h4B: begin                                       // PAUSE/RESUME
                            if (!a_playing) check(4'h5, 8'h2C);            // COMMAND SEQUENCE ERROR
                            else begin
                                if (cdb[8][0]) a_resume <= 1'b1; else a_pause <= 1'b1;
                                good;
                            end
                        end
                        8'h4E: begin a_stop <= 1'b1; good; end             // STOP PLAY/SCAN
                        8'h1B: begin                                       // START STOP UNIT: stop ends a play
                            if (is_cd && !cdb[4][0]) a_stop <= 1'b1;
                            good;
                        end
                        8'h0B, 8'h2B: begin if (is_cd) a_stop <= 1'b1; good; end    // SEEK
                        8'h00, 8'h01, 8'h16, 8'h17, 8'h1D, 8'h1E, 8'h2F, 8'h35:
                            good;
                        8'h04: begin                                       // FORMAT UNIT: a defect list is taken, ignored
                            if (is_cd) check(4'h5, 8'h20);
                            else if (cdb[1][4]) begin
                                d_left <= 16'd4; x_blocks <= 32'd0; skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                st <= T_DOUT; phase <= P_DOUT; req <= 1'b1; chunk <= 12'd0;
                            end else good;
                        end
                        8'h37: begin                                       // READ DEFECT DATA
                            if (is_cd) check(4'h5, 8'h20);
                            else begin good; din_start({cdb[7], cdb[8]}, 16'd4); end
                        end
                        8'h12, 8'h03, 8'h25: begin
                            rl = (op == 8'h12) ? 16'd36 : (op == 8'h03) ? 16'd18 : 16'd8;
                            alloc = (op == 8'h25) ? 16'd8 : {8'd0, cdb[4]};
                            if (op == 8'h12 && cdb[1][0]) check(4'h5, 8'h24);          // EVPD: no pages
                            else begin
                                if (op != 8'h03) begin skey[dev] <= 4'd0; sasc[dev] <= 8'd0; end
                                din_start(alloc, rl);
                            end
                        end
                        8'h1A, 8'h5A: begin                                // MODE SENSE
                            if (!page_ok(cdb[2][5:0], is_cd)) check(4'h5, 8'h24);
                            else begin
                                hl = (op == 8'h5A) ? 10'd8 : 10'd4;
                                rl = {6'd0, hl} + (cdb[1][3] ? 16'd0 : 16'd8) + {8'd0, pages_len(cdb[2][5:0], is_cd)};
                                ms_10 <= op == 8'h5A; ms_pc <= cdb[2][7:6];
                                ms_len <= rl[7:0] - ((op == 8'h5A) ? 8'd2 : 8'd1);
                                ms_bdlen <= cdb[1][3] ? 8'd0 : 8'd8;
                                ms_sec <= 2'd0; ms_po <= 5'd0;
                                ms_cpg <= cdb[2][5:0] == 6'h3F ? 6'h01 : cdb[2][5:0];
                                good;
                                din_start((op == 8'h5A) ? {cdb[7], cdb[8]} : {8'd0, cdb[4]}, rl);
                            end
                        end
                        8'h08, 8'h28, 8'hA8, 8'hBE: begin                  // READ (6/10/12), READ CD
                            if (is_cd) a_stop <= 1'b1;                     // a data read ends a play
                            if (op == 8'hBE) begin
                                // user data of data sectors only (any type, or mode 1)
                                if ((cdb[1][4:2] != 3'd0 && cdb[1][4:2] != 3'd2) ||
                                    (cdb[9] != 8'h10 && cdb[9] != 8'h00) || cdb[10][2:0] != 3'd0) check(4'h5, 8'h24);
                                else if (cdb[9] == 8'h00 || cnt == 0) good;
                                else if (end_r > capcd) check(4'h5, 8'h21);
                                else begin
                                    x_lba <= lba << 2; x_blocks <= cnt << 2; din_synth <= 1'b0;
                                    skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                    st <= T_FETCH; phase <= P_DIN; req <= 1'b0;
                                end
                            end
                            else if (end_r > cap_n) check(4'h5, 8'h21);
                            else if (cnt == 0) good;
                            else begin
                                x_lba <= lba << bshift; x_blocks <= cnt << bshift; din_synth <= 1'b0;
                                skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                st <= T_FETCH; phase <= P_DIN; req <= 1'b0;
                            end
                        end
                        8'h0A, 8'h2A, 8'hAA, 8'h2E, 8'h15, 8'h55: begin    // WRITE (6/10/12), WRITE AND VERIFY, MODE SELECT
                            if (op == 8'h15 || op == 8'h55) begin
                                // the parameter list: the CD's block length and page 0E taken, the rest ignored
                                d_left <= (op == 8'h15) ? {8'd0, cdb[4]} : {cdb[7], cdb[8]};
                                x_blocks <= 32'd0;
                                skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                if (((op == 8'h15) ? cdb[4] : cdb[8]) == 8'd0 && (op == 8'h15 || cdb[7] == 8'd0)) go_status(8'h00);
                                else begin st <= T_DOUT; phase <= P_DOUT; req <= 1'b1; chunk <= 12'd0; end
                            end else if (is_cd) check(4'h7, 8'h27);       // write protected
                            else if (end_r > cap_n) check(4'h5, 8'h21);
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
                        b_addr <= 11'd0; pend <= 2'd2;
                        st <= T_DIN;
                    end
                end

                // DATA IN, from the synthesised response or the buffer. A byte is
                // sent two clocks after its cursors moved: toc_q / b_q, then syn_r
                T_DIN: begin
                    if (ack && req) begin
                        req <= 1'b0; pend <= 2'd2;
                        if (din_synth) begin
                            d_idx <= d_idx + 11'd1; d_left <= d_left - 16'd1;
                            // MODE SENSE: header, block descriptor, pages
                            case (ms_sec)
                                2'd0: if (d_idx[2:0] == (ms_10 ? 3'd7 : 3'd3)) begin
                                    ms_sec <= ms_bdlen != 8'd0 ? 2'd1 : 2'd2; ms_po <= 5'd0;
                                end
                                2'd1: if (ms_po == 5'd7) begin ms_sec <= 2'd2; ms_po <= 5'd0; end
                                      else ms_po <= ms_po + 5'd1;
                                default: if (ms_po == page_last(ms_cpg)) begin
                                    ms_po <= 5'd0; ms_cpg <= page_next(ms_cpg, is_cd);
                                end else ms_po <= ms_po + 5'd1;
                            endcase
                            // READ TOC: the entries after the 4-byte header
                            if (cdb[0] == 8'h43 && d_idx >= 11'd3) begin
                                if (d_idx != 11'd3 && rt_b != (rt_fmt == 2'd2 ? 4'd10 : 4'd7)) rt_b <= rt_b + 4'd1;
                                else begin
                                    ne = (d_idx == 11'd3) ? 7'd0 : rt_e + 7'd1;
                                    rt_b <= 4'd0; rt_e <= ne;
                                    if (rt_fmt == 2'd2) begin
                                        rt_k <= ne == 7'd0 ? 2'd0 : ne == 7'd1 ? 2'd1 : ne == 7'd2 ? 2'd2 : 2'd3;
                                        toc_a_r <= ne == 7'd0 ? 7'd0 : ne == 7'd1 ? toc_n[6:0] - 7'd1 :
                                                   ne == 7'd2 ? toc_n[6:0] : ne - 7'd3;
                                    end else toc_a_r <= rt_first + ne;
                                end
                            end
                        end
                        else begin b_addr <= b_addr + 11'd1; chunk <= chunk - 12'd1; end
                    end else if (!req && !sd_busy) begin
                        if (din_synth && d_left == 16'd0) go_status(8'h00);
                        else if (!din_synth && chunk == 12'd0) st <= T_FETCH;
                        else if (pend != 2'd0) pend <= pend - 2'd1;
                        else begin req <= 1'b1; tdata <= din_synth ? syn_r : b_q; end
                    end
                end

                // DATA OUT into the buffer, written to the image per chunk
                T_DOUT: begin
                    if (ack && req) begin
                        req <= 1'b0;
                        // a parameter list (MODE SELECT, FORMAT UNIT) is counted by
                        // d_left alone: chunk stays 0
                        if (x_blocks == 0 && d_left != 0) begin
                            d_left <= d_left - 16'd1;
                            if (cdb[0] == 8'h04) begin
                                // the defect list header: the list's length follows it
                                if (ms_i == 10'd2) ms_blhi <= idata;
                                if (ms_i == 10'd3) d_left <= {ms_blhi, idata};
                            end else begin
                                hl = (cdb[0] == 8'h15) ? 10'd4 : 10'd8;
                                if (ms_i == hl - 10'd1) begin ms_bdl <= idata; ms_ps <= hl + {2'd0, idata}; end
                                // the block descriptor's block length: 512 or 2048 on the CD
                                if (ms_bdl != 8'd0 && ms_i == hl + 10'd6) ms_blhi <= idata;
                                if (is_cd && ms_bdl != 8'd0 && ms_i == hl + 10'd7) begin
                                    if ({ms_blhi, idata} == 16'h0200) cd_512 <= 1'b1;
                                    else if ({ms_blhi, idata} == 16'h0800) cd_512 <= 1'b0;
                                end
                                // the pages: code, length, then page 0E's ports 0 and 1
                                if (ms_i >= hl && ms_i == ms_ps) ms_pg <= idata[5:0];
                                if (ms_i >= hl && ms_i == ms_ps + 10'd1) ms_pl <= idata;
                                if (ms_i >= hl && ms_i > ms_ps + 10'd1 && ms_i == ms_ps + 10'd1 + {2'd0, ms_pl})
                                    ms_ps <= ms_i + 10'd1;
                                if (is_cd && ms_pg == 6'h0E && ms_i == ms_ps + 10'd8)  csel0 <= idata[3:0];
                                if (is_cd && ms_pg == 6'h0E && ms_i == ms_ps + 10'd9)  vol0 <= idata;
                                if (is_cd && ms_pg == 6'h0E && ms_i == ms_ps + 10'd10) csel1 <= idata[3:0];
                                if (is_cd && ms_pg == 6'h0E && ms_i == ms_ps + 10'd11) vol1 <= idata;
                            end
                            if (ms_i != 10'h3FF) ms_i <= ms_i + 10'd1;
                        end
                        else begin b_we <= 1'b1; b_wdata <= idata; chunk <= chunk - 12'd1; end
                    end else if (!req) begin
                        if (b_we) b_addr <= b_addr + 11'd1;
                        if (x_blocks == 0 && d_left == 0 && chunk == 0 && !b_we) go_status(8'h00);
                        else if (x_blocks == 0 && d_left != 0) req <= 1'b1;
                        else if (chunk == 12'd0 && !b_we) begin
                            // once a CD frame in flight is done
                            if (!sd_busy) begin
                                n = (x_blocks >= 4) ? 32'd4 : x_blocks;
                                sd_lba[32 * dev +: 32] <= x_lba; sd_blk_cnt[6 * dev +: 6] <= n[5:0] - 6'd1;
                                e_wr[dev] <= 1'b1; sd_busy <= 1'b1;
                                x_lba <= x_lba + n; x_blocks <= x_blocks - n;
                                st <= T_STORE;
                            end
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
                // header bytes 0 (first track), 1 (n), 4 (the last session's first
                // track), 5 (sessions) and n + 1 entries of 8 bytes from byte 8 into
                // toc; then the command runs again. An empty table (a Main without
                // the window): one data track on the whole image (T_TOCFK)
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
                        else if (cp_b == 11'd4) toc_lsf <= b_q == 8'd0 ? toc_first : b_q;
                        else if (cp_b == 11'd5) toc_nses <= b_q == 8'd0 ? 8'd1 : b_q;
                        else if (cp_b >= 11'd8) begin
                            toc_wd[8 * (7 - cp_b[2:0]) +: 8] <= b_q;
                            if (cp_b[2:0] == 3'd7) begin toc_we <= 1'b1; toc_a_r <= n[9:3]; end
                            if (last_e) toc_lead <= {toc_wd[23:8], b_q};
                        end
                        if ((cp_b == 11'd1 && b_q == 8'd0) || last_e) cp_s <= 2'd3;
                        else begin cp_b <= cp_b + 11'd1; cp_s <= 2'd0; end
                    end
                    default: begin
                        if (toc_n == 8'd0) begin
                            fk_x <= {1'b0, cd_secs} + 20'd150;            // the image in 2048-byte sectors, + 150
                            fk_m <= 8'd0; fk_s <= 8'd0; fk_s2 <= 2'd0; st <= T_TOCFK;
                        end else begin toc_ok <= 1'b1; st <= T_PRE2; end
                    end
                endcase
                // the made-up table: track 1 at 00:02:00 (LBA 0), the lead-out at the image's end
                T_TOCFK: case (fk_s2)
                    2'd0: begin
                        toc_wd <= {8'h14, 8'd1, 8'd0, 8'd2, 8'd0, 24'd0}; toc_a_r <= 7'd0; toc_we <= 1'b1;
                        fk_s2 <= 2'd1;
                    end
                    2'd1: if (fk_x >= 20'd4500) begin fk_x <= fk_x - 20'd4500; fk_m <= fk_m + 8'd1; end
                          else if (fk_x >= 20'd75) begin fk_x <= fk_x - 20'd75; fk_s <= fk_s + 8'd1; end
                          else fk_s2 <= 2'd2;
                    default: begin
                        n = {13'd0, cd_secs};
                        toc_wd <= {8'h14, 8'hAA, fk_m, fk_s, fk_x[7:0], n[23:0]}; toc_a_r <= 7'd1; toc_we <= 1'b1;
                        toc_first <= 8'd1; toc_n <= 8'd1; toc_lsf <= 8'd1; toc_nses <= 8'd1; toc_lead <= n[23:0];
                        toc_ok <= 1'b1; st <= T_PRE2;
                    end
                endcase

                // data in: the length, the allocation length or the response's, the shorter
                T_DLEN: begin
                    n = {16'd0, (dal < drl) ? dal : drl};
                    d_left <= n[15:0];
                    // an allocation length of 0 goes from COMMAND straight to STATUS: a DATA IN
                    // on the lines, even without REQ, is taken by a JUMP IF DATA_IN (ARC 4.58's
                    // NCRC8xx then moves its 0-byte entry: IID, bus reset, no devices)
                    if (n[15:0] == 16'd0) go_status(8'h00);
                    else begin st <= T_DIN; phase <= P_DIN; pend <= 2'd2; end
                end

                // PLAY AUDIO (10), (12), MSF: the start and end LBAs, a step a clock
                // (M:S:F: M x 4500 + S x 75 + F - 150; FFFFFFFF / FF:FF:FF = the current position)
                T_PLAY: begin
                    pl_s <= pl_s + 3'd1;
                    case (pl_s)
                        3'd0: begin
                            pm0 <= {16'd0, cdb[3]} * 24'd4500; ps0 <= {8'd0, cdb[4]} * 16'd75;
                            pm1 <= {16'd0, cdb[6]} * 24'd4500; ps1 <= {8'd0, cdb[7]} * 16'd75;
                            pf0 <= {24'd0, cdb[5]} - 32'd150; pf1 <= {24'd0, cdb[8]} - 32'd150;
                            pcur <= (cdb[0] == 8'h47) ? (cdb[3] == 8'hFF && cdb[4] == 8'hFF && cdb[5] == 8'hFF)
                                                      : lba_r == 32'hFFFF_FFFF;
                        end
                        3'd1: begin
                            pt0 <= {8'd0, pm0} + {16'd0, ps0}; pt1 <= {8'd0, pm1} + {16'd0, ps1};
                        end
                        3'd2: begin
                            if (cdb[0] == 8'h47) begin
                                p0r <= pcur ? {8'd0, q_abs_lba} : pt0 + pf0; p1r <= pt1 + pf1;
                            end else begin
                                p0r <= pcur ? {8'd0, q_abs_lba} : lba_r;
                                p1r <= pcur ? {8'd0, q_abs_lba} + cnt_r : end_r;
                            end
                        end
                        3'd3: begin
                            pbad <= p0r > {8'd0, toc_lead} || (cdb[0] == 8'h47 && p1r < p0r);     // past the lead-out
                            pover <= p1r > {8'd0, toc_lead};
                        end
                        default: begin
                            if (pbad) check(4'h5, 8'h21);
                            else begin
                                a_start <= frame19(p0r); a_end <= frame19(pover ? {8'd0, toc_lead} : p1r);
                                a_play <= 1'b1; good;
                            end
                        end
                    endcase
                end

                // PLAY AUDIO TRACK/INDEX: from the first track's start to the start
                // of the track after the last (the lead-out for the last one)
                T_TRK: begin
                    trk_s <= trk_s + 3'd1;
                    if (trk_s == 3'd1) begin
                        a_start <= frame19({8'd0, toc_q[23:0]});
                        et = (cdb[7] == 8'd0 || cdb[7] > tl_r) ? tl_r :
                             cdb[7] < cdb[4] ? cdb[4] : cdb[7];
                        toc_a_r <= et[6:0] - toc_first[6:0] + 7'd1;
                    end
                    if (trk_s == 3'd3) begin
                        a_end <= frame19({8'd0, toc_q[23:0]}); a_play <= 1'b1;
                        good;
                    end
                end

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
