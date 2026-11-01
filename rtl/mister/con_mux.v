// What the on-screen terminal (rtl/mister/vterm.v) shows while there is no
// graphics console: the 21064's SROM serial port (the DROM's console: SL_XMIT
// as an 8N1 line at 19200 baud, the DROM's own timing), COM1's characters,
// and every change of the diagnostic LEDs as "[XX]". One byte out per strobe;
// sources that arrive together are queued.
module con_mux #(
    parameter CLK_HZ = 100000000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       srom_txd,         // the SROM port line (idle 1)
    input  wire       com1_stb,
    input  wire [7:0] com1_byte,
    input  wire [7:0] leds,
    output reg        out_stb,
    output reg  [7:0] out_byte
);
    // ------------------------------------------------------------ SROM port receiver
    localparam integer BIT = CLK_HZ / 19200;
    reg  [2:0] rs;
    always @(posedge clk) rs <= {rs[1:0], srom_txd};
    reg        rx_busy;
    reg [15:0] rx_cnt;
    reg  [3:0] rx_n;
    reg  [7:0] rx_sh;
    reg        rx_stb;
    reg  [7:0] rx_byte;
    always @(posedge clk) begin
        rx_stb <= 1'b0;
        if (rst) rx_busy <= 1'b0;
        else if (!rx_busy) begin
            if (rs[2] && !rs[1]) begin rx_busy <= 1'b1; rx_cnt <= BIT + BIT / 2; rx_n <= 4'd0; end
        end else if (rx_cnt != 16'd0) rx_cnt <= rx_cnt - 16'd1;
        else begin
            rx_cnt <= BIT;
            if (rx_n == 4'd8) begin
                rx_busy <= 1'b0;
                rx_stb  <= rs[2];                 // a stop bit: a character
                rx_byte <= rx_sh;
            end else begin
                rx_sh <= {rs[2], rx_sh[7:1]};
                rx_n  <= rx_n + 4'd1;
            end
        end
    end

    // ------------------------------------------------------------ queue
    reg  [7:0] q [0:31];
    reg  [4:0] wr, rd;
    reg  [7:0] led_q;
    reg  [2:0] led_n;                       // LED message characters left: [ X X ]
    function [7:0] hexc;
        input [3:0] v;
        hexc = v < 4'd10 ? 8'h30 + v : 8'h37 + v;
    endfunction

    always @(posedge clk) begin
        out_stb <= 1'b0;
        if (rst) begin
            wr <= 5'd0; rd <= 5'd0; led_q <= 8'hFF; led_n <= 3'd0;
        end else begin
            // one write per cycle: SROM port, then COM1, then the LED message
            if (rx_stb) begin q[wr] <= rx_byte; wr <= wr + 5'd1; end
            else if (com1_stb) begin q[wr] <= com1_byte; wr <= wr + 5'd1; end
            else if (led_n != 3'd0) begin
                q[wr] <= led_n == 3'd4 ? 8'h5B : led_n == 3'd3 ? hexc(led_q[7:4]) :
                         led_n == 3'd2 ? hexc(led_q[3:0]) : 8'h5D;
                wr <= wr + 5'd1; led_n <= led_n - 3'd1;
            end else if (leds != led_q) begin
                led_q <= leds; led_n <= 3'd4;
            end
            if (rd != wr) begin out_stb <= 1'b1; out_byte <= q[rd]; rd <= rd + 5'd1; end
        end
    end
endmodule
