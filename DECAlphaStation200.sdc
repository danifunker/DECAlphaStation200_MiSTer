derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# The 65 MHz pixel clock (emu|pll outclk_2) and the 50 MHz system clock
# (outclk_0) come from one PLL, so they would be timed as related clocks
# with a 1.5 ns relationship. Every crossing between them is safe by
# construction: the dual-clock text RAM and two-flop synchronisers of
# quasi-static values (rtl/mister/vterm.v), the settings latch cfg read by
# video_freak, hps_io's video_calc. Time them as asynchronous.
set_clock_groups -asynchronous \
	-group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
	-group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

# The HDMI clock (148.5 MHz at 1080p) misses by a few tenths of a ns inside the template's scaler
# (sys/ascal: o_vcpt_pre3, o_hacc_next) when the chip is full; sys/ is not ours to edit. The fitter
# alone sees 0.8 ns more setup uncertainty on that clock, so it places the scaler for a shorter period;
# the timing analysis after the fit reports the real figures.
if {$::quartus(nameofexecutable) == "quartus_fit"} {
	set_clock_uncertainty -setup -add -from [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] -to [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] 0.8
}
