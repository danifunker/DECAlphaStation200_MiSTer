# OPL3 FPGA

Greg Taylor's OPL3 (YMF262) in SystemVerilog, LGPL-3 (the licence text is in each file's header):
https://github.com/gtaylormb/opl3_fpga

These files are the copy in ao486_MiSTer (`rtl/soc/sound/opl3/`, master `628ddbc`), unchanged, with
`synchronizer.sv` from ao486's `rtl/common/`. `opl3_pkg.sv` sets the chip's clock (24.576 MHz, MiSTer's
CLK_AUDIO) and its sample divider (494: 49.7 kHz). `rtl/audio/opl_isa.v` puts it on the sound card's
ports (388h-38Bh).
