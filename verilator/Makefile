# DEC AlphaStation 200 -- Verilator simulation of the machine (rtl/as200.v)
# with the MiSTer-side serial terminal, headless (verilator/sim_main.cpp).
#
#   make -C verilator            build obj_dir/Vsim_top
#   make -C verilator smoke      the bring-up banner, an echo over RXD and a
#                                typed line, with a screenshot
V   = verilator
RTL = ../rtl

V_SRC = $(RTL)/sio/ns16550.v $(RTL)/bringup_stub.v $(RTL)/as200.v \
	$(RTL)/mister/vterm.v sim_top.v
C_SRC = sim_main.cpp

V_FLAGS = --cc --exe --build -j 3 --top-module sim_top -O3 \
	--x-assign fast --x-initial fast --noassert \
	-Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	-Wno-PINCONNECTEMPTY -Wno-BLKSEQ \
	-CFLAGS "-O2 -I.."

EXE = obj_dir/Vsim_top

all: $(EXE)

$(EXE): $(V_SRC) $(C_SRC) Makefile
	$(V) $(V_FLAGS) $(V_SRC) $(C_SRC) -o Vsim_top

smoke: $(EXE)
	$(EXE) --until '>' --rx 'echo over RXD\r' --type 'typed at the keyboard\r' --after 5 \
		--screenshot smoke.png

clean:
	rm -rf obj_dir smoke.png

.PHONY: all smoke clean
