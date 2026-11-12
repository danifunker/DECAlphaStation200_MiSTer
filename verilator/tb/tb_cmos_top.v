// tb_cmos's top: rtl/sio/isa_rtc.v (the TOY and its CMOS) and rtl/mister/nvsave.v (the NVRAM
// image file) wired as in DECAlphaStation200.sv, with an 8 KB NVRAM whose port B reads one clock
// late like the 21071 model's (rtl/apecs/apecs.v). The C++ side plays hps_io's slot 4 (mount, block
// reads and writes) and the guest's port 70h/71h accesses (verilator/tb/tb_cmos.cpp).
module tb_cmos_top (
    input  wire        clk,
    input  wire        rst,
    input  wire  [1:0] console_mode,
    input  wire  [1:0] srm_con_mode,

    // the guest's TOY ports
    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output wire  [7:0] io_dout,

    // hps_io slot 4
    input  wire        img_mounted,
    input  wire [63:0] img_size,
    output wire [31:0] sd_lba,
    output wire  [5:0] sd_blk_cnt,
    output wire        sd_rd,
    output wire        sd_wr,
    input  wire        sd_ack,
    input  wire [13:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din,
    input  wire        sd_buff_wr,

    // the guest's NVRAM writes (the flashbus side, simplified)
    input  wire        nv_cpu_we,
    input  wire [12:0] nv_cpu_addr,
    input  wire  [7:0] nv_cpu_wdata,
    output wire        loaded
);
    wire [12:0] nvb_addr;
    wire        nvb_we;
    wire  [7:0] nvb_wdata;
    reg   [7:0] nvb_rdata;
    reg         nv_dirty;
    reg   [7:0] nvram [0:8191];
    always @(posedge clk) begin
        nvb_rdata <= nvram[nvb_addr];
        if (nvb_we) nvram[nvb_addr] <= nvb_wdata;
        else if (nv_cpu_we) nvram[nv_cpu_addr] <= nv_cpu_wdata;
        nv_dirty <= nv_cpu_we;
    end

    wire [6:0] cm_addr;
    wire       cm_we, cm_dirty;
    wire [7:0] cm_wdata, cm_rdata;

    isa_rtc #(.CLK_HZ(1000000), .FAST(1)) toy (
        .clk(clk), .rst(rst),
        .io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_din(io_din), .io_dout(io_dout),
        .irq(),
        .rtc(65'd0), .year_ovr_en(1'b0), .year_ovr(7'd0), .console_mode(console_mode), .srm_con_mode(srm_con_mode),
        .cm_addr(cm_addr), .cm_we(cm_we), .cm_wdata(cm_wdata), .cm_rdata(cm_rdata), .cm_dirty(cm_dirty)
    );

    // CLK_HZ 1000: the save's 5 s quiet time is 5,000 clocks here
    nvsave #(.CLK_HZ(1000)) nvs (
        .clk(clk), .rst(rst),
        .img_mounted(img_mounted), .img_size(img_size),
        .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
        .nvb_addr(nvb_addr), .nvb_we(nvb_we), .nvb_wdata(nvb_wdata), .nvb_rdata(nvb_rdata), .nv_dirty(nv_dirty),
        .cm_addr(cm_addr), .cm_we(cm_we), .cm_wdata(cm_wdata), .cm_rdata(cm_rdata), .cm_dirty(cm_dirty),
        .loaded(loaded)
    );

    integer i;
    initial for (i = 0; i < 8192; i = i + 1) nvram[i] = 8'h00;
endmodule
