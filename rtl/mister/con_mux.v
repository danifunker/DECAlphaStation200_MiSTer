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
    // the CPU state line (OSD): every second "PC xxxxxxxxxxxxxxxx P? I?? R????????"
    input  wire        st_en,
    input  wire        st_retire,
    input  wire [63:0] st_pc,
    input  wire        st_pal,
    input  wire  [5:0] st_irq,
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

    // the state line: snapshot once a second, then 40 characters
    reg [31:0] st_tick, st_ret;
    reg [63:0] s_pc;
    reg        s_pal;
    reg  [5:0] s_irq;
    reg [31:0] s_ret;
    reg  [5:0] st_i;                         // characters left (40 .. 1), 0 idle
    always @(posedge clk) begin
        if (st_retire) st_ret <= st_ret + 32'd1;
        if (rst || !st_en) st_tick <= 32'd0;
        else if (st_tick == CLK_HZ - 1) st_tick <= 32'd0;
        else st_tick <= st_tick + 32'd1;
    end
    reg  [7:0] st_c;
    always @* begin : stc
        reg [5:0] k;
        k = 6'd40 - st_i;                    // 0 .. 39
        st_c = 8'h20;
        if (k == 6'd0) st_c = 8'h0D; else if (k == 6'd1) st_c = 8'h0A;
        else if (k == 6'd2) st_c = 8'h50; else if (k == 6'd3) st_c = 8'h43;
        else if (k >= 6'd5 && k <= 6'd20) st_c = hexc(s_pc[4 * (20 - k) +: 4]);
        else if (k == 6'd22) st_c = 8'h50; else if (k == 6'd23) st_c = s_pal ? 8'h31 : 8'h30;
        else if (k == 6'd25) st_c = 8'h49; else if (k == 6'd26) st_c = hexc({2'b00, s_irq[5:4]});
        else if (k == 6'd27) st_c = hexc(s_irq[3:0]);
        else if (k == 6'd29) st_c = 8'h52;
        else if (k >= 6'd30 && k <= 6'd37) st_c = hexc(s_ret[4 * (37 - k) +: 4]);
        else if (k == 6'd38) st_c = 8'h0D; else if (k == 6'd39) st_c = 8'h0A;
    end

    always @(posedge clk) begin
        out_stb <= 1'b0;
        if (rst) begin
            wr <= 5'd0; rd <= 5'd0; led_q <= 8'hFF; led_n <= 3'd0; st_i <= 6'd0;
        end else begin
            if (st_en && st_tick == CLK_HZ - 1 && st_i == 6'd0) begin
                s_pc <= st_pc; s_pal <= st_pal; s_irq <= st_irq; s_ret <= st_ret; st_i <= 6'd40;
            end
            // one write per cycle: SROM port, then COM1, then the LED message
            if (rx_stb) begin q[wr] <= rx_byte; wr <= wr + 5'd1; end
            else if (com1_stb) begin q[wr] <= com1_byte; wr <= wr + 5'd1; end
            else if (led_n != 3'd0) begin
                q[wr] <= led_n == 3'd4 ? 8'h5B : led_n == 3'd3 ? hexc(led_q[7:4]) :
                         led_n == 3'd2 ? hexc(led_q[3:0]) : 8'h5D;
                wr <= wr + 5'd1; led_n <= led_n - 3'd1;
            end else if (leds != led_q) begin
                led_q <= leds; led_n <= 3'd4;
            end else if (st_i != 6'd0 && wr + 5'd2 != rd) begin
                q[wr] <= st_c; wr <= wr + 5'd1; st_i <= st_i - 6'd1;
            end
            if (rd != wr) begin out_stb <= 1'b1; out_byte <= q[rd]; rd <= rd + 5'd1; end
        end
    end
endmodule
