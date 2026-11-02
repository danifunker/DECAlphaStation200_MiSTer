// The 82378's two 8259A interrupt controllers and the edge/level control
// registers (docs/design/sio.md): the master at 20h/21h, the slave at
// A0h/A1h on the master's IRQ2, ELCR at 4D0h/4D1h. Ported to Verilog-2001
// from the user's IBM RS/6000 core (IBMRS6K7248_pic.sv, GPL-2).
//
// ICW1-ICW4 (ICW3's cascade wiring is the AT's, whatever is written; ICW4's
// AEOI), OCW1 (mask), OCW2 (non-specific and specific EOI, rotation, set
// priority, rotate in AEOI), OCW3 (read IRR or ISR, poll, special mask
// mode), edge or level sense per line (ELCR, or ICW1 LTIM for a whole chip),
// and the interrupt acknowledge: the PCI INTA cycle the PALcode makes (the
// 21071's IACK space, pci.md 4) is one whole INTA sequence here: the vector
// of the highest request, the slave's through the cascade; with no request
// IRQ7's or IRQ15's vector (the 8259's spurious interrupt).
//
// Edge mode latches a request from its rising edge until it is acknowledged,
// and, as on the 8259A, only while the line stays high: a line that falls
// before the acknowledge clears its IRR bit (the 8259A's edge sense latch
// feeds the request latch through the IR level; Intel: "the IR input must
// remain high until after the falling edge of the first INTA"). DEC's DROM
// floppy loader relies on it: it polls IRR bit 6 for each FDC command with
// the line masked and never acknowledged (docs/design/floppy.md 5). The
// master's IRQ2 (the slave's INT, which this model's pipeline holds low for two
// clocks after each access to the slave) keeps the latch until the acknowledge.
// The lines are active high here (a PCI PIRQ routed by the 82378 arrives
// inverted, as the level the 8259 sees).
//
// Bus (pci.md 5): io_rd/io_wr are one-cycle strobes already qualified by
// the SIO's decode of this device's ports; io_dout is combinational from the
// state, the side effects of a read (poll) happen on the io_rd clock.
// iack is a strobe too, iack_vec the vector combinationally (from registers).
// The priority resolution is pipelined (isa_pic_chip): INT follows a request by
// three clocks, and the CPU-facing intr is registered once more in the SIO.
module isa_pic (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] io_addr,
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire  [7:0] io_din,
    output wire  [7:0] io_dout,

    input  wire        iack,          // the acknowledge (strobe)
    output wire  [7:0] iack_vec,

    input  wire [15:0] irq,           // request lines (IRQ2's input is the cascade: ignored)
    output wire        intr           // the master's INT, to the CPU
);
    wire elcr  = io_addr[10];                             // 4D0/4D1 (else 20/21, A0/A1)
    wire slave = elcr ? io_addr[0] : io_addr[7];          // 4D1, A0/A1
    wire a0    = io_addr[0];

    wire [7:0] m_dout, s_dout, m_elcr, s_elcr;
    wire [3:0] m_pend, s_pend;
    wire [7:0] m_vec, s_vec;
    wire       s_int;

    // the acknowledge: the master's highest request; through IRQ2 the slave's
    wire m_none = m_pend[3];
    wire via_s  = !m_none && m_pend[2:0] == 3'd2;
    wire ack_m  = iack && !m_none;
    wire ack_s  = iack && via_s && !s_pend[3];
    assign iack_vec = via_s ? s_vec : m_vec;

    isa_pic_chip master (
        .clk(clk), .rst(rst),
        .wr(io_wr && !elcr && !slave), .rd(io_rd && !elcr && !slave), .a0(a0), .din(io_din), .dout(m_dout),
        .elcr_wr(io_wr && elcr && !slave), .elcr_mask(8'hF8), .elcr_q(m_elcr), .hold(8'h04),
        .line({irq[7:3], s_int, irq[1:0]}), .int_o(intr), .pend_o(m_pend),
        .ack(ack_m), .vec(m_vec)
    );
    isa_pic_chip slave_pic (
        .clk(clk), .rst(rst),
        .wr(io_wr && !elcr && slave), .rd(io_rd && !elcr && slave), .a0(a0), .din(io_din), .dout(s_dout),
        .elcr_wr(io_wr && elcr && slave), .elcr_mask(8'hDE), .elcr_q(s_elcr), .hold(8'h00),   // IRQ8 and 13 edge only
        .line(irq[15:8]), .int_o(s_int), .pend_o(s_pend),
        .ack(ack_s), .vec(s_vec)
    );

    assign io_dout = elcr ? (slave ? s_elcr : m_elcr) : (slave ? s_dout : m_dout);
