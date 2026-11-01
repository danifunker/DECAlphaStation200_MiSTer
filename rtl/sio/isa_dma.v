// The ISA DMA controller of the 82378: two 8237s with the SIO's extensions
// (docs/design/sio.md). Ported to Verilog-2001 from the user's IBM RS/6000
// core (IBMRS6K7248_dma.sv, GPL-2), its memory port changed to the
// AlphaStation's little-endian 32-bit PCI master port (pci.md 3).
//
// DMA1 at 00h-0Fh (channels 0-3, 8-bit), DMA2 at C0h-DFh (channels 4-7, even
// ports; 4 the cascade, 5-7 16-bit): each channel's base and current
// address and count (low byte then high, through the byte pointer flip-
// flop), the command, request, single and all mask, mode and status
// registers, clear byte pointer, master clear, clear mask. The page
// registers at 80h-8Fh (87 0, 83 1, 81 2, 82 3, 8B 5, 89 6, 8A 7; the rest
// scratch), the 82378's high pages at 481h-48Bh (the PCI address's bits
// 31:24), its extended mode registers 40Bh / 4D6h (kept), and its
// scatter/gather: for each channel a command at 410h + n (bits 1:0: 01
// start, 10 stop), a status at 418h + n (bit 3 active, bit 2 ended at a
// list's end), a descriptor table pointer at 420h + 4n, 40Ah / 4D4h the
// channels whose list ended (read: cleared). A started channel takes its
// address and count from the table's 8-byte entries (the PCI address; bits
// 23:0 the count less 1, bit 31 the list's last), the next entry when one
// runs out; at the last one's end it masks itself and raises IRQ 13 (sg_irq).
//
// A transfer: a channel unmasked, its DREQ high, not in cascade mode, is
// served (the lowest number first): one byte (channels 0-3) or one word
// (5-7, at {page[7:1], address, 0}) between memory, over the PCI master port,
// and the device, which sees dack with the channel (a read transfer:
// dack_data the byte or word memory gave; a write transfer: it gives
// dev_data) and tc on the last. Then the address steps, the count steps
// down; past 0, TC: the status bit, and the channel reloads (auto-initialise)
// or masks itself. The address carries into the page past a 64 KB boundary
// (the 82378's behaviour, unlike an AT's 8237). Single, demand and block
// modes alike: one transfer each time the request is seen. Verify transfers
// count with no memory access.
//
// Bus (pci.md 5): one-cycle strobes qualified by the SIO's decode, the
// whole port in io_addr; io_dout combinational, the side effects of a read
// (byte pointer, status's TC bits, the S/G interrupt status) on the io_rd clock.
module isa_dma (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output reg   [7:0] io_dout,

    // the devices
    input  wire  [7:0] dreq,
    output reg         dack,           // a pulse: the channel's transfer is done
    output reg   [2:0] dack_ch,
    output reg  [15:0] dack_data,      // a read transfer's byte (7:0) or word, from memory
    input  wire [15:0] dev_data,       // a write transfer's, from the device (dev_ch's)
    output wire  [2:0] dev_ch,         // the channel being served
    output reg         tc,             // with dack: the count ran out
    output wire        sg_irq,         // a scatter/gather list ended (IRQ 13)

    // PCI master (pci.md 3)
    output reg         dm_req,
    output reg         dm_we,
    output reg  [31:0] dm_addr,
    output reg   [3:0] dm_be,
    output reg  [31:0] dm_wdata,
    input  wire        dm_ack,
    input  wire [31:0] dm_rdata
);
    wire [15:0] port = io_addr;

    // ---------------------------------------------------------------- registers
    reg [15:0] base_a [0:7];
    reg [15:0] cur_a  [0:7];
    reg [15:0] base_c [0:7];
    reg [15:0] cur_c  [0:7];
    reg  [7:0] page   [0:7];
    reg  [7:0] hpage  [0:7];
    reg  [7:0] cur_pg [0:7];            // the page a transfer is at (the page register, carried into)
    reg  [5:0] mode   [0:7];            // the mode register's bits 7:2
    reg  [7:0] mask;                    // 1: masked
    reg  [7:0] req_sw;                  // software requests
    reg  [7:0] tc_st;                   // the status's TC bits (read clears)
    reg  [7:0] cmd1, cmd2;
    reg        ff1, ff2;                // the byte pointers
    reg  [7:0] ext1, ext2;              // the extended mode registers (40B, 4D6)
    reg  [7:0] rb [0:63];               // 410-43F and the scratch bytes of 80-8F, read back
    reg  [7:0] temp;                    // the last byte read from memory (the temporary register)
    // scatter/gather: each channel's list running, its entry, loading, ended, interrupting
    reg  [7:0] sg_on, sg_load, sg_end, sg_int, sg_last;
    reg [31:0] sg_a   [0:7];
    reg [23:0] sg_c   [0:7];
    reg [31:0] sg_ptr [0:7];
    assign sg_irq = |sg_int;

    // the engine's (below)
    reg  [2:0] ch;
    assign dev_ch = ch;
    reg        go_step, go_tc, sg_go_step, sg_go_next, sg_go_end, sg_loaded;
    reg [31:0] sg_new_a, sg_new_c;

    // the page register port of a channel (80-8F), and back
    function [3:0] port_ch;            // bit 3: a channel's
        input [3:0] p;
        case (p)
        4'h7: port_ch = 4'b1000;  4'h3: port_ch = 4'b1001;  4'h1: port_ch = 4'b1010;  4'h2: port_ch = 4'b1011;
        4'hF: port_ch = 4'b1100;  4'hB: port_ch = 4'b1101;  4'h9: port_ch = 4'b1110;  4'hA: port_ch = 4'b1111;
        default: port_ch = 4'b0000;
        endcase
    endfunction

    // the decode
    wire        d1   = port[15:4] == 12'h000;                       // 00-0F
    wire        d2   = port[15:5] == 11'h006 && !port[0];           // C0-DF, even
    wire        pg   = port[15:4] == 12'h008;                       // 80-8F
    wire        hpg  = port[15:4] == 12'h048;                       // 480-48F
    wire        sg_p = port >= 16'h0410 && port <= 16'h043F;
    wire  [3:0] pch  = port_ch(port[3:0]);
    wire        rb_p = (sg_p && port[5:3] != 3'b011) || (pg && !pch[3]);   // bytes only read back
    wire [15:0] sg_off = port - 16'h0410;
    wire  [5:0] rb_a = sg_p ? sg_off[5:0] : {2'b11, port[3:0]};
    // a register access: the controller (0 or 1) and its register number (0-15)
    wire        ctl  = d2;
    wire  [3:0] rn   = d2 ? port[4:1] : port[3:0];
    wire  [2:0] rch  = {ctl, rn[2:1]};                              // a channel's address or count
    wire        ff   = ctl ? ff2 : ff1;
    wire  [2:0] sgch = port[2:0];
    wire  [2:0] sgpc = port[4:2];

    // reads (combinational)
    always @* begin
        io_dout = 8'h00;
        if (d1 || d2) begin
            if (rn < 4'd8) begin
                if (!rn[0]) io_dout = ff ? cur_a[rch][15:8] : cur_a[rch][7:0];
                else        io_dout = ff ? cur_c[rch][15:8] : cur_c[rch][7:0];
            end else case (rn)
                4'h8: io_dout = ctl ? {dreq[7:4] | req_sw[7:4], tc_st[7:4]} : {dreq[3:0] | req_sw[3:0], tc_st[3:0]};
                4'hD: io_dout = temp;
                4'hF: io_dout = {4'hF, ctl ? mask[7:4] : mask[3:0]};
                default: io_dout = 8'h00;
            endcase
        end
        else if (rb_p) io_dout = rb[rb_a];
        else if (pg)   io_dout = page[pch[2:0]];
        else if (hpg)  io_dout = pch[3] ? hpage[pch[2:0]] : 8'h00;
        else if (port == 16'h040B) io_dout = ext1;
        else if (port == 16'h04D6) io_dout = ext2;
        else if (sg_p) io_dout = {4'h0, sg_on[sgch], sg_end[sgch], 2'b00};     // 418-41F: status
        else if (port == 16'h040A) io_dout = {4'h0, sg_int[3:0]};
        else if (port == 16'h04D4) io_dout = {sg_int[7:4], 4'h0};
    end

    integer i;
    always @(posedge clk) begin
        if (io_wr && rb_p) rb[rb_a] <= io_din;
    end

    always @(posedge clk) begin
        if (io_wr) begin
            if (d1 || d2) begin
                if (rn < 4'd8) begin
                    // a channel's address (even) or count (odd), low byte then high; base and current
                    if (!rn[0]) begin
                        if (!ff) begin base_a[rch][7:0]  <= io_din; cur_a[rch][7:0]  <= io_din; end
                        else     begin base_a[rch][15:8] <= io_din; cur_a[rch][15:8] <= io_din; end
                        cur_pg[rch] <= page[rch];
                    end else begin
                        if (!ff) begin base_c[rch][7:0]  <= io_din; cur_c[rch][7:0]  <= io_din; end
                        else     begin base_c[rch][15:8] <= io_din; cur_c[rch][15:8] <= io_din; end
                    end
                    if (ctl) ff2 <= ~ff2; else ff1 <= ~ff1;
                end else case (rn)
                    4'h8: if (ctl) cmd2 <= io_din; else cmd1 <= io_din;
                    4'h9: req_sw[{ctl, io_din[1:0]}] <= io_din[2];
                    4'hA: mask[{ctl, io_din[1:0]}] <= io_din[2];
                    4'hB: mode[{ctl, io_din[1:0]}] <= io_din[7:2];
                    4'hC: if (ctl) ff2 <= 1'b0; else ff1 <= 1'b0;
                    4'hD: begin                                    // master clear
                        if (ctl) begin cmd2 <= 8'h0; ff2 <= 1'b0; mask[7:4] <= 4'hF; tc_st[7:4] <= 4'h0; req_sw[7:4] <= 4'h0; end
                        else     begin cmd1 <= 8'h0; ff1 <= 1'b0; mask[3:0] <= 4'hF; tc_st[3:0] <= 4'h0; req_sw[3:0] <= 4'h0; end
                    end
                    4'hE: if (ctl) mask[7:4] <= 4'h0; else mask[3:0] <= 4'h0;
                    4'hF: if (ctl) mask[7:4] <= io_din[3:0]; else mask[3:0] <= io_din[3:0];
                    default: ;
                endcase
            end
            else if (pg) begin
                if (pch[3]) begin page[pch[2:0]] <= io_din; cur_pg[pch[2:0]] <= io_din; end
            end
            else if (hpg) begin
                if (pch[3]) hpage[pch[2:0]] <= io_din;
            end
            else if (port == 16'h040B) ext1 <= io_din;
            else if (port == 16'h04D6) ext2 <= io_din;
            else if (sg_p) begin
                if (port[5:3] == 3'b010) begin             // 410-417: a channel's command
                    if (io_din[1:0] == 2'b01) begin sg_load[sgch] <= 1'b1; sg_on[sgch] <= 1'b1; sg_end[sgch] <= 1'b0; end
                    if (io_din[1:0] == 2'b10) begin sg_on[sgch] <= 1'b0; sg_load[sgch] <= 1'b0; end
                    sg_int[sgch] <= 1'b0;
                end
                if (port[5]) case (port[1:0])                // 420-43F: the pointers
                    2'd0: sg_ptr[sgpc][7:0]   <= io_din;
                    2'd1: sg_ptr[sgpc][15:8]  <= io_din;
                    2'd2: sg_ptr[sgpc][23:16] <= io_din;
                    default: sg_ptr[sgpc][31:24] <= io_din;
                endcase
            end
        end
        if (io_rd) begin
            if ((d1 || d2) && rn < 4'd8) begin if (ctl) ff2 <= ~ff2; else ff1 <= ~ff1; end
            if ((d1 || d2) && rn == 4'h8) begin if (ctl) tc_st[7:4] <= 4'h0; else tc_st[3:0] <= 4'h0; end
            if (port == 16'h040A) sg_int[3:0] <= 4'h0;
            if (port == 16'h04D4) sg_int[7:4] <= 4'h0;
        end

        // ---- the transfers ----
        if (sg_loaded) begin                               // an entry in
            sg_load[ch] <= 1'b0;
            sg_a[ch]    <= sg_new_a;
            sg_c[ch]    <= sg_new_c[23:0];
            sg_last[ch] <= sg_new_c[31];
            sg_ptr[ch]  <= sg_ptr[ch] + 32'd8;
        end
        if (sg_go_step) begin
            sg_a[ch] <= mode[ch][3] ? sg_a[ch] - (ch[2] ? 32'd2 : 32'd1) : sg_a[ch] + (ch[2] ? 32'd2 : 32'd1);
            sg_c[ch] <= sg_c[ch] - (ch[2] ? 24'd2 : 24'd1);
        end
        if (sg_go_next) sg_load[ch] <= 1'b1;
        if (sg_go_end) begin                               // the list's end: masked, IRQ 13
            sg_on[ch]  <= 1'b0;
            sg_end[ch] <= 1'b1;
            sg_int[ch] <= 1'b1;
            mask[ch]   <= 1'b1;
            tc_st[ch]  <= 1'b1;
        end
        if (go_tc) begin
            tc_st[ch] <= 1'b1;
            if (mode[ch][2]) begin cur_a[ch] <= base_a[ch]; cur_c[ch] <= base_c[ch]; cur_pg[ch] <= page[ch]; end   // auto-initialise
            else mask[ch] <= 1'b1;
            req_sw[ch] <= 1'b0;
        end else if (go_step) begin
            cur_a[ch] <= mode[ch][3] ? cur_a[ch] - 16'd1 : cur_a[ch] + 16'd1;
            cur_c[ch] <= cur_c[ch] - 16'd1;
            // past a 64 KB boundary (128 KB on 5-7: the page's bits 7:1) the page steps too
            if (!mode[ch][3] && cur_a[ch] == 16'hFFFF) cur_pg[ch] <= cur_pg[ch] + (ch[2] ? 8'd2 : 8'd1);
            if ( mode[ch][3] && cur_a[ch] == 16'h0000) cur_pg[ch] <= cur_pg[ch] - (ch[2] ? 8'd2 : 8'd1);
        end

        if (rst) begin
            mask <= 8'hFF; req_sw <= 8'h0; tc_st <= 8'h0; cmd1 <= 8'h0; cmd2 <= 8'h0; ff1 <= 1'b0; ff2 <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin hpage[i] <= 8'h0; page[i] <= 8'h0; cur_pg[i] <= 8'h0; mode[i] <= 6'h0; end
            ext1 <= 8'h0; ext2 <= 8'h0;
            sg_on <= 8'h0; sg_load <= 8'h0; sg_end <= 8'h0; sg_int <= 8'h0; sg_last <= 8'h0;
        end
    end

    // ---------------------------------------------------------------- the engine
    // a channel wanting service: requested (DREQ or software), unmasked, not cascade (and
    // not 4), its controller enabled (command bit 2 clear), no S/G entry being fetched
    reg [7:0] want;
    always @* begin
        for (i = 0; i < 8; i = i + 1)
            want[i] = (dreq[i] | req_sw[i]) && !mask[i] && mode[i][5:4] != 2'b11 && i != 4 &&
                      !(i < 4 ? cmd1[2] : cmd2[2]) && !sg_load[i];
    end
    reg [2:0] want_ch, load_ch;
    always @* begin
        want_ch = 3'd0; load_ch = 3'd0;
        for (i = 7; i >= 0; i = i - 1) begin
            if (want[i]) want_ch = i[2:0];
            if (sg_load[i]) load_ch = i[2:0];
        end
    end

    localparam T_IDLE = 3'd0, T_RD = 3'd1, T_WR = 3'd2, T_DONE = 3'd3, T_GAP = 3'd4,
               T_SG = 3'd5, T_SG_W = 3'd6, T_SG2_W = 3'd7;
    reg  [2:0] ts;
    wire [31:0] ta = sg_on[ch] ? sg_a[ch] :
                     ch[2] ? {hpage[ch], cur_pg[ch][7:1], cur_a[ch], 1'b0} : {hpage[ch], cur_pg[ch], cur_a[ch]};
    wire  [1:0] ttype = mode[ch][1:0];                  // 00 verify, 01 write (to memory), 10 read (from memory)

    always @(posedge clk) begin
        dack <= 1'b0; tc <= 1'b0;
        go_step <= 1'b0; go_tc <= 1'b0;
        sg_go_step <= 1'b0; sg_go_next <= 1'b0; sg_go_end <= 1'b0; sg_loaded <= 1'b0;
        case (ts)
        T_IDLE: begin
            if (|sg_load) begin ch <= load_ch; ts <= T_SG; end          // a list's next entry first
            else if (|want) begin ch <= want_ch; ts <= T_RD; end
        end
        T_SG: begin dm_we <= 1'b0; dm_be <= 4'hF; dm_addr <= {sg_ptr[ch][31:2], 2'b00}; dm_req <= 1'b1; ts <= T_SG_W; end
        T_SG_W: if (dm_ack) begin                           // the entry's address
            sg_new_a <= dm_rdata;
            dm_addr  <= dm_addr + 32'd4;                    // dm_req stays: the count next
            ts       <= T_SG2_W;
        end
        T_SG2_W: if (dm_ack) begin                          // its count and last flag
            dm_req    <= 1'b0;
            sg_new_c  <= dm_rdata;
            sg_loaded <= 1'b1;
            ts        <= T_GAP;
        end
        T_RD: begin
            dm_addr <= {ta[31:2], 2'b00};
            if (ttype == 2'b10) begin                       // a read transfer: memory's byte or word
                dm_we <= 1'b0; dm_be <= 4'hF; dm_req <= 1'b1; ts <= T_WR;
            end else if (ttype == 2'b01) begin              // a write transfer: the device's into memory
                dm_we    <= 1'b1;
                dm_be    <= ch[2] ? (4'b0011 << {ta[1], 1'b0}) : (4'b0001 << ta[1:0]);
                dm_wdata <= ch[2] ? {2{dev_data}} : {4{dev_data[7:0]}};
                dm_req   <= 1'b1;
                ts       <= T_WR;
            end else ts <= T_DONE;                          // verify: no memory
        end
        T_WR: if (dm_ack) begin
            dm_req    <= 1'b0;
            temp      <= dm_rdata[8*ta[1:0] +: 8];
            dack_data <= ch[2] ? dm_rdata[16*ta[1] +: 16] : {8'h00, dm_rdata[8*ta[1:0] +: 8]};
            ts        <= T_DONE;
        end
        T_DONE: begin
            dack    <= 1'b1;
            dack_ch <= ch;
            if (sg_on[ch]) begin
                // a list's entry: its count is the bytes less 1
                if (sg_c[ch] < (ch[2] ? 24'd2 : 24'd1)) begin
                    if (sg_last[ch]) begin tc <= 1'b1; sg_go_end <= 1'b1; end
                    else sg_go_next <= 1'b1;
                end else sg_go_step <= 1'b1;
            end else begin
                tc <= cur_c[ch] == 16'd0;
                if (cur_c[ch] == 16'd0) go_tc <= 1'b1; else go_step <= 1'b1;
            end
            ts <= T_GAP;
        end
        default: ts <= T_IDLE;                              // T_GAP: the device drops DREQ if it is done
        endcase
        if (rst) begin ts <= T_IDLE; dm_req <= 1'b0; dm_we <= 1'b0; ch <= 3'd0; end
    end

    initial begin
        for (i = 0; i < 64; i = i + 1) rb[i] = 8'h00;
    end
endmodule
