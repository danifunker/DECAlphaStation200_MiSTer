// The four flashROMs' command interface (Intel 28F020, 256 KB each, flashbus
// 00.0000-0F.FFFF; TI 4-3) between the 21071 model's flashbus byte port (u_*)
// and the flash storage behind it (f_*: fbrom's DDR3 on the board, the bench's
// array in simulation). The other flashbus devices pass straight through.
//
// The 28F020 has no data writes: a write is a command. 00h/FFh read the array,
// 90h the identifier (byte 0 = 89h Intel, byte 1 = BDh 28F020), 40h/10h set up a
// program (the next write programs that byte), 20h then 20h erase the whole
// chip to FFh, A0h (erase verify) and C0h (program verify) read the array.
// Programming stores the byte (the chip ANDs it into an erased byte; firmware
// only programs erased bytes or zeros). The erase runs here as 256K byte writes
// of FFh to the storage; the port waits for it. With wp (J6 flash write
// disabled: no Vpp) the chips ignore every write and only read their array.
//
// The handshake on both sides: req held until a one-cycle ack.
module flash28f020 (
    input  wire        clk,
    input  wire        rst,
    input  wire        wp,

    input  wire        u_req,
    input  wire        u_we,
    input  wire [20:0] u_addr,
    input  wire  [7:0] u_wdata,
    output wire        u_ack,
    output wire  [7:0] u_rdata,

    output wire        f_req,
    output wire        f_we,
    output wire [20:0] f_addr,
    output wire  [7:0] f_wdata,
    input  wire        f_ack,
    input  wire  [7:0] f_rdata
);
    localparam [1:0] M_READ = 2'd0, M_ID = 2'd1, M_PROG = 2'd2, M_ERASE = 2'd3;
    reg  [1:0] mode;
    reg        erasing;
    reg  [1:0] e_chip;
    reg [17:0] e_cnt;
    reg        l_ack;
    reg  [7:0] l_rdata;

    wire flash = !u_addr[20];                   // 00.0000-0F.FFFF
    // forwarded: other devices, array reads, the byte of a program
    wire fwd = !flash || (!u_we && mode != M_ID) || (u_we && mode == M_PROG && !wp);

    assign f_req   = erasing ? 1'b1 : (u_req && fwd && !l_ack);
    assign f_we    = erasing ? 1'b1 : u_we;
    assign f_addr  = erasing ? {1'b0, e_chip, e_cnt} : u_addr;
    assign f_wdata = erasing ? 8'hFF : u_wdata;
    assign u_ack   = l_ack || (!erasing && fwd && f_ack);
    assign u_rdata = l_ack ? l_rdata : f_rdata;

    always @(posedge clk) begin
        l_ack <= 1'b0;
        if (rst) begin
            mode <= M_READ; erasing <= 1'b0;
        end else if (erasing) begin
            if (f_ack) begin
                e_cnt <= e_cnt + 18'd1;
                if (&e_cnt) erasing <= 1'b0;
            end
        end else if (u_req && !l_ack && !u_ack) begin
            if (flash && !u_we && mode == M_ID) begin
                l_rdata <= u_addr[0] ? 8'hBD : 8'h89; l_ack <= 1'b1;
            end else if (flash && u_we && !(mode == M_PROG && !wp)) begin
                l_ack <= 1'b1;
                if (!wp) begin
                    if (mode == M_ERASE && u_wdata == 8'h20) begin
                        erasing <= 1'b1; e_chip <= u_addr[19:18]; e_cnt <= 18'd0; mode <= M_READ;
                    end else case (u_wdata)
                        8'h90:        mode <= M_ID;
                        8'h40, 8'h10: mode <= M_PROG;
                        8'h20:        mode <= M_ERASE;
                        default:      mode <= M_READ;     // 00, FF, A0, C0 and the rest
                    endcase
                end
            end
        end
        // the programmed byte has gone to the storage
        if (!rst && !erasing && fwd && f_ack && u_we && mode == M_PROG) mode <= M_READ;
    end
endmodule
