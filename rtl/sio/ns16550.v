// NS16550A-compatible UART: one of the PC87332 Super I/O's two serial ports
// (COM1 at 3F8h, COM2 at 2F8h; docs/CORE_SPEC.md). Registers, 16-byte FIFOs,
// the interrupt identification priorities, the character timeout, the modem
// lines and the MCR loopback, as in the National 16550A data sheet.
//
// Bus: one access per io_rd/io_wr strobe (one clk), io_addr = A2..A0.
// Read data is combinational from the register state; the side effects of a
// read (RBR pops the FIFO, IIR clears THRE, LSR clears its error bits, MSR its
// delta bits) happen on the io_rd clock.
//
// Baud: ce_1m8 is a 1.8432 MHz enable (the PC crystal); the divisor latch
// divides it into the 16x bit clock, so DLL = 12 is 9600 baud.
//
// For the MiSTer side: tx_stb/tx_byte pulse when a character goes into the
// transmit shift register (the on-screen serial terminal reads them), and
// rx_inj_stb/rx_inj_byte put a character straight into the receive FIFO (the
// MiSTer keyboard typing into the console).
module ns16550 (
    input  wire       clk,
    input  wire       rst,
    input  wire       ce_1m8,

    input  wire [2:0] io_addr,
    input  wire       io_rd,
    input  wire       io_wr,
    input  wire [7:0] io_din,
    output reg  [7:0] io_dout,
    output wire       irq,

    output wire       txd,
    input  wire       rxd,
    output wire       rts_n,
    output wire       dtr_n,
    output wire       out1_n,
    output wire       out2_n,
    input  wire       cts_n,
    input  wire       dsr_n,
    input  wire       ri_n,
    input  wire       dcd_n,

    output reg        tx_stb,
    output reg  [7:0] tx_byte,
    input  wire       rx_inj_stb,
    input  wire [7:0] rx_inj_byte
);
    // ---------------------------------------------------------------- registers
    reg  [7:0] ier, lcr, mcr, scr, dll, dlm;
    reg        fifo_en;
    reg  [1:0] rx_trig;
    reg  [3:0] msr_delta;           // DDCD TERI DDSR DCTS, MSR[3:0]
    reg  [3:0] msr_q;               // DCD RI DSR CTS as last seen
    reg        lsr_oe, lsr_pe, lsr_fe, lsr_bi;
    reg        thre_ip;             // THRE interrupt pending
    reg        rx_timeout;

    wire dlab = lcr[7];
    wire loop = mcr[4];

    // ---------------------------------------------------------------- baud clock
    reg [15:0] div_cnt;
    reg        tick16;              // 16x bit clock enable
    wire [15:0] divisor = {dlm, dll};
    always @(posedge clk) begin
        tick16 <= 1'b0;
        if (rst) div_cnt <= 16'd0;
        else if (ce_1m8) begin
            if (div_cnt <= 16'd1) begin
                div_cnt <= divisor;
                tick16  <= divisor != 16'd0;
            end else
                div_cnt <= div_cnt - 16'd1;
        end
    end

    // ---------------------------------------------------------------- FIFOs
    // receive entries carry {break, framing, parity, data}
    reg [10:0] rxf [0:15];
    reg [3:0]  rxf_rd, rxf_wr;
    reg [4:0]  rxf_n;
    reg [7:0]  txf [0:15];
    reg [3:0]  txf_rd, txf_wr;
    reg [4:0]  txf_n;

    wire [10:0] rx_head = rxf[rxf_rd];
    wire        rx_any  = rxf_n != 5'd0;
    wire        rxf_err = rx_any && (rx_head[10] || rx_head[9] || rx_head[8]);

    // any error anywhere in the FIFO (LSR bit 7)
    reg  [15:0] err_mask;
    integer k;
    always @* begin
        for (k = 0; k < 16; k = k + 1) err_mask[k] = |rxf[k][10:8];
    end
    reg fifo_err_any;
    always @* begin
        fifo_err_any = 1'b0;
        for (k = 0; k < 16; k = k + 1)
            if (((k - rxf_rd) & 4'hF) < rxf_n && err_mask[k]) fifo_err_any = 1'b1;
    end

    wire [4:0] rx_level = rx_trig == 2'd0 ? 5'd1 : rx_trig == 2'd1 ? 5'd4 :
                          rx_trig == 2'd2 ? 5'd8 : 5'd14;
    wire rda = fifo_en ? (rxf_n >= rx_level) : rx_any;

    // ---------------------------------------------------------------- transmitter
    reg  [3:0] tx_sub;              // 16x ticks into the current bit
    reg  [3:0] tx_bit;              // bits left in the frame
    reg [11:0] tx_sh;
    reg        tx_busy;
    reg        tx_line;

    wire [3:0] data_bits = 4'd5 + lcr[1:0];
    function [7:0] mask_len;
        input [7:0] d; input [1:0] len;
        mask_len = len == 2'd0 ? {3'b0, d[4:0]} : len == 2'd1 ? {2'b0, d[5:0]} :
                   len == 2'd2 ? {1'b0, d[6:0]} : d;
    endfunction
    // parity of the data bits as sent: even parity bit = XOR of the bits
    wire [7:0] tx_d     = mask_len(txf[txf_rd], lcr[1:0]);
    wire       tx_par   = lcr[5] ? ~lcr[4] : (^tx_d) ^ ~lcr[4];

    // ---------------------------------------------------------------- receiver
    wire rx_in = loop ? tx_line : rxd;
    reg  [2:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[1:0], rx_in};
    wire rx_s = rx_sync[2];

    reg        rx_busy;
    reg  [3:0] rx_sub;
    reg  [3:0] rx_bit;              // bits sampled so far (start = 0)
    reg  [9:0] rx_sh;               // data then parity then stop, LSB first
    reg  [9:0] rx_idle;             // 16x ticks since the FIFO last changed

    wire [3:0] rx_frame = 4'd1 + data_bits + {3'b0, lcr[3]} + 4'd1;   // start..stop

    // ---------------------------------------------------------------- reads
    wire [3:0] msr_now = loop ? {mcr[3], mcr[2], mcr[0], mcr[1]}
                              : {~dcd_n, ~ri_n, ~dsr_n, ~cts_n};
    wire tx_empty = txf_n == 5'd0;
    wire temt     = tx_empty && !tx_busy;

    reg [3:0] iid;
    always @* begin
        if (ier[2] && (lsr_oe || lsr_pe || lsr_fe || lsr_bi || rxf_err)) iid = 4'b0110;
        else if (ier[0] && rda)                                   iid = 4'b0100;
        else if (ier[0] && rx_timeout && fifo_en)                 iid = 4'b1100;
        else if (ier[1] && thre_ip)                               iid = 4'b0010;
        else if (ier[3] && |msr_delta)                            iid = 4'b0000;
        else                                                      iid = 4'b0001;
    end
    assign irq = !iid[0];

    wire [7:0] lsr = {fifo_en ? fifo_err_any : 1'b0, temt, tx_empty,
                      lsr_bi || (rx_any && rx_head[10]),
                      lsr_fe || (rx_any && rx_head[9]),
                      lsr_pe || (rx_any && rx_head[8]), lsr_oe, rx_any};

    always @* begin
        case (io_addr)
            3'd0: io_dout = dlab ? dll : rx_head[7:0];
            3'd1: io_dout = dlab ? dlm : {4'b0, ier[3:0]};
            3'd2: io_dout = {fifo_en, fifo_en, 2'b00, iid};
            3'd3: io_dout = lcr;
            3'd4: io_dout = {3'b0, mcr[4:0]};
            3'd5: io_dout = lsr;
            3'd6: io_dout = {msr_now, msr_delta};
            default: io_dout = scr;
        endcase
    end

    assign txd    = loop ? 1'b1 : (tx_line & ~lcr[6]);
    assign rts_n  = loop ? 1'b1 : ~mcr[1];
    assign dtr_n  = loop ? 1'b1 : ~mcr[0];
    assign out1_n = loop ? 1'b1 : ~mcr[2];
    assign out2_n = loop ? 1'b1 : ~mcr[3];

    // ---------------------------------------------------------------- state
    reg        rx_push;
    reg [10:0] rx_push_d;

    always @(posedge clk) begin
        tx_stb  <= 1'b0;
        rx_push  = 1'b0;
        rx_push_d = 11'd0;
        if (rst) begin
            ier <= 8'd0; lcr <= 8'd0; mcr <= 8'd0; scr <= 8'd0;
            dll <= 8'd12; dlm <= 8'd0;
            fifo_en <= 1'b0; rx_trig <= 2'd0;
            msr_delta <= 4'd0; msr_q <= 4'd0;
            lsr_oe <= 1'b0; lsr_pe <= 1'b0; lsr_fe <= 1'b0; lsr_bi <= 1'b0;
            thre_ip <= 1'b0; rx_timeout <= 1'b0;
            rxf_rd <= 4'd0; rxf_wr <= 4'd0; rxf_n <= 5'd0;
            txf_rd <= 4'd0; txf_wr <= 4'd0; txf_n <= 5'd0;
            tx_busy <= 1'b0; tx_line <= 1'b1; tx_sub <= 4'd0; tx_bit <= 4'd0;
            rx_busy <= 1'b0; rx_sub <= 4'd0; rx_bit <= 4'd0; rx_idle <= 10'd0;
        end else begin
            // ------------------------------------------------ modem status deltas
            msr_q <= msr_now;
            if (msr_now[0] != msr_q[0]) msr_delta[0] <= 1'b1;
            if (msr_now[1] != msr_q[1]) msr_delta[1] <= 1'b1;
            if (!msr_now[2] && msr_q[2]) msr_delta[2] <= 1'b1;     // RI trailing edge
            if (msr_now[3] != msr_q[3]) msr_delta[3] <= 1'b1;

            // ------------------------------------------------ transmitter
            if (!tx_busy) begin
                if (!tx_empty) begin
                    // the start bit goes out now; tx_sh holds the rest, LSB
                    // first: data, [parity], then ones for the stop bits
                    tx_sh   <= (12'hFFF << (data_bits + {3'b0, lcr[3]}))
                             | ({11'd0, lcr[3] & tx_par} << data_bits)
                             | {4'd0, tx_d};
                    tx_byte <= txf[txf_rd];
                    tx_stb  <= 1'b1;
                    txf_rd  <= txf_rd + 4'd1;
                    txf_n   <= txf_n - 5'd1;
                    if (txf_n == 5'd1) thre_ip <= 1'b1;
                    tx_busy <= 1'b1;
                    tx_sub  <= 4'd0;
                    tx_line <= 1'b0;
                    // start + data + parity + stop (1, or 2; 1.5 for 5 bits is sent as 2)
                    tx_bit  <= 4'd1 + data_bits + {3'b0, lcr[3]} + (lcr[2] ? 4'd2 : 4'd1);
                end
            end else if (tick16) begin
                tx_sub <= tx_sub + 4'd1;
                if (tx_sub == 4'd15) begin
                    tx_bit <= tx_bit - 4'd1;
                    if (tx_bit == 4'd1) begin
                        tx_busy <= 1'b0;
                        tx_line <= 1'b1;
                    end else begin
                        tx_sh   <= {1'b1, tx_sh[11:1]};
                        tx_line <= tx_sh[0];
                    end
                end
            end

            // ------------------------------------------------ receiver
            if (tick16) begin
                if (rx_idle != 10'h3FF) rx_idle <= rx_idle + 10'd1;
                // character timeout: 4 character times (about 40 bits) with
                // data in the FIFO and nothing received or read
                if (rx_any && rx_idle >= 10'd640) rx_timeout <= 1'b1;
                if (!rx_busy) begin
                    if (!rx_s) begin
                        rx_busy <= 1'b1;
                        rx_sub  <= 4'd0;
                        rx_bit  <= 4'd0;
                    end
                end else begin
                    rx_sub <= rx_sub + 4'd1;
                    if (rx_sub == 4'd7) begin
                        if (rx_bit == 4'd0) begin
                            if (rx_s) rx_busy <= 1'b0;   // false start bit
                            else rx_bit <= 4'd1;
                        end else begin
                            rx_sh  <= {rx_s, rx_sh[9:1]};
                            rx_bit <= rx_bit + 4'd1;
                            if (rx_bit == rx_frame - 4'd1) begin
                                // stop bit sampled: rx_s; the data/parity are in
                                // rx_sh, right-aligned after one more shift
                                rx_busy <= 1'b0;
                                rx_push  = 1'b1;
                                rx_push_d = rx_frame_decode({rx_s, rx_sh[9:1]}, lcr[3:0], lcr[5:4]);
                            end
                        end
                    end
                end
            end
            if (rx_inj_stb) begin
                rx_push   = 1'b1;
                rx_push_d = {3'b000, rx_inj_byte};
            end

            // ------------------------------------------------ register writes
            if (io_wr) begin
                case (io_addr)
                    3'd0: if (dlab) dll <= io_din;
                          else if (txf_n != (fifo_en ? 5'd16 : 5'd1)) begin
                              txf[txf_wr] <= io_din;
                              txf_wr  <= txf_wr + 4'd1;
                              txf_n   <= txf_n + 5'd1 - ((!tx_busy && !tx_empty) ? 5'd1 : 5'd0);
                              thre_ip <= 1'b0;
                          end
                    3'd1: if (dlab) dlm <= io_din;
                          else begin
                              ier <= {4'b0, io_din[3:0]};
                              // enabling THRE with the holding register empty interrupts at once
                              if (io_din[1] && !ier[1] && tx_empty) thre_ip <= 1'b1;
                          end
                    3'd2: begin
                              if (io_din[0] != fifo_en) begin
                                  rxf_rd <= 4'd0; rxf_wr <= 4'd0; rxf_n <= 5'd0;
                                  txf_rd <= 4'd0; txf_wr <= 4'd0; txf_n <= 5'd0;
                              end
                              fifo_en <= io_din[0];
                              rx_trig <= io_din[7:6];
                              if (io_din[1]) begin rxf_rd <= 4'd0; rxf_wr <= 4'd0; rxf_n <= 5'd0; rx_timeout <= 1'b0; end
                              if (io_din[2]) begin txf_rd <= 4'd0; txf_wr <= 4'd0; txf_n <= 5'd0; thre_ip <= 1'b1; end
                          end
                    3'd3: lcr <= io_din;
                    3'd4: mcr <= {3'b0, io_din[4:0]};
                    3'd7: scr <= io_din;
                    default: ;
                endcase
            end

            // ------------------------------------------------ read side effects
            if (io_rd) begin
                case (io_addr)
                    3'd0: if (!dlab && rx_any) begin
                              rxf_rd     <= rxf_rd + 4'd1;
                              rxf_n      <= rxf_n - 5'd1 + (rx_push ? 5'd1 : 5'd0);
                              rx_timeout <= 1'b0;
                              rx_idle    <= 10'd0;
                          end
                    3'd2: if (iid == 4'b0010) thre_ip <= 1'b0;
                    3'd5: begin lsr_oe <= 1'b0; lsr_pe <= 1'b0; lsr_fe <= 1'b0; lsr_bi <= 1'b0; end
                    3'd6: msr_delta <= 4'd0;
                    default: ;
                endcase
            end

            // ------------------------------------------------ receive FIFO push
            if (rx_push) begin
                rx_idle    <= 10'd0;
                rx_timeout <= 1'b0;
                if (rxf_n == (fifo_en ? 5'd16 : 5'd1) &&
                    !(io_rd && io_addr == 3'd0 && !dlab)) begin
                    lsr_oe <= 1'b1;
                    if (!fifo_en) rxf[rxf_rd] <= rx_push_d;  // 16450: the new byte overwrites
                end else begin
                    rxf[rxf_wr] <= rx_push_d;
                    rxf_wr <= rxf_wr + 4'd1;
                    if (!(io_rd && io_addr == 3'd0 && !dlab && rx_any)) rxf_n <= rxf_n + 5'd1;
                end
            end
        end
    end

    // received frame -> {break, framing error, parity error, data}
    // f holds the frame without its start bit, right-aligned: data bits,
    // [parity], stop, in bit order
    function [10:0] rx_frame_decode;
        input [9:0] f; input [3:0] l; input [1:0] ps;   // l = LCR[3:0], ps = LCR[5:4]
        reg [3:0] n; reg [9:0] g; reg [7:0] d; reg p, s, pe;
        begin
            n = 4'd5 + l[1:0];
            g = f >> (4'd9 - n - {3'b0, l[3]});        // right-align the n+parity+stop bits
            d = mask_len(g[7:0], l[1:0]);
            p = g[n];
            s = g[n + {3'b0, l[3]}];
            pe = l[3] && (ps[1] ? (p != ~ps[0]) : ((^d ^ p) != ~ps[0]));
            rx_frame_decode = {(d == 8'd0) && !s && (!l[3] || !p), !s, pe, d};
        end
    endfunction
endmodule
