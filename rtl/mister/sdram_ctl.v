// The MiSTer SDRAM module as the AlphaStation's main memory (CORE_SPEC: 32,
// 64 or 128 MB), on the 21071 model's DRAM port (rtl/apecs/apecs.v d_*): one
// 64-bit quadword per read request (four for a line read), little-endian (the
// byte at the lowest address in bits 7:0). A write is a 32-byte line with 32
// byte enables (the CPU's write buffer merges the stores to a line; rtl/cpu/
// ev4_core.v): only the quadwords with an enabled byte are written, in one
// opening of the row, and the request is acknowledged as soon as it is latched
// (the next request waits for the chip).
//
// The chip side follows the user's IBMRS6K7248_sdram.sv (from Sorgelig's
// MiSTer sdram.sv, hardware-tested at 99 MHz with CAS latency 2): the
// power-up sequence (121 us of NOPs, then PRECHARGE ALL, two AUTO REFRESH and
// LOAD MODE per rank, 8 clocks apart), the mode word (burst of 8 for reads,
// single-location writes, sequential, CAS 2), refresh of both ranks every
// 7.8 us, ACTIVE -> READ/WRITE after 2 clocks, PRECHARGE -> ACTIVE after 3,
// the first read beat in the input register 4 clocks after READ, DQM also
// on A12/A11 (the MiSTer boards wire DQMH/DQML there), the data bus from a
// register with an output enable, SDRAM_CLK = the clock inverted from a DDR
// output register (in the top). One row is opened and closed per request.
//
// Byte offset -> chip (as there): rank off[26], column bit 9 off[25], bank
// off[24:23], row off[22:10], columns 8-0 off[9:1]. A quadword is four
// halfwords at columns off[9:3]*4 .. +3: one READ (the burst of 8, sequential
// from an aligned 4, gives them first) or four single WRITEs per quadword.
// Halfword k of the quadword is bits 16k+15:16k; on the chip DQ[7:0] is the
// lower address.
module sdram_ctl #(
    parameter CLK_MHZ = 100
) (
    input  wire        clk,
    input  wire        init,            // run the power-up sequence (again)
    output reg         ready,

    input  wire        req,             // held until ack
    input  wire        we,
    input  wire        line,            // a 32-byte line read: 4 quadwords from addr (line aligned), one ack each
    input  wire [26:3] addr,            // a write: the line (addr[4:3] is not used)
    input  wire [31:0] be,              // a write: byte enables of the line
    input  wire [255:0] wdata,
    output reg         ack,
    output reg  [63:0] rdata,

    output reg  [12:0] SDRAM_A,
    output reg   [1:0] SDRAM_BA,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_DQML,
    output wire        SDRAM_DQMH,
    output wire        SDRAM_CKE,
    output reg  [15:0] dq_out,
    output reg         dq_oe,
    input  wire [15:0] dq_in
);
    localparam [2:0] CMD_NOP = 3'b111, CMD_ACTIVE = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
                     CMD_PRECHARGE = 3'b010, CMD_REFRESH = 3'b001, CMD_MODE = 3'b000;
    // burst of 8 (011), sequential, CAS latency 2, single-location writes
    localparam [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'd2, 1'b0, 3'b011};
    localparam STARTUP = CLK_MHZ * 121;
    localparam REFRESH = CLK_MHZ * 78 / 10;
    localparam T_RCD = 2, T_RP = 3, T_WR = 2, T_RFC = 8, CAP = 4;

    reg  [2:0] command;
    reg        chip;
    reg  [1:0] dqm;
    assign SDRAM_nCS  = chip;
    assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = command;
    assign SDRAM_CKE  = 1'b1;
    assign {SDRAM_DQMH, SDRAM_DQML} = dqm;

    reg [15:0] dq_q;
    always @(posedge clk) dq_q <= dq_in;

    localparam S_INIT = 3'd0, S_IDLE = 3'd1, S_REF = 3'd2, S_ACT = 3'd3, S_READ = 3'd4,
               S_WRITE = 3'd5, S_PRE = 3'd6;
    reg  [2:0] state;
    reg [15:0] t;
    reg        ref_due;
    reg [15:0] ref_cnt;
    reg        acked;
    wire       cpu_req = req && !acked && !ack;

    reg        r_we, r_line;
    reg [26:3] r_a;
    reg [31:0] r_be;
    reg [255:0] r_wd;
    reg  [3:0] r_qv;                    // quadwords of the line still to write
    wire [1:0] wq = r_qv[0] ? 2'd0 : r_qv[1] ? 2'd1 : r_qv[2] ? 2'd2 : 2'd3;
    reg  [2:0] issued;
    reg  [3:0] beat;                    // halfwords captured (16 for a line)

    always @(posedge clk) begin
        if (state == S_IDLE && ref_due) ref_due <= 1'b0;
        if (ref_cnt == REFRESH - 1) begin ref_cnt <= 16'd0; ref_due <= 1'b1; end
        else ref_cnt <= ref_cnt + 16'd1;
        if (init) begin ref_cnt <= 16'd0; ref_due <= 1'b0; end
    end

    always @(posedge clk) begin
        command <= CMD_NOP;
        dq_oe   <= 1'b0;
        ack     <= 1'b0;
        t       <= t + 16'd1;
        if (!req) acked <= 1'b0;
        case (state)
        S_INIT: begin
            SDRAM_A <= 13'd0; SDRAM_BA <= 2'b00; dqm <= 2'b11;
            if (t >= STARTUP) begin
                case (t - STARTUP)
                16'd0:  begin chip <= 1'b0; command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1; end
                16'd8:  command <= CMD_REFRESH;
                16'd16: command <= CMD_REFRESH;
                16'd24: begin command <= CMD_MODE; SDRAM_A <= MODE; end
                16'd32: begin chip <= 1'b1; command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1; end
                16'd40: command <= CMD_REFRESH;
                16'd48: command <= CMD_REFRESH;
                16'd56: begin command <= CMD_MODE; SDRAM_A <= MODE; end
                16'd64: begin state <= S_IDLE; ready <= 1'b1; end
                default: ;
                endcase
            end
        end
        S_IDLE: begin
            t <= 16'd0;
            dqm <= 2'b00;
            if (ref_due) begin
                chip <= 1'b0; command <= CMD_REFRESH; state <= S_REF;
            end else if (cpu_req) begin
                r_we <= we; r_line <= line && !we; r_a <= addr; r_be <= be; r_wd <= wdata;
                r_qv <= {|be[31:24], |be[23:16], |be[15:8], |be[7:0]};
                if (we) begin ack <= 1'b1; acked <= 1'b1; end   // latched: the requester goes on
                chip <= addr[26]; SDRAM_BA <= addr[24:23]; SDRAM_A <= addr[22:10];
                command <= CMD_ACTIVE;
                state <= S_ACT;
            end
        end
        S_REF: begin
            if (t == 16'd0) begin chip <= 1'b1; command <= CMD_REFRESH; end
            if (t == T_RFC) state <= S_IDLE;
        end
        S_ACT: begin
            beat <= 4'd0; issued <= 3'd0;
            if (t == T_RCD - 2) state <= r_we ? S_WRITE : S_READ;
        end
        // a quadword: one READ, the first 4 beats of its burst. A line: two
        // READs 8 clocks apart from the 16-halfword-aligned column (16 beats
        // without a gap), an ack after every 4th beat
        S_READ: begin
            if (issued == 3'd0) begin
                command <= CMD_READ;
                SDRAM_A <= r_line ? {3'b000, r_a[25], r_a[9:5], 4'b0000} : {3'b000, r_a[25], r_a[9:3], 2'b00};
                issued <= 3'd1;
                t <= 16'd1;
            end else if (r_line && issued == 3'd1 && t == 16'd8) begin
                command <= CMD_READ;
                SDRAM_A <= {3'b000, r_a[25], r_a[9:5], 4'b1000};
                issued <= 3'd2;
            end
            if (t >= CAP && (r_line ? 1'b1 : !beat[2]) && !(r_line && beat == 4'd15 && ack)) begin
                rdata[16*beat[1:0] +: 16] <= dq_q;
                beat <= beat + 4'd1;
                if (beat[1:0] == 2'd3) begin
                    ack <= 1'b1;
                    if (!r_line || beat == 4'd15) acked <= 1'b1;
                end
            end
            if (t == CAP + (r_line ? 16 : 8)) begin   // the burst(s) have left the bus
                command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b0;
                t <= 16'd0; state <= S_PRE;
            end
        end
        S_WRITE: begin
            if (r_qv != 4'd0) begin : wr
                reg [1:0] m;
                m = ~r_be[{wq, issued[1:0], 1'b0} +: 2];  // {DQMH, DQML}: bytes not enabled
                command <= CMD_WRITE;
                dq_oe   <= 1'b1;
                SDRAM_A <= {m, 1'b0, r_a[25], r_a[9:5], wq, issued[1:0]};
                dqm     <= m;
                dq_out  <= r_wd[{wq, issued[1:0], 4'd0} +: 16];
                issued  <= {1'b0, issued[1:0] + 2'd1};
                if (issued[1:0] == 2'd3) r_qv[wq] <= 1'b0;
                t       <= 16'd0;
            end else if (t == T_WR) begin
                command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b0; dqm <= 2'b00;
                t <= 16'd0; state <= S_PRE;
            end
        end
        S_PRE: if (t == T_RP - 2) state <= S_IDLE;
        default: state <= S_IDLE;
        endcase
        if (init) begin
            state <= S_INIT; t <= 16'd0; ready <= 1'b0; chip <= 1'b0;
            acked <= 1'b0; ack <= 1'b0; dqm <= 2'b11;
        end
    end
endmodule
