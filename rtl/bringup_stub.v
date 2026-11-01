// Bring-up stand-in for the CPU: drives COM1's register bus the way the
// console firmware would, so the serial path (16550 -> MiSTer UART and the
// on-screen terminal, MiSTer keyboard / UART -> 16550) can be checked on the
// board and in Verilator before the 21064 exists. It programs 9600 8N1 with
// the FIFOs on, prints a banner and then echoes every received character
// (CR also sends LF). Removed when the CPU drives the bus.
module bringup_stub (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] mem_sel,      // cfg Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB

    output reg  [2:0] io_addr,
    output reg        io_rd,
    output reg        io_wr,
    output reg  [7:0] io_dout,
    input  wire [7:0] io_din
);
    localparam [8*74-1:0] BANNER = {
        "\r\nDEC AlphaStation 200 4/100 - MiSTer core, bring-up build\r\n",
        "Memory: # MB\r\n"
    };
    localparam BLEN = 74;
    localparam [8*49-1:0] BANNER2 = "CPU not implemented yet. COM1 echo: type here.\r\n>";
    localparam B2LEN = 49;

    localparam S_INIT = 3'd0, S_BANNER = 3'd1, S_POLL = 3'd2, S_READ = 3'd3,
               S_WAIT = 3'd4, S_PUT = 3'd5;

    reg  [2:0] st;
    reg  [3:0] init_i;
    reg  [6:0] bi;
    reg  [1:0] digit;               // memory size digits being sent
    reg  [7:0] pend;                // character waiting to be sent
    reg  [2:0] after;               // state after the character is out
    reg        lf_next;
    reg  [7:0] rdat;                // read data, captured on the io_rd clock
                                    // (an RBR read pops the FIFO on that clock)
    always @(posedge clk) if (io_rd) rdat <= io_din;

    // memory size as up to three digits
    wire [23:0] memtxt = mem_sel == 2'd1 ? {"32", 8'h00} :
                         mem_sel == 2'd2 ? "128" : {"64", 8'h00};

    function [7:0] banner_at;
        input [6:0] i;
        if (i < BLEN) banner_at = BANNER[8*(BLEN-1-i) +: 8];
        else          banner_at = BANNER2[8*(B2LEN-1-(i-BLEN)) +: 8];
    endfunction

    always @(posedge clk) begin
        io_rd <= 1'b0;
        io_wr <= 1'b0;
        if (rst) begin
            st <= S_INIT; init_i <= 4'd0; bi <= 7'd0; digit <= 2'd0; lf_next <= 1'b0;
        end else if (!io_rd && !io_wr) begin
            case (st)
            S_INIT: begin
                io_wr <= 1'b1;
                case (init_i)
                4'd0: begin io_addr <= 3'd3; io_dout <= 8'h83; end   // DLAB
                4'd1: begin io_addr <= 3'd0; io_dout <= 8'd12; end   // 9600
                4'd2: begin io_addr <= 3'd1; io_dout <= 8'd0;  end
                4'd3: begin io_addr <= 3'd3; io_dout <= 8'h03; end   // 8N1
                4'd4: begin io_addr <= 3'd2; io_dout <= 8'h07; end   // FIFOs on, cleared
                default: begin io_addr <= 3'd4; io_dout <= 8'h03; end // DTR, RTS
                endcase
                init_i <= init_i + 4'd1;
                if (init_i == 4'd5) st <= S_BANNER;
            end
            S_BANNER: begin
                if (bi == BLEN + B2LEN) st <= S_POLL;
                else if (banner_at(bi) == "#") begin
                    if (digit == 2'd3 || memtxt[8*(2-digit) +: 8] == 8'h00) begin
                        bi <= bi + 7'd1; digit <= 2'd0;
                    end else begin
                        pend <= memtxt[8*(2-digit) +: 8]; digit <= digit + 2'd1;
                        after <= S_BANNER; st <= S_WAIT;
                    end
                end else begin
                    pend <= banner_at(bi); bi <= bi + 7'd1;
                    after <= S_BANNER; st <= S_WAIT;
                end
            end
            S_POLL: begin                                    // LSR.DR?
                io_rd <= 1'b1; io_addr <= 3'd5; st <= S_READ;
            end
            S_READ: begin
                if (rdat[0]) begin
                    io_rd <= 1'b1; io_addr <= 3'd0;              // RBR
                    st <= S_PUT;
                end else st <= S_POLL;
            end
            S_PUT: begin
                pend    <= rdat;
                lf_next <= rdat == 8'h0D;
                after   <= S_POLL;
                st      <= S_WAIT;
            end
            S_WAIT: begin                                    // wait for THRE, then send
                io_rd <= 1'b1; io_addr <= 3'd5; st <= 3'd6;
            end
            default: begin
                if (rdat[5]) begin
                    io_wr <= 1'b1; io_addr <= 3'd0; io_dout <= pend;
                    if (lf_next && after == S_POLL) begin
                        pend <= 8'h0A; lf_next <= 1'b0; st <= S_WAIT;
                    end else st <= after;
                end else st <= S_WAIT;
            end
            endcase
        end
    end
endmodule
