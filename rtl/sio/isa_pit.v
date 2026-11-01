// The 82378's 8254 interval timer and port 61h (NMI status and control),
// docs/design/sio.md. Ported to Verilog-2001 from the user's IBM RS/6000
// core (IBMRS6K7248_pit.sv, GPL-2).
//
// Three counters at 40h-42h, the control word at 43h, clocked at
// 1,193,182 Hz (14.31818 MHz / 12) made from CLK_HZ by phase accumulation.
// Counter 0 is ISA IRQ0, counter 1 the refresh request (port 61 bit 4
// toggles with it), counter 2 the speaker (gated by port 61 bit 0, its
// output read at bit 5 and sent out ANDed with bit 1).
//
// Every mode: 0 (interrupt on terminal count), 1 (retriggerable one-shot),
// 2 (rate generator), 3 (square wave), 4 and 5 (strobes); binary counting
// (BCD counting is taken as binary); LSB, MSB and LSB-then-MSB access; the
// counter latch command and the read-back command (count and status).
// Counters 0 and 1 have their gates tied high, as on the AT. Mode 3 counts
// down by two through 0, then reloads (DROM V1.7's CPU-speed calibration
// times counter 0 in mode 3, MSB only, count FF00h: ten half periods, from
// its MSB reading 0 to the next time it does).
//
// Port 61h (82378 NMISC): bits 3:0 written (3 IOCHK# NMI disable, 2 PCI
// SERR# NMI disable, 1 speaker data, 0 counter 2 gate); read
// {SERR# status, IOCHK# status, OUT2, refresh toggle, bits 3:0}.
//
// Bus (pci.md 5): one-cycle io_rd/io_wr strobes qualified by the SIO's
// decode, io_dout combinational, read side effects on the io_rd clock.
module isa_pit #(
    parameter CLK_HZ = 100000000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] io_addr,       // 40-43, 61
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output wire  [7:0] io_dout,

    input  wire        serr_st,       // NMI sources (port 61 bits 7, 6)
    input  wire        iochk_st,
    output wire  [3:0] p61,           // port 61 bits 3:0 as written

    output wire        irq0,          // counter 0's output
    output wire        spk            // counter 2's output AND port 61 bit 1
);
    localparam [63:0] INC64 = (64'd1193182 << 32) / CLK_HZ;
    localparam [31:0] INC   = INC64[31:0];
    reg [31:0] acc;
    reg        tick;
    always @(posedge clk) begin
        {tick, acc} <= {1'b0, acc} + {1'b0, INC};
        if (rst) begin acc <= 32'd0; tick <= 1'b0; end
    end

    wire is61 = io_addr[5];                          // 61h (40-43h have bit 5 clear)
    wire [1:0] a = io_addr[1:0];
    reg  [3:0] p61_r;
    reg        refresh;

    wire [7:0] q0, q1, q2;
    wire       out0, out1, out2;
    wire [15:0] cnt1;
    wire ctl_w = io_wr && !is61 && a == 2'd3;
    isa_pit_ctr #(.C(0)) c0 (.clk(clk), .rst(rst), .tick(tick), .gate(1'b1),
        .ctl_w(ctl_w), .dat_w(io_wr && !is61 && a == 2'd0), .dat_r(io_rd && !is61 && a == 2'd0),
        .din(io_din), .dout(q0), .out(out0), .cnt_o());
    isa_pit_ctr #(.C(1)) c1 (.clk(clk), .rst(rst), .tick(tick), .gate(1'b1),
        .ctl_w(ctl_w), .dat_w(io_wr && !is61 && a == 2'd1), .dat_r(io_rd && !is61 && a == 2'd1),
        .din(io_din), .dout(q1), .out(out1), .cnt_o(cnt1));
    isa_pit_ctr #(.C(2)) c2 (.clk(clk), .rst(rst), .tick(tick), .gate(p61_r[0]),
        .ctl_w(ctl_w), .dat_w(io_wr && !is61 && a == 2'd2), .dat_r(io_rd && !is61 && a == 2'd2),
        .din(io_din), .dout(q2), .out(out2), .cnt_o());

    always @(posedge clk) begin
        if (tick && out1 && cnt1 == 16'd1) refresh <= ~refresh;
        if (io_wr && is61) p61_r <= io_din[3:0];
        if (rst) begin p61_r <= 4'h0; refresh <= 1'b0; end
    end

    assign io_dout = is61 ? {serr_st, iochk_st, out2, refresh, p61_r} :
                     a == 2'd0 ? q0 : a == 2'd1 ? q1 : a == 2'd2 ? q2 : 8'hFF;
    assign p61  = p61_r;
    assign irq0 = out0;
    assign spk  = out2 & p61_r[1];
endmodule

// one 8254 counter
module isa_pit_ctr #(
    parameter C = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,
    input  wire        gate,
    input  wire        ctl_w,         // a write of the control word (43h): this counter's or a read-back
    input  wire        dat_w,
    input  wire        dat_r,
    input  wire  [7:0] din,
    output wire  [7:0] dout,
    output wire        out,
    output wire [15:0] cnt_o
);
    reg [15:0] cnt, reload, latch;
    reg  [5:0] ctl;                    // {rw[1:0], mode[2:0], bcd}
    reg        out_r, latched, st_latched, rd_hi, wr_hi, armed, load, gate_prev, running;
    reg  [7:0] status;

    wire [2:0] mode = ctl[3:1] == 3'd6 ? 3'd2 : ctl[3:1] == 3'd7 ? 3'd3 : ctl[3:1];
    wire       sel_w  = ctl_w && din[7:6] == C;
    wire       rb_w   = ctl_w && din[7:6] == 2'd3 && din[1 + C];
    wire       g_rise = gate && !gate_prev;
    wire [15:0] rl_even = {reload[15:1], 1'b0};

    wire [15:0] rv = latched ? latch : cnt;
    assign dout = st_latched ? status :
                  ctl[5:4] == 2'b01 ? rv[7:0] :
                  ctl[5:4] == 2'b10 ? rv[15:8] :
                  rd_hi ? rv[15:8] : rv[7:0];
    assign out   = out_r;
    assign cnt_o = cnt;

    always @(posedge clk) begin
        if (tick) gate_prev <= gate;

        // the control word
        if (sel_w) begin
            if (din[5:4] == 2'b00) begin                    // counter latch
                if (!latched) begin latch <= cnt; latched <= 1'b1; end
            end else begin
                ctl <= din[5:0];
                wr_hi <= 1'b0; rd_hi <= 1'b0; latched <= 1'b0; armed <= 1'b0; running <= 1'b0;
                out_r <= din[3:1] != 3'd0;                  // mode 0 starts low, the others high
            end
        end
        if (rb_w) begin
            if (!din[5] && !latched) begin latch <= cnt; latched <= 1'b1; end
            if (!din[4] && !st_latched) begin
                status <= {out_r, !armed || load, ctl};
                st_latched <= 1'b1;
            end
        end

        // the count
        if (dat_w) begin
            case (ctl[5:4])
            2'b01: begin reload <= {8'd0, din}; load <= 1'b1; armed <= 1'b1; end
            2'b10: begin reload <= {din, 8'd0}; load <= 1'b1; armed <= 1'b1; end
            default: begin
                if (!wr_hi) begin
                    reload[7:0] <= din; wr_hi <= 1'b1;
                    if (mode == 3'd0) running <= 1'b0;      // mode 0 stops on the LSB
                end else begin
                    reload[15:8] <= din; wr_hi <= 1'b0; load <= 1'b1; armed <= 1'b1;
                end
            end
            endcase
            if (mode == 3'd0) out_r <= 1'b0;
        end

        // reads
        if (dat_r) begin
            if (st_latched) st_latched <= 1'b0;
            else case (ctl[5:4])
            2'b01, 2'b10: latched <= 1'b0;
            default: begin
                if (rd_hi) latched <= 1'b0;
                rd_hi <= ~rd_hi;
            end
            endcase
        end

        // counting, at 1.19 MHz
        if (tick) begin
            if (load && ((mode != 3'd1 && mode != 3'd5) || g_rise)) begin
                // a new count: modes 0, 2, 3, 4 take it at once (2 and 3 at the end of the
                // current period on the real chip); 1 and 5 on the gate's rise
                cnt <= mode == 3'd3 ? rl_even : reload;
                load <= 1'b0; running <= 1'b1;
                if (mode == 3'd1) out_r <= 1'b0;
            end else if (running) begin
                case (mode)
                3'd0, 3'd4: if (gate) begin
                    cnt <= cnt - 16'd1;
                    if (cnt == 16'd1) out_r <= mode == 3'd0;  // 0: rises and stays; 4: a strobe
                    else if (mode == 3'd4) out_r <= 1'b1;
                end
                3'd1, 3'd5: begin
                    if (g_rise) begin cnt <= reload; out_r <= mode == 3'd5; end
                    else begin
                        cnt <= cnt - 16'd1;
                        if (cnt == 16'd1) out_r <= mode == 3'd1;
                        else if (mode == 3'd5) out_r <= 1'b1;
                    end
                end
                3'd2: if (gate) begin
                    if (cnt == 16'd2) begin cnt <= cnt - 16'd1; out_r <= 1'b0; end
                    else if (cnt == 16'd1) begin cnt <= reload; out_r <= 1'b1; end
                    else cnt <= cnt - 16'd1;
                end else out_r <= 1'b1;
                3'd3: if (gate) begin
                    // by two, through 0; the output toggles when the count runs out and the
                    // even count (an odd one taken as the even one below) is reloaded
                    if (cnt[15:1] == 15'd0) begin cnt <= rl_even - 16'd2; out_r <= ~out_r; end
                    else cnt <= cnt - 16'd2;
                end else out_r <= 1'b1;
                default: ;
                endcase
            end
        end

        if (rst) begin
            ctl <= 6'b110110; out_r <= 1'b1; latched <= 1'b0; st_latched <= 1'b0;
            rd_hi <= 1'b0; wr_hi <= 1'b0; armed <= 1'b0; load <= 1'b0; running <= 1'b0;
            cnt <= 16'd0; reload <= 16'd0; latch <= 16'd0; status <= 8'd0; gate_prev <= 1'b0;
        end
    end
endmodule
