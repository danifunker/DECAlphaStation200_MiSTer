//============================================================================
//
//  DEC AlphaStation 200 - the 21040's wire: Main_MiSTer's Ethernet mailbox
//
//  The mailbox is the one the user's other cores share with Main_MiSTer
//  (support/hp9k/hp9k_enet.cpp, support/ibmrs6k/ibmrs6k_enet.cpp,
//  support/sun/sun_enet.cpp; here support/decalpha/decalpha_enet.cpp): 64 KB
//  of DDR3 at byte 0x1FF0_0000, 64-bit little-endian words. nb_addr is the
//  word offset (byte offset / 8):
//
//    word 0  magic "DAETH001" (written last at start-up; Main reads the RX
//            ring depth from it: 16)
//    word 1  generation (new at every start-up)
//    word 2  TXW  core: frames posted        word 3  TXR  Main: frames taken
//    word 4  RXW  Main: frames posted        word 5  RXR  core: frames taken
//    word 6  the station address the chip answers to: bit 63 valid, bits
//            47:40 the first byte (Main filters the host interface on it)
//    word 7  PMAC, Main's: bit 63 valid, bit 62 the bridge is up (link),
//            bits 47:0 the address for the Ethernet ID ROM (08-00-2B and
//            the low three bytes of the MiSTer's eth0)
//    0x1000  8 TX slots of 2 KB: word 0 = length (bits 10:0, no FCS), the
//            frame from word 1
//    0x5000  16 RX slots of 2 KB: word 0 = length with the FCS (bits 10:0),
//            the frame from word 1 (Main pads to 60 bytes and appends the FCS)
//
//  The core side (docs/design/ethernet.md 5): nb_req is held until the
//  one-cycle nb_ack; nb_we, nb_addr and nb_wdata are steady meanwhile;
//  nb_rdata is valid with nb_ack. All 8 bytes are written.
//
//  Towards the chip: a frame to send sits in the chip's TX buffer (tx_req,
//  tx_len, read through tbr_addr -> tbr_data one cycle later), tx_done takes
//  it; a received frame is written into the chip's RX buffer while rx_gnt
//  is up (rbw_*), then rx_put with its length. RXW is polled every POLL
//  cycles, PMAC every 16th poll (every poll until Main has written it).
//
//============================================================================

module tulip_nb #(
    parameter POLL = 4096
) (
    input  wire        clk,
    input  wire        reset,

    input  wire [47:0] mac,             // published in word 6

    output reg         nb_req,
    output reg         nb_we,
    output reg  [12:0] nb_addr,
    output reg  [63:0] nb_wdata,
    input  wire        nb_ack,
    input  wire [63:0] nb_rdata,

    output reg  [47:0] pmac,            // word 7
    output reg         pmac_ok,
    output reg         link,

    input  wire        tx_req,
    input  wire [10:0] tx_len,
    output reg         tx_done,
    output reg   [8:0] tbr_addr,
    input  wire [31:0] tbr_data,

    input  wire        rx_ok,           // the chip would take a frame now
    output reg         rx_req,
    input  wire        rx_gnt,
    output reg         rbw_we,
    output reg   [8:0] rbw_addr,
    output reg  [31:0] rbw_data,
    output reg         rx_put,
    output reg  [10:0] rx_plen
);

localparam [12:0] W_MAGIC = 13'd0, W_GEN = 13'd1, W_TXW = 13'd2, W_TXR = 13'd3,
                  W_RXW = 13'd4, W_RXR = 13'd5, W_MAC = 13'd6, W_PMAC = 13'd7;
localparam [12:0] W_TX = 13'h0200, W_RX = 13'h0A00;            // 0x1000 / 8, 0x5000 / 8
localparam [63:0] MAGIC = 64'h4441_4554_4830_3031;              // "DAETH001"

localparam [4:0] N_BOOT = 5'd0, N_IDLE = 5'd1, N_MEM = 5'd2,
                 N_T0 = 5'd3, N_T1 = 5'd4, N_T2 = 5'd5, N_T3 = 5'd6, N_T4 = 5'd7, N_T5 = 5'd8,
                 N_T6 = 5'd9, N_T7 = 5'd10, N_TW = 5'd11,
                 N_R0 = 5'd12, N_R1 = 5'd13, N_R2 = 5'd14, N_R3 = 5'd15, N_R4 = 5'd16,
                 N_R5 = 5'd17, N_R6 = 5'd18, N_R7 = 5'd19, N_P0 = 5'd20;

reg  [4:0]  st, ret;
reg  [3:0]  bk;
reg  [15:0] tick;
reg  [31:0] txw, rxr;
reg  [12:0] slot;
reg  [7:0]  k;                          // the mailbox word in the slot (8 bytes each)
reg  [10:0] len;
reg  [31:0] lo;
reg  [63:0] q;                          // the word read
reg  [15:0] tx_wait;
reg  [15:0] poll;
reg  [3:0]  npoll;
reg  [47:0] mac_pub;

// one mailbox word, then ret
task nb;
    input [12:0] a; input w; input [63:0] d; input [4:0] r;
    begin nb_addr <= a; nb_we <= w; nb_wdata <= d; nb_req <= 1'b1; ret <= r; st <= N_MEM; end
endtask

wire [7:0] k_end = len[10:3] + {7'd0, len[2:0] != 3'd0};     // the slot's frame words

