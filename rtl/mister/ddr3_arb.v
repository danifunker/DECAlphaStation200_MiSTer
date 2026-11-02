// The core's DDR3 clients on MiSTer's DDRAM bridge (sys DDRAM_*, 64-bit
// words, DDRAM_CLK = clk), one transaction at a time, in priority order:
//
//   1. the TGA's display fetch (sc_*): read bursts of 1..32 words, a line
//      ahead of the beam (rtl/tga/tga_scan.v); it must never wait behind
//      more than one other transaction
//   2. the TGA's VRAM port (vr_*): the CPU's frame buffer accesses and the
//      drawing engine. Writes go into a merge register (two longwords of a
//      quadword, or byte writes to one quadword, become one DDR3 write) and
//      a 16-entry FIFO, and are acknowledged as soon as they are queued;
//      a read waits until every queued write has gone out (so it sees them),
//      then reads 1..16 words
//   3. the flashbus ROM (rtl/mister/fbrom.v), through a DDRAM-like port
//      (fb_*): fbrom's own DDRAM_* signals connect here unchanged. It
//      alternates with the TGA port when both want the bus.
//   4. the LAN mailbox Main_MiSTer shares with the core (nb_*, the 21040's
//      rtl/net/tulip_nb.v): one 64-bit word a request at byte
//      0x1FF0_0000 + 8 x nb_addr, no deadline. It goes when nobody else
//      wants the bus, or after waiting 1024 cycles (then right after the
//      display fetch).
//
// Map (DDR3 bytes; DDRAM_ADDR counts 64-bit words):
//   0x3000_0000  flash image, 1 MB (fbrom's own addresses, passed through)
//   0x3010_0000  TGA VRAM, 2 MB: VRAM byte offset o at 0x3010_0000 + o
//
// Handshakes. sc_req / vr_req are held until sc_ack / vr_ack (one-cycle
// pulses, registered). A read's words follow as sc_rvalid / vr_rvalid with
// rdata, in order. A VRAM write is complete for the client with vr_ack.
module ddr3_arb #(
    parameter [28:0] VRAM_BASE = 29'h0602_0000     // byte 0x3010_0000
) (
    input  wire        clk,
    input  wire        rst,

    // TGA display fetch
    input  wire        sc_req,
    input  wire [17:0] sc_addr,         // VRAM quadword
    input  wire  [5:0] sc_len,          // 1..32
    output reg         sc_ack,
    output reg         sc_rvalid,

    // TGA VRAM port
    input  wire        vr_req,
    input  wire        vr_we,
    input  wire [17:0] vr_addr,         // VRAM quadword
    input  wire  [4:0] vr_len,          // reads: 1..16
    input  wire  [7:0] vr_be,
    input  wire [63:0] vr_wdata,
    output reg         vr_ack,
    output reg         vr_rvalid,
    output wire        vr_wq_empty,     // no write waiting in the merge register or the FIFO

    output reg  [63:0] rdata,           // with sc_rvalid / vr_rvalid

    // flashbus ROM (fbrom.v's DDRAM side)
    output wire        fb_busy,
    input  wire  [7:0] fb_burstcnt,
    input  wire [28:0] fb_addr,
    output wire [63:0] fb_dout,
    output wire        fb_dout_ready,
    input  wire        fb_rd,
    input  wire [63:0] fb_din,
    input  wire  [7:0] fb_be,
    input  wire        fb_we,

    // LAN mailbox (nb_req held until nb_ack; nb_rdata valid with nb_ack)
    input  wire        nb_req,
    input  wire        nb_we,
    input  wire [12:0] nb_addr,
    input  wire [63:0] nb_wdata,
    output reg         nb_ack,
    output reg  [63:0] nb_rdata,

    // MiSTer DDRAM bridge
    input  wire        DDRAM_BUSY,
    output reg   [7:0] DDRAM_BURSTCNT,
    output reg  [28:0] DDRAM_ADDR,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output reg         DDRAM_RD,
    output reg  [63:0] DDRAM_DIN,
    output reg   [7:0] DDRAM_BE,
    output reg         DDRAM_WE
);
    // ------------------------------------------------------------ write merge register
    reg         m_v;
    reg  [17:0] m_a;
    reg  [63:0] m_d;
    reg   [7:0] m_be;
    reg   [3:0] m_tmo;                  // cycles left before it goes to the FIFO anyway

    // ------------------------------------------------------------ write FIFO (16 x 90 bits, RAM)
    reg  [89:0] wq [0:15];
    reg  [89:0] wq_q;                   // the head entry, registered
    reg   [3:0] wq_h, wq_t;
    reg   [4:0] wq_n;
    reg         wq_qv;                  // wq_q is the head entry (not a slot written as it was read)
    wire        wq_full = wq_n[4];
    wire        wq_rdy  = wq_n != 5'd0 && wq_qv;
    assign vr_wq_empty = !m_v && wq_n == 5'd0;

    reg         wq_push;
    reg  [89:0] wq_pd;
    reg         wq_pop;
    wire  [3:0] wq_hn = wq_pop ? wq_h + 4'd1 : wq_h;
    always @(posedge clk) begin
        if (wq_push) wq[wq_t] <= wq_pd;
        wq_q  <= wq[wq_hn];
        wq_qv <= !(wq_push && wq_t == wq_hn);
    end

    // ------------------------------------------------------------ the bus
    localparam S_IDLE = 2'd0, S_CMD = 2'd1, S_RD = 2'd2;
    reg   [1:0] st;
    reg   [1:0] own;                    // the read in flight: 0 display, 1 VRAM port, 2 flash, 3 mailbox
    reg   [9:0] nb_wait;                // cycles the mailbox has waited
    reg         nb_late;                // ... 1024 of them: it goes next
    localparam [28:0] NB_BASE = 29'h03FE_0000;     // byte 0x1FF0_0000
    reg   [5:0] left;                   // read words still to come
    reg         last_tga;               // the TGA port went last: the flash goes first next time

    wire sc_want  = sc_req && !sc_ack;
    wire vrd_want = vr_req && !vr_we && !vr_ack && vr_wq_empty;
    wire tga_want = wq_rdy || vrd_want;
    wire fb_cmd   = fb_rd || fb_we;
    // the flash may go now (fbrom raises its command only after seeing !busy)
    wire nb_want  = nb_req && !nb_ack;
    wire fb_ok    = st == S_IDLE && !sc_want && !(nb_want && nb_late) && (!tga_want || last_tga);
    assign fb_busy       = !fb_ok;
    assign fb_dout       = DDRAM_DOUT;
    assign fb_dout_ready = DDRAM_DOUT_READY && st == S_RD && own == 2'd2;

    // a VRAM write into the merge register
    wire wr_in   = vr_req && vr_we && !vr_ack;
    wire wr_hit  = m_v && m_a == vr_addr;
    wire wr_take = wr_in && (wr_hit || !m_v || !wq_full);
    // the merge register goes to the FIFO: a different quadword arrives, its
    // time is up, or a read waits for it
    wire m_flush = m_v && !wq_full &&
                   ((wr_in && !wr_hit) || m_tmo == 4'd0 || (vr_req && !vr_we));

    integer k;
    always @(posedge clk) begin
        sc_ack <= 1'b0; sc_rvalid <= 1'b0;
        vr_ack <= 1'b0; vr_rvalid <= 1'b0; nb_ack <= 1'b0;
        if (!nb_want) begin nb_wait <= 10'd0; nb_late <= 1'b0; end
        else if (nb_wait == 10'h3FF) nb_late <= 1'b1;
        else nb_wait <= nb_wait + 10'd1;
        wq_push <= 1'b0; wq_pop <= 1'b0;
        if (DDRAM_DOUT_READY) rdata <= DDRAM_DOUT;

        // ---------------------------------------- merge register and FIFO
        if (m_v && m_tmo != 4'd0) m_tmo <= m_tmo - 4'd1;
        if (m_flush) begin
            wq_push <= 1'b1; wq_pd <= {m_a, m_be, m_d};
        end
        if (wr_take) begin
            vr_ack <= 1'b1; m_tmo <= 4'd15;
            if (wr_hit) begin
                for (k = 0; k < 8; k = k + 1) if (vr_be[k]) m_d[8*k +: 8] <= vr_wdata[8*k +: 8];
                m_be <= m_be | vr_be;
            end else begin
                m_v <= 1'b1; m_a <= vr_addr; m_d <= vr_wdata; m_be <= vr_be;
            end
        end else if (m_flush) m_v <= 1'b0;

        if (rst) begin
            st <= S_IDLE; DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; DDRAM_BURSTCNT <= 8'd1;
            m_v <= 1'b0; wq_h <= 4'd0; wq_t <= 4'd0; wq_n <= 5'd0; last_tga <= 1'b0;
            vr_ack <= 1'b0; sc_ack <= 1'b0; wq_push <= 1'b0;
        end else begin
            if (wq_push) wq_t <= wq_t + 4'd1;
            if (wq_pop)  wq_h <= wq_h + 4'd1;
            wq_n <= wq_n + {4'd0, wq_push} - {4'd0, wq_pop};

            case (st)
            S_IDLE: begin
                if (sc_want) begin
                    DDRAM_ADDR <= VRAM_BASE + {11'd0, sc_addr}; DDRAM_BURSTCNT <= {2'b00, sc_len};
                    DDRAM_RD <= 1'b1; own <= 2'd0; left <= sc_len; sc_ack <= 1'b1; st <= S_CMD;
                end else if (nb_want && nb_late) begin
                    DDRAM_ADDR <= NB_BASE + {16'd0, nb_addr}; DDRAM_BURSTCNT <= 8'd1; DDRAM_BE <= 8'hFF;
                    DDRAM_DIN <= nb_wdata; DDRAM_RD <= !nb_we; DDRAM_WE <= nb_we;
                    own <= 2'd3; left <= 6'd1; nb_late <= 1'b0; nb_wait <= 10'd0; st <= S_CMD;
                end else if (fb_cmd && fb_ok) begin
                    DDRAM_ADDR <= fb_addr; DDRAM_BURSTCNT <= fb_burstcnt;
                    DDRAM_RD <= fb_rd; DDRAM_WE <= fb_we && !fb_rd; DDRAM_DIN <= fb_din; DDRAM_BE <= fb_be;
                    own <= 2'd2; left <= fb_burstcnt[5:0]; last_tga <= 1'b0; st <= S_CMD;
                end else if (wq_rdy) begin
                    DDRAM_ADDR <= VRAM_BASE + {11'd0, wq_q[89:72]}; DDRAM_BURSTCNT <= 8'd1;
                    DDRAM_BE <= wq_q[71:64]; DDRAM_DIN <= wq_q[63:0]; DDRAM_WE <= 1'b1;
                    wq_pop <= 1'b1; own <= 2'd1; last_tga <= 1'b1; st <= S_CMD;
                end else if (vrd_want) begin
                    DDRAM_ADDR <= VRAM_BASE + {11'd0, vr_addr}; DDRAM_BURSTCNT <= {3'b000, vr_len};
                    DDRAM_RD <= 1'b1; own <= 2'd1; left <= {1'b0, vr_len}; vr_ack <= 1'b1;
                    last_tga <= 1'b1; st <= S_CMD;
                end else if (nb_want && !fb_cmd) begin
                    DDRAM_ADDR <= NB_BASE + {16'd0, nb_addr}; DDRAM_BURSTCNT <= 8'd1; DDRAM_BE <= 8'hFF;
                    DDRAM_DIN <= nb_wdata; DDRAM_RD <= !nb_we; DDRAM_WE <= nb_we;
                    own <= 2'd3; left <= 6'd1; st <= S_CMD;
                end
            end
            // the command stays on the bus until the bridge takes it
            S_CMD: if (!DDRAM_BUSY) begin
                DDRAM_WE <= 1'b0; DDRAM_RD <= 1'b0;
                st <= DDRAM_RD ? S_RD : S_IDLE;
                if (DDRAM_WE && own == 2'd3) nb_ack <= 1'b1;
            end
            S_RD: if (DDRAM_DOUT_READY) begin
                if (own == 2'd0) sc_rvalid <= 1'b1;
                if (own == 2'd1) vr_rvalid <= 1'b1;
                if (own == 2'd3) begin nb_ack <= 1'b1; nb_rdata <= DDRAM_DOUT; end
                left <= left - 6'd1;
                if (left == 6'd1) st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