endmodule

// one 8259A
module isa_pic_chip (
    input  wire       clk,
    input  wire       rst,
    input  wire       wr,
    input  wire       rd,
    input  wire       a0,
    input  wire [7:0] din,
    output wire [7:0] dout,
    input  wire       elcr_wr,
    input  wire [7:0] elcr_mask,      // the lines that may be level-sensitive
    output wire [7:0] elcr_q,
    input  wire [7:0] hold,           // edge lines whose latch holds until the acknowledge, whatever the line does
    input  wire [7:0] line,
    output wire       int_o,
    output wire [3:0] pend_o,         // the request to raise INT for; bit 3: none
    input  wire       ack,            // acknowledge pend_o
    output wire [7:0] vec             // {ICW2[7:3], the line acknowledged, 7 if none}
);
    // the highest-priority bit of v, priorities rotated so that line `lowest` is the
    // lowest; bit 3 set: none
    function [3:0] prio;
        input [7:0] v; input [2:0] lowest;
        integer i; reg [2:0] n;
        begin
            prio = 4'h8;
            for (i = 7; i >= 0; i = i - 1) begin
                n = lowest + i[2:0] + 3'd1;
                if (v[n]) prio = {1'b0, n};
            end
        end
    endfunction

    reg [7:0] irr, isr, imr, last, elcr;
    reg [4:0] vbase;
    reg       ltim, need_icw4, single, aeoi, smm, read_isr, poll, rot_aeoi;
    reg [1:0] step;                   // 0 ready; 1 ICW2 next; 2 ICW3 next; 3 ICW4 next
    reg [2:0] lowest;

    // The priority resolution is pipelined (timing at 100 MHz): stage 1 registers the
    // highest unmasked request (hr_q) and the highest in service (hs_q), stage 2 registers
    // the request to raise INT for (pend_q), which drives INT, the acknowledge, the poll
    // and the vector. A request reaches INT three clocks after its line rises. After any
    // write, acknowledge or poll the pipeline holds stale values for two clocks: INT is
    // held low and an acknowledge in that window gets the spurious vector (as an 8259
    // whose request went away), so nothing acts on a stale resolution.
    reg  [3:0] hr_q, hs_q, eoi_q, pend_q;
    reg  [1:0] stale;
    wire [2:0] dr = hr_q[2:0] - lowest - 3'd1;
    wire [2:0] ds = hs_q[2:0] - lowest - 3'd1;
    wire [3:0] pend_d = hr_q[3] ? 4'h8 :
                        smm ? (isr[hr_q[2:0]] ? 4'h8 : hr_q) :
                        (!hs_q[3] && dr >= ds) ? 4'h8 : hr_q;
    wire [3:0] pend = stale != 2'd0 ? 4'h8 : pend_q;
    assign pend_o = pend;
    assign int_o  = !pend[3];
    wire [2:0] ack_n = pend[3] ? 3'd7 : pend[2:0];
    assign vec    = {vbase, ack_n};
    wire [3:0] eoi_n = eoi_q;                          // the highest in service, registered
    wire [7:0] lvl   = elcr | {8{ltim}};
    assign elcr_q = elcr;

    always @(posedge clk) begin
        hr_q   <= prio(irr & ~imr, lowest);
        hs_q   <= prio(smm ? (isr & ~imr) : isr, lowest);
        eoi_q  <= prio(isr, lowest);
        pend_q <= pend_d;
        if (wr || elcr_wr || ack || (rd && poll)) stale <= 2'd2;
        else if (stale != 2'd0) stale <= stale - 2'd1;
        if (rst) begin hr_q <= 4'h8; hs_q <= 4'h8; eoi_q <= 4'h8; pend_q <= 4'h8; stale <= 2'd2; end
    end

    wire icw1  = wr && !a0 && din[4];
    wire ocw3  = wr && !a0 && !din[4] && din[3];
    wire ocw2  = wr && !a0 && !din[4] && !din[3];
    wire odd_w = wr && a0;
    wire poll_r = rd && poll;

    assign dout = poll ? {!pend[3], 4'd0, pend[2:0]} : !a0 ? (read_isr ? isr : irr) : imr;

    always @(posedge clk) begin
        last <= line;
        // requests: a level line follows its input; an edge line latches a rising edge,
        // and drops with the line
        irr <= (lvl & line) | (~lvl & (line | hold) & (irr | (line & ~last)));

        if (icw1) begin
            ltim <= din[3]; single <= din[1]; need_icw4 <= din[0];
            imr <= 8'h00; isr <= 8'h00; irr <= 8'h00; lowest <= 3'd7;
            read_isr <= 1'b0; smm <= 1'b0; aeoi <= 1'b0; step <= 2'd1;
        end
        if (ocw3) begin
            if (din[1]) read_isr <= din[0];
            poll <= din[2];
            if (din[6]) smm <= din[5];
        end
        if (ocw2) begin
            case (din[7:5])
            3'b001: if (!eoi_n[3]) isr[eoi_n[2:0]] <= 1'b0;                 // non-specific EOI
            3'b101: if (!eoi_n[3]) begin isr[eoi_n[2:0]] <= 1'b0; lowest <= eoi_n[2:0]; end
            3'b011: isr[din[2:0]] <= 1'b0;                                  // specific EOI
            3'b111: begin isr[din[2:0]] <= 1'b0; lowest <= din[2:0]; end
            3'b110: lowest <= din[2:0];                                     // set priority
            3'b100: rot_aeoi <= 1'b1;
            3'b000: rot_aeoi <= 1'b0;
            default: ;
            endcase
        end
        if (odd_w) begin
            case (step)
            2'd1: begin
                vbase <= din[7:3];
                step  <= single ? (need_icw4 ? 2'd3 : 2'd0) : 2'd2;
            end
            2'd2: step <= need_icw4 ? 2'd3 : 2'd0;                          // ICW3
            2'd3: begin aeoi <= din[1]; step <= 2'd0; end                   // ICW4
            default: imr <= din;                                            // OCW1
            endcase
        end
        // a poll read is an acknowledge of this chip alone
        if (poll_r) begin
            poll <= 1'b0;
            if (!pend[3]) begin
                isr[pend[2:0]] <= 1'b1;
                if (!lvl[pend[2:0]]) irr[pend[2:0]] <= 1'b0;
            end
        end
        if (ack) begin
            if (!aeoi) isr[ack_n] <= 1'b1;
            else if (rot_aeoi) lowest <= ack_n;
            if (!lvl[ack_n]) irr[ack_n] <= 1'b0;
        end
        if (elcr_wr) elcr <= din & elcr_mask;

        if (rst) begin
            irr <= 8'h00; isr <= 8'h00; imr <= 8'hFF; elcr <= 8'h00; vbase <= 5'd0; last <= 8'h00;
            ltim <= 1'b0; single <= 1'b0; need_icw4 <= 1'b0; aeoi <= 1'b0; smm <= 1'b0;
            read_isr <= 1'b0; poll <= 1'b0; rot_aeoi <= 1'b0; step <= 2'd0; lowest <= 3'd7;
        end
    end
endmodule
