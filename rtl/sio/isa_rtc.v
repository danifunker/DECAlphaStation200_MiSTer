// The BQ4285 TOY clock (MC146818-compatible) at 70h/71h, docs/design/sio.md.
// Ported to Verilog-2001 from the user's IBM RS/6000 core
// (IBMRS6K7248_rtc.sv, GPL-2), without that machine's 4 KB NVRAM.
//
// The time and calendar, the alarm, registers A-D, the update-in-progress
// flag, the periodic, alarm and update-ended interrupts, and 114 bytes of
// CMOS RAM (0Eh-7Fh). On the AlphaStation the interrupt output does not go
// to the 8259 (ISA IRQ8 is not connected) but straight to CPU IRQ4: the
// interval timer of every Alpha OS (HARDWARE.md 3), and what DROM's
// "Interrupts test" checks through HIRR.
//
// The time is kept in binary and shown as register B asks (BCD or binary,
// 12 or 24 hour); the year is two digits. It is set from the MiSTer's clock
// (hps_io's rtc[64:0]: BCD seconds, minutes, hours, date, month, year,
// weekday 0-6 from Sunday in [55:48], bit 64 toggling with each update) and
// then counts on its own 32,768 Hz time base, made from CLK_HZ by phase
// accumulation. year_ovr replaces the MiSTer's year (OSD option, e.g. 99
// for the Windows 2000 RC1 time-bomb), on each update and at reset.
//
// The index register's bit 7 (NMI enable) belongs to the 82378 and is kept
// there; here port 70h holds the index (read back as written).
//
// Bus (pci.md 5): one-cycle strobes qualified by the SIO's decode,
// io_addr[0] = 0 index, 1 data; io_dout combinational, the side effect of a
// read (register C clears its flags) on the io_rd clock.
module isa_rtc #(
    parameter CLK_HZ = 100000000,
    parameter FAST   = 0              // 1 (benches only): a second every 512 ticks of the 32 kHz
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output wire  [7:0] io_dout,

    output wire        irq,           // IRQF: to CPU IRQ4

    input  wire [64:0] rtc,           // hps_io
    input  wire        year_ovr_en,
    input  wire  [6:0] year_ovr,      // binary 0-99
    input  wire        console_arc    // CMOS 3Fh at reset: 1 = ARC, 0 = SRM (the DROM's flash loader
                                      // reads it; the CMOS is lost on every core load, so the OSD sets it)
);
    // ---------------------------------------------------------------- 32,768 Hz
    localparam [63:0] INC64 = (64'd32768 << 32) / CLK_HZ;
    localparam [31:0] INC   = INC64[31:0];
    reg [31:0] acc;
    reg        t32k;
    always @(posedge clk) {t32k, acc} <= {1'b0, acc} + {1'b0, INC};
    reg [14:0] div;                   // the divider chain: one second at its wrap
    localparam [14:0] SEC_WRAP = FAST != 0 ? 15'h01FF : 15'h7FFF;

    // ---------------------------------------------------------------- registers
    reg [6:0] index;
    reg [5:0] sec, min, sec_a, min_a;   // binary
    reg [4:0] hour, hour_a;             // 0-23
    reg [7:0] sec_a_raw, min_a_raw, hour_a_raw;  // the alarm bytes as written (C0-FF: don't care)
    reg [2:0] dow;                      // 1-7
    reg [4:0] date;
    reg [3:0] month;
    reg [6:0] year;
    reg [6:0] reg_a;                    // DV, RS (UIP is made)
    reg [7:0] reg_b;
    reg [2:0] flags;                    // PF, AF, UF
    reg [7:0] cram [0:127];             // 0E-7F used

    wire bin = reg_b[2];
    wire h24 = reg_b[1];
    wire run = reg_a[6:4] == 3'b010 && !reg_b[7];

    function [7:0] to_bcd;
        input [6:0] v;
        reg [6:0] t, o;
        begin t = v / 7'd10; o = v - t * 7'd10; to_bcd = {t[3:0], o[3:0]}; end   // (tens up to 9: the year)
    endfunction
    function [6:0] from_bcd;
        input [7:0] v;
        begin from_bcd = {3'd0, v[7:4]} * 7'd10 + {3'd0, v[3:0]}; end
    endfunction
    function [7:0] show;                // a value as register B shows it
        input [6:0] v; input b;
        begin show = b ? {1'b0, v} : to_bcd(v); end
    endfunction
    function [7:0] show_hour;
        input [4:0] h; input b; input t24;
        reg [4:0] h12; reg [7:0] v;
        begin
            if (t24) show_hour = show({2'd0, h}, b);
            else begin
                h12 = (h == 5'd0) ? 5'd12 : (h > 5'd12) ? h - 5'd12 : h;
                v = show({2'd0, h12}, b);
                show_hour = {h >= 5'd12, v[6:0]};
            end
        end
    endfunction
    function [6:0] take;
        input [7:0] v; input b;
        begin take = b ? v[6:0] : from_bcd(v); end
    endfunction
    function [4:0] take_hour;
        input [7:0] v; input b; input t24;
        reg [6:0] h, h2;
        begin
            h = take({1'b0, v[6:0]}, b);
            if (t24) take_hour = h[4:0];
            else begin
                h2 = (h == 7'd12 ? 7'd0 : h) + (v[7] ? 7'd12 : 7'd0);
                take_hour = h2[4:0];
            end
        end
    endfunction

    // days in the month (two-digit years: every fourth is a leap year)
    wire [4:0] mdays = month == 4'd2 ? (year[1:0] == 2'd0 ? 5'd29 : 5'd28) :
                       (month == 4'd4 || month == 4'd6 || month == 4'd9 || month == 4'd11) ? 5'd30 : 5'd31;

    // the update cycle: UIP for the last 244 us (8 ticks) before each second
    wire uip = run && div >= SEC_WRAP - 15'd7;

    // the periodic interrupt: rate select 3-15 every 2^(RS-1) ticks (8,192 Hz down to
    // 2 Hz); 1 and 2 are 256 and 128 Hz (every 128 and 256 ticks)
    reg [14:0] pmask;
    always @* begin
        case (reg_a[3:0])
        4'd1:    pmask = 15'h007F;
        4'd2:    pmask = 15'h00FF;
        default: pmask = (15'd1 << (reg_a[3:0] - 4'd1)) - 15'd1;
        endcase
    end

    wire alarm_hit = (sec_a_raw[7:6] == 2'b11 || sec_a == sec) &&
                     (min_a_raw[7:6] == 2'b11 || min_a == min) &&
                     (hour_a_raw[7:6] == 2'b11 || hour_a == hour);

    // the MiSTer's time: each change of rtc[64]
    reg [2:0] tog;
    always @(posedge clk) tog <= {tog[1:0], rtc[64]};
    wire set_time = tog[2] != tog[1];

    assign irq = |(flags & reg_b[6:4]);

    // the time registers as register B shows them, registered every cycle
    // (the BCD conversion was a 1.5 ns timing failure into the SIO's read
    // data; ISA accesses are at least 3 clocks apart, so a one-cycle-old view
    // is never seen)
    reg [7:0] v_sec, v_min, v_hour, v_date, v_mon, v_year;
    always @(posedge clk) begin
        v_sec  <= show({1'b0, sec}, bin);
        v_min  <= show({1'b0, min}, bin);
        v_hour <= show_hour(hour, bin, h24);
        v_date <= show({2'd0, date}, bin);
        v_mon  <= show({3'd0, month}, bin);
        v_year <= show(year, bin);
    end

    reg [7:0] rd71;
    always @* begin
        case (index)
        7'h00: rd71 = v_sec;
        7'h01: rd71 = sec_a_raw;
        7'h02: rd71 = v_min;
        7'h03: rd71 = min_a_raw;
        7'h04: rd71 = v_hour;
        7'h05: rd71 = hour_a_raw;
        7'h06: rd71 = {5'd0, dow};
        7'h07: rd71 = v_date;
        7'h08: rd71 = v_mon;
        7'h09: rd71 = v_year;
        7'h0A: rd71 = {uip, reg_a};
        7'h0B: rd71 = reg_b;
        7'h0C: rd71 = {irq, flags[2], flags[1], flags[0], 4'd0};
        7'h0D: rd71 = 8'h80;                                    // VRT: the battery is good
        default: rd71 = cram[index];
        endcase
    end
    assign io_dout = io_addr[0] ? rd71 : {1'b0, index};

    wire data_w = io_wr && io_addr[0];
    wire [6:0] tk  = take(io_din, bin);              // a byte written, as register B reads it
    wire [6:0] b_sec = from_bcd(rtc[7:0]),   b_min = from_bcd(rtc[15:8]),  b_hour = from_bcd(rtc[23:16]);
    wire [6:0] b_date = from_bcd(rtc[31:24]), b_mon = from_bcd(rtc[39:32]), b_year = from_bcd(rtc[47:40]);
    always @(posedge clk) begin
        if (rst) cram[7'h3F] <= {7'd0, console_arc};
        else if (data_w && index >= 7'h0E) cram[index] <= io_din;
    end

    always @(posedge clk) begin
        if (t32k && reg_a[6:4] == 3'b010) begin
            div <= div == SEC_WRAP ? 15'd0 : div + 15'd1;
            if (reg_a[3:0] != 4'd0 && (div & pmask) == pmask)
                flags[2] <= 1'b1;                                   // periodic
            if (!reg_b[7] && div == SEC_WRAP) begin
                // the second: the time, then the alarm and the update-ended flag
                flags[0] <= 1'b1;
                if (sec != 6'd59) sec <= sec + 6'd1;
                else begin
                    sec <= 6'd0;
                    if (min != 6'd59) min <= min + 6'd1;
                    else begin
                        min <= 6'd0;
                        if (hour != 5'd23) hour <= hour + 5'd1;
                        else begin
                            hour <= 5'd0;
                            dow  <= dow == 3'd7 ? 3'd1 : dow + 3'd1;
                            if (date != mdays) date <= date + 5'd1;
                            else begin
                                date <= 5'd1;
                                if (month != 4'd12) month <= month + 4'd1;
                                else begin month <= 4'd1; year <= year == 7'd99 ? 7'd0 : year + 7'd1; end
                            end
                        end
                    end
                end
            end
        end
        // the alarm, checked after the second has moved
        if (t32k && run && div == 15'd0 && alarm_hit) flags[1] <= 1'b1;

        if (io_wr && !io_addr[0]) index <= io_din[6:0];
        if (data_w) begin
            case (index)
            7'h00: sec   <= tk[5:0];
            7'h01: begin sec_a <= tk[5:0]; sec_a_raw <= io_din; end
            7'h02: min   <= tk[5:0];
            7'h03: begin min_a <= tk[5:0]; min_a_raw <= io_din; end
            7'h04: hour  <= take_hour(io_din, bin, h24);
            7'h05: begin hour_a <= take_hour(io_din, bin, h24); hour_a_raw <= io_din; end
            7'h06: dow   <= io_din[2:0];
            7'h07: date  <= tk[4:0];
            7'h08: month <= tk[3:0];
            7'h09: year  <= tk;
            7'h0A: begin
                reg_a <= io_din[6:0];
                if (io_din[6:4] != 3'b010) div <= 15'd0;            // the divider held in reset
            end
            7'h0B: reg_b <= io_din[7] ? {io_din[7:5], 1'b0, io_din[3:0]} : io_din;   // SET clears UIE
            default: ;                                              // C, D read only; the CMOS above
            endcase
        end
        if (io_rd && io_addr[0] && index == 7'h0C) flags <= 3'd0;

        if (set_time) begin
            sec   <= b_sec[5:0];
            min   <= b_min[5:0];
            hour  <= b_hour[4:0];
            date  <= b_date[4:0];
            month <= b_mon[3:0];
            year  <= year_ovr_en ? year_ovr : b_year;
            dow   <= rtc[50:48] + 3'd1;                         // the MiSTer's 0-6 from Sunday; the chip's 1-7
        end

        if (rst) begin
            // what a power-on reset of the chip clears (the time and the CMOS are battery-backed)
            reg_b[6:4] <= 3'b000;
            flags      <= 3'd0;
            index      <= 7'd0;
            if (year_ovr_en) year <= year_ovr;
        end
    end

    // a sensible clock before the first update from the MiSTer (benches, or no RTC)
    integer i;
    initial begin
        for (i = 0; i < 128; i = i + 1) cram[i] = 8'h00;
        sec = 6'd0; min = 6'd0; hour = 5'd12; date = 5'd1; month = 4'd1; year = 7'd26; dow = 3'd5;
        reg_a = 7'b010_0110; reg_b = 8'b0000_0010; div = 15'd0; flags = 3'd0; index = 7'd0;
        sec_a_raw = 8'd0; min_a_raw = 8'd0; hour_a_raw = 8'd0; sec_a = 6'd0; min_a = 6'd0; hour_a = 5'd0;
        acc = 32'd0; tog = 3'd0;
    end
endmodule