always @(posedge clk) begin
    tx_done <= 1'b0;
    rbw_we  <= 1'b0;
    rx_put  <= 1'b0;
    tick    <= tick + 16'd1;
    if (poll != 16'd0) poll <= poll - 16'd1;

    case (st)
        N_MEM: if (nb_ack) begin nb_req <= 1'b0; q <= nb_rdata; st <= ret; end

        // ---- start-up: the magic off, the ring pointers zero, the addresses, the
        // generation, the magic last (the order Main's bridges expect)
        N_BOOT: begin
            bk <= bk + 4'd1;
            txw <= 32'd0; rxr <= 32'd0;
            case (bk)
                4'd0: nb(W_MAGIC, 1'b1, 64'd0, N_BOOT);
                4'd1: nb(W_TXW, 1'b1, 64'd0, N_BOOT);
                4'd2: nb(W_TXR, 1'b1, 64'd0, N_BOOT);
                4'd3: nb(W_RXW, 1'b1, 64'd0, N_BOOT);
                4'd4: nb(W_RXR, 1'b1, 64'd0, N_BOOT);
                4'd5: begin mac_pub <= mac; nb(W_MAC, 1'b1, {16'h8000, mac}, N_BOOT); end
                4'd6: nb(W_PMAC, 1'b1, 64'd0, N_BOOT);
                4'd7: nb(W_GEN, 1'b1, {48'd0, tick}, N_BOOT);
                default: nb(W_MAGIC, 1'b1, MAGIC, N_IDLE);
            endcase
        end

        N_IDLE: begin
            if (mac != mac_pub) begin
                mac_pub <= mac; nb(W_MAC, 1'b1, {16'h8000, mac}, N_IDLE);
            end else if (tx_req && !tx_done) begin
                tx_wait <= 16'd0; nb(W_TXR, 1'b0, 64'd0, N_T0);
            end else if (poll == 16'd0) begin
                poll <= POLL[15:0]; npoll <= npoll + 4'd1;
                if (npoll == 4'd0 || !pmac_ok) nb(W_PMAC, 1'b0, 64'd0, N_P0);     // until Main has written it
                else nb(W_RXW, 1'b0, 64'd0, N_R0);
            end
        end

        N_P0: begin
            pmac_ok <= q[63]; link <= q[63] && q[62];
            if (q[63]) pmac <= q[47:0];
            st <= N_IDLE;
        end

        // ---- a frame out: a free TX slot (Main empties them; a ring full for
        // ~65000 tries drops the frame), the words, the header, TXW
        N_T0: if (txw - q[31:0] < 32'd8) begin
            slot <= W_TX + {2'd0, txw[2:0], 8'd0}; len <= tx_len; k <= 8'd0; st <= N_T1;
        end else if (tx_wait == 16'hFFFF) begin
            tx_done <= 1'b1; st <= N_IDLE;
        end else begin
            tx_wait <= tx_wait + 16'd1; poll <= 16'd255; st <= N_TW;
        end
        N_TW: if (poll == 16'd0) nb(W_TXR, 1'b0, 64'd0, N_T0);
        N_T1: begin tbr_addr <= {k, 1'b0}; st <= N_T2; end
        N_T2: begin tbr_addr <= {k, 1'b1}; st <= N_T3; end
        N_T3: begin lo <= tbr_data; st <= N_T4; end
        N_T4: nb(slot + 13'd1 + {5'd0, k}, 1'b1, {tbr_data, lo}, N_T5);
        N_T5: begin
            k <= k + 8'd1;
            if (k + 8'd1 >= k_end) nb(slot, 1'b1, {53'd0, len}, N_T6);
            else st <= N_T1;
        end
        N_T6: begin txw <= txw + 32'd1; nb(W_TXW, 1'b1, {32'd0, txw + 32'd1}, N_T7); end
        N_T7: begin tx_done <= 1'b1; st <= N_IDLE; end

        // ---- a frame in: RXW moved and the chip can take one
        N_R0: if (q[31:0] != rxr && rx_ok) begin
            slot <= W_RX + {1'b0, rxr[3:0], 8'd0};
            nb(W_RX + {1'b0, rxr[3:0], 8'd0}, 1'b0, 64'd0, N_R1);
        end else st <= N_IDLE;
        N_R1: begin
            len <= q[10:0]; k <= 8'd0;
            if (q[10:0] < 11'd14 || q[10:0] > 11'd2040) st <= N_R7;     // not a frame: skip it
            else begin rx_req <= 1'b1; st <= N_R2; end
        end
        N_R2: if (rx_gnt) nb(slot + 13'd1, 1'b0, 64'd0, N_R3);
        N_R3: begin rbw_we <= 1'b1; rbw_addr <= {k, 1'b0}; rbw_data <= q[31:0]; st <= N_R4; end
        N_R4: begin
            rbw_we <= 1'b1; rbw_addr <= {k, 1'b1}; rbw_data <= q[63:32];
            k <= k + 8'd1;
            if (k + 8'd1 >= k_end) st <= N_R5;
            else nb(slot + 13'd2 + {5'd0, k}, 1'b0, 64'd0, N_R3);
        end
        N_R5: begin rx_put <= 1'b1; rx_plen <= len; rx_req <= 1'b0; st <= N_R7; end
        N_R7: begin rxr <= rxr + 32'd1; poll <= 16'd0; nb(W_RXR, 1'b1, {32'd0, rxr + 32'd1}, N_IDLE); end   // more may wait

        default: st <= N_IDLE;
    endcase

    if (reset) begin
        st <= N_BOOT; bk <= 4'd0; nb_req <= 1'b0; nb_we <= 1'b0; nb_addr <= 13'd0;
        pmac_ok <= 1'b0; link <= 1'b0; pmac <= 48'd0;
        rx_req <= 1'b0; tx_done <= 1'b0; rx_put <= 1'b0; rbw_we <= 1'b0;
        poll <= 16'd0; npoll <= 4'd0; tbr_addr <= 9'd0;
    end
end

endmodule
