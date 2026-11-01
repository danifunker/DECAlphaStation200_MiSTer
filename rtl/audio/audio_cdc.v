// The mix's samples into the MiSTer's audio clock (CLK_AUDIO, 24.576 MHz):
// in_l/in_r are held for a whole 48 kHz period in the system clock and
// in_tgl toggles with each new pair, so the toggle is synchronised (three
// flops) and the pair taken when it changes, by then long stable.
// For sys/: AUDIO_S = 1 (signed), AUDIO_L/AUDIO_R = out_l/out_r.
module audio_cdc (
    input  wire        clk_audio,
    input  wire [15:0] in_l,
    input  wire [15:0] in_r,
    input  wire        in_tgl,
    output reg  [15:0] out_l,
    output reg  [15:0] out_r
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] s;
    always @(posedge clk_audio) begin
        s <= {s[1:0], in_tgl};
        if (s[2] != s[1]) begin out_l <= in_l; out_r <= in_r; end
    end
    initial begin s = 3'd0; out_l = 16'd0; out_r = 16'd0; end
endmodule
