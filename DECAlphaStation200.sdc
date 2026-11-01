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
