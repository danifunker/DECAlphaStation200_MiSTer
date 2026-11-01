// The AlphaStation 200 4/100 with its CPU: the 21064 (rtl/cpu/ev4_core.v)
// loading the SROM into its I-cache, the 21071 (rtl/apecs/apecs.v), and on
// the ISA side COM1 (rtl/sio/ns16550.v at 3F8h). DRAM and the flash/DROM
// bytes are ports: the MiSTer top puts them in SDRAM and DDR3, the Verilator
// system simulation (verilator/system) in C++ models.
//
// This replaces rtl/as200.v (the bring-up stub machine) in the MiSTer top
// once the SDRAM and DDR3 adapters exist.
module as200_sys #(
    parameter SROM_HEX = "srom/build/avanti_srom.bitstream.hex"   // relative to the Quartus project
) (
    input  wire        clk,
    input  wire        rst,
    input  wire  [1:0] cfg_mem,         // Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB
    input  wire  [7:0] jumpers,
    output wire  [7:0] leds,

    // DRAM (128 MB)
    output wire        d_req,
    output wire        d_we,
    output wire [26:3] d_addr,
    output wire  [7:0] d_be,
    output wire [63:0] d_wdata,
    input  wire        d_ack,
    input  wire [63:0] d_rdata,

    // flash + DROM bytes (flashbus offset)
    output wire        f_req,
    output wire        f_we,
    output wire [20:0] f_addr,
    output wire  [7:0] f_wdata,
    input  wire        f_ack,
    input  wire  [7:0] f_rdata,

    // the 21064's SROM serial port (the DROM's console)
    output wire        srom_txd,
    input  wire        srom_rxd,

    // COM1
    output wire        com1_txd,
    input  wire        com1_rxd,
    output wire        com1_tx_stb,
    output wire  [7:0] com1_tx_byte,
    input  wire        com1_kbd_stb,
    input  wire  [7:0] com1_kbd_byte,

    // retire trace (simulation)
    output wire        dbg_retire,
    output wire [63:0] dbg_pc,
    output wire [31:0] dbg_insn,
    output wire        dbg_rwr,
    output wire  [4:0] dbg_rnum,
    output wire [63:0] dbg_rval,
    output wire        dbg_mwr,
    output wire [63:0] dbg_maddr,
    output wire [63:0] dbg_mval,
    output wire  [3:0] dbg_msize
);
    // ------------------------------------------------------------ SROM (XC1765D image)
    reg  [7:0] srom [0:8191];
    initial $readmemh(SROM_HEX, srom);
    wire [12:0] srom_addr;
    reg   [7:0] srom_q;
    always @(posedge clk) srom_q <= srom[srom_addr];

    // ------------------------------------------------------------ CPU
    wire        c_req, c_we, c_ist, c_ack;
    wire [33:3] c_addr;
    wire  [7:0] c_be;
    wire [63:0] c_wdata, c_rdata;

    ev4_core cpu (
        .clk(clk), .rst(rst),
        .icmode(1'b0), .srom_addr(srom_addr), .srom_data(srom_q),
        .sl_xmit(srom_txd), .sl_rcv(srom_rxd),
        .mem_req(c_req), .mem_we(c_we), .mem_istream(c_ist), .mem_addr(c_addr),
        .mem_be(c_be), .mem_wdata(c_wdata), .mem_ack(c_ack), .mem_rdata(c_rdata),
        .dbg_retire(dbg_retire), .dbg_pc(dbg_pc), .dbg_insn(dbg_insn), .dbg_rwr(dbg_rwr),
        .dbg_rnum(dbg_rnum), .dbg_rval(dbg_rval), .dbg_mwr(dbg_mwr), .dbg_maddr(dbg_maddr),
        .dbg_mval(dbg_mval), .dbg_msize(dbg_msize)
    );

    // ------------------------------------------------------------ 21071
    wire        pt_req, pt_we;
    wire  [1:0] pt_cmd;
    wire  [4:0] pt_dev;
    wire [31:0] pt_addr, pt_wdata;
    wire  [3:0] pt_be;
    wire        pt_claim, pt_ack;
    wire [31:0] pt_rdata;

    apecs core_logic (
        .clk(clk), .rst(rst), .cfg_mem(cfg_mem), .jumpers(jumpers), .leds(leds),
        .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_be(c_be), .c_wdata(c_wdata),
        .c_ack(c_ack), .c_rdata(c_rdata),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata),
        .d_ack(d_ack), .d_rdata(d_rdata),
        .f_req(f_req), .f_we(f_we), .f_addr(f_addr), .f_wdata(f_wdata),
        .f_ack(f_ack), .f_rdata(f_rdata),
        .pt_req(pt_req), .pt_cmd(pt_cmd), .pt_dev(pt_dev), .pt_addr(pt_addr), .pt_be(pt_be),
        .pt_we(pt_we), .pt_wdata(pt_wdata), .pt_claim(pt_claim), .pt_ack(pt_ack), .pt_rdata(pt_rdata),
        .dm_req(1'b0), .dm_we(1'b0), .dm_addr(32'd0), .dm_be(4'd0), .dm_wdata(32'd0),
        .dm_ack(), .dm_rdata()
    );

    // ------------------------------------------------------------ PCI devices
    // (pci.md 2) claim/ack/rdata of every device ORed; I/O that no device
    // claims is the ISA side's (subtractive)
    wire        other_claim = 1'b0;               // the 53C810, the SIO's own registers: to come
    wire        isa_claim   = pt_req && pt_cmd == 2'd1 && !other_claim;
    assign pt_claim = other_claim || isa_claim;

    // ------------------------------------------------------------ ISA (stand-in until rtl/sio/sio82378.v)
    // 1.8432 MHz for the UARTs, from the system clock (an accumulator)
    localparam [31:0] SYS_HZ = 32'd100000000;
    reg [31:0] baud_acc;
    reg        ce_1m8;
    always @(posedge clk) begin
        if (baud_acc + 32'd1843200 >= SYS_HZ) begin
            baud_acc <= baud_acc + 32'd1843200 - SYS_HZ; ce_1m8 <= 1'b1;
        end else begin
            baud_acc <= baud_acc + 32'd1843200; ce_1m8 <= 1'b0;
        end
    end

    // the ISA byte: the lowest enabled lane
    wire  [1:0] isa_lane = pt_be[0] ? 2'd0 : pt_be[1] ? 2'd1 : pt_be[2] ? 2'd2 : 2'd3;
    wire [15:0] isa_port = {pt_addr[15:2], isa_lane};
    wire  [7:0] isa_wd   = pt_wdata[8*isa_lane +: 8];
    wire        com1_sel = isa_port[15:3] == 13'h007F;          // 3F8-3FF
    reg         isa_busy;
    wire        io_strobe = isa_claim && !isa_busy;
    wire  [7:0] com1_dout;
    reg         isa_ack;
    reg  [31:0] isa_rd;

    ns16550 com1 (
        .clk(clk), .rst(rst), .ce_1m8(ce_1m8),
        .io_addr(isa_port[2:0]), .io_rd(io_strobe && !pt_we && com1_sel), .io_wr(io_strobe && pt_we && com1_sel),
        .io_din(isa_wd), .io_dout(com1_dout), .irq(),
        .txd(com1_txd), .rxd(com1_rxd), .rts_n(), .dtr_n(), .out1_n(), .out2_n(),
        .cts_n(1'b0), .dsr_n(1'b0), .ri_n(1'b1), .dcd_n(1'b0),
        .tx_stb(com1_tx_stb), .tx_byte(com1_tx_byte),
        .rx_inj_stb(com1_kbd_stb), .rx_inj_byte(com1_kbd_byte)
    );

    always @(posedge clk) begin
        isa_ack <= 1'b0;
        if (rst) isa_busy <= 1'b0;
        else if (io_strobe) begin
            isa_rd  <= {4{com1_sel ? com1_dout : 8'hFF}};    // nothing else on ISA yet
            isa_ack <= 1'b1;
            isa_busy <= 1'b1;
        end else if (!pt_req) isa_busy <= 1'b0;
    end
    assign pt_ack   = isa_ack;
    assign pt_rdata = isa_rd;
endmodule
