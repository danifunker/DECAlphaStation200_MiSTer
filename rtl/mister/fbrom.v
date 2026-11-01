// The flashbus ROMs behind the 21071 model's byte port (rtl/apecs/apecs.v
// f_*): the DROM (64 KB, flashbus 18.0000-18.FFFF) in block RAM and the four
// flash chips (1 MB, 00.0000-0F.FFFF) in DDR3, at the core's window
// 0x3000_0000 (DDRAM_ADDR counts 64-bit words: 0x0600_0000). Both are loaded
// by the MiSTer ROM download (hps_io ioctl): index 0 = boot0.rom, the flash
// image; index 0x40 = boot1.rom, the DROM.
//
// Flash reads keep the last DDR3 quadword (the DROM copies the console from
// flash a byte at a time, in order). Flash writes are byte writes into DDR3
// (the 28F020 command set is a STUB: no ID, erase or program sequences yet).
module fbrom (
    input  wire        clk,
    input  wire        rst,

    // the 21071's flashbus byte port
    input  wire        f_req,
    input  wire        f_we,
    input  wire [20:0] f_addr,
    input  wire  [7:0] f_wdata,
    output reg         f_ack,
    output reg   [7:0] f_rdata,

    // ROM download (hps_io ioctl, in this clock)
    input  wire        dl_wr,
    input  wire  [7:0] dl_index,
    input  wire [24:0] dl_addr,
    input  wire  [7:0] dl_data,
    output reg         dl_wait,

    // DDR3 (sys DDRAM_*)
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
    localparam [28:0] BASE = 29'h0600_0000;     // byte 0x3000_0000

    // ------------------------------------------------------------ DROM (BRAM)
    reg  [7:0] drom [0:65535];
    reg  [7:0] drom_q;
    reg [15:0] drom_a;
    reg        drom_we;
    reg  [7:0] drom_wd;
    always @(posedge clk) begin
        drom_q <= drom[drom_a];
        if (drom_we) drom[drom_a] <= drom_wd;
    end

    // ------------------------------------------------------------ DDR3
    reg [16:0] cq_addr;                 // cached quadword: flash byte offset >> 3
    reg        cq_v;
    reg [63:0] cq;

    // the download assembles flash quadwords
    reg [63:0] dl_q;
    reg  [7:0] dl_be;
    reg [16:0] dl_qa;
    reg        dl_pend;

    localparam S_IDLE = 3'd0, S_DROM1 = 3'd1, S_DROM2 = 3'd2, S_RD = 3'd3, S_RDW = 3'd4, S_WR = 3'd5;
    reg [2:0] st;

    wire drom_sel = f_addr[20:16] == 5'h18;     // 18.0000-18.FFFF

    always @(posedge clk) begin
        f_ack   <= 1'b0;
        drom_we <= 1'b0;
        if (!DDRAM_BUSY) begin DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; end
        if (rst) begin
            st <= S_IDLE; cq_v <= 1'b0; dl_pend <= 1'b0; dl_wait <= 1'b0;
            DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; DDRAM_BURSTCNT <= 8'd1;
        end else begin
            // ---------------------------------------- download
            if (dl_wr) begin
                if (dl_index == 8'h40) begin
                    drom_a <= dl_addr[15:0]; drom_wd <= dl_data; drom_we <= 1'b1;
                end else if (dl_index == 8'h00) begin
                    dl_q[8*dl_addr[2:0] +: 8] <= dl_data;
                    dl_be[dl_addr[2:0]] <= 1'b1;
                    dl_qa <= dl_addr[19:3];
                    if (dl_addr[2:0] == 3'd7) begin dl_pend <= 1'b1; dl_wait <= 1'b1; end
                    cq_v <= 1'b0;
                end
            end
            case (st)
            S_IDLE: begin
                if (dl_pend && !DDRAM_BUSY) begin
                    DDRAM_ADDR <= BASE + {12'd0, dl_qa}; DDRAM_DIN <= dl_q; DDRAM_BE <= dl_be;
                    DDRAM_BURSTCNT <= 8'd1; DDRAM_WE <= 1'b1;
                    dl_pend <= 1'b0; dl_wait <= 1'b0; dl_be <= 8'd0;
                end else if (f_req && !f_ack) begin
                    if (drom_sel) begin
                        drom_a <= f_addr[15:0]; drom_wd <= f_wdata; drom_we <= 1'b0;   // the DROM is read-only
                        st <= S_DROM1;
                    end else if (f_we) begin
                        st <= S_WR;
                    end else if (cq_v && cq_addr == f_addr[19:3]) begin
                        f_rdata <= cq[8*f_addr[2:0] +: 8]; f_ack <= 1'b1;
                    end else if (!DDRAM_BUSY) begin
                        DDRAM_ADDR <= BASE + {12'd0, f_addr[19:3]}; DDRAM_BURSTCNT <= 8'd1; DDRAM_RD <= 1'b1;
                        st <= S_RDW;
                    end
                end
            end
            S_DROM1: st <= S_DROM2;
            S_DROM2: begin f_rdata <= drom_q; f_ack <= 1'b1; st <= S_IDLE; end
            S_RDW: if (DDRAM_DOUT_READY) begin
                cq <= DDRAM_DOUT; cq_addr <= f_addr[19:3]; cq_v <= 1'b1;
                f_rdata <= DDRAM_DOUT[8*f_addr[2:0] +: 8]; f_ack <= 1'b1;
                st <= S_IDLE;
            end
            S_WR: if (!DDRAM_BUSY) begin
                DDRAM_ADDR <= BASE + {12'd0, f_addr[19:3]}; DDRAM_BURSTCNT <= 8'd1;
                DDRAM_DIN <= {8{f_wdata}}; DDRAM_BE <= 8'd1 << f_addr[2:0]; DDRAM_WE <= 1'b1;
                if (cq_v && cq_addr == f_addr[19:3]) cq[8*f_addr[2:0] +: 8] <= f_wdata;
                f_ack <= 1'b1; st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
