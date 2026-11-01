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
	rm -rf obj_dir obj_tb_* obj_cpu smoke.png

.PHONY: all smoke clean

# ---------------------------------------------------------------- CPU unit benches
# vectors from tests/cpu/unit_vectors.py (gen_int.py's model)
TB_V = $(V) --cc --exe --build -j 3 -O3 -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL
VEC  = ../tests/cpu/build/vec

$(VEC)/ialu.vec: ../tests/cpu/unit_vectors.py ../tests/cpu/gen_int.py
	@mkdir -p $(VEC)
	python3 -I ../tests/cpu/unit_vectors.py ialu $@

obj_tb_ialu/Vev4_ialu: $(RTL)/cpu/ev4_ialu.v tb/tb_ialu.cpp
	$(TB_V) --Mdir obj_tb_ialu --top-module ev4_ialu $^

tb_ialu: obj_tb_ialu/Vev4_ialu $(VEC)/ialu.vec
	obj_tb_ialu/Vev4_ialu $(VEC)/ialu.vec

.PHONY: tb_ialu

$(VEC)/imul.vec: ../tests/cpu/unit_vectors.py ../tests/cpu/gen_int.py
	@mkdir -p $(VEC)
	python3 -I ../tests/cpu/unit_vectors.py imul $@

obj_tb_imul/Vev4_imul: $(RTL)/cpu/ev4_imul.v tb/tb_imul.cpp
	$(TB_V) --Mdir obj_tb_imul --top-module ev4_imul $^

tb_imul: obj_tb_imul/Vev4_imul $(VEC)/imul.vec
	obj_tb_imul/Vev4_imul $(VEC)/imul.vec

.PHONY: tb_imul

# ---------------------------------------------------------------- CPU tests on the RTL
# the T0 bare-metal images on rtl/cpu/ev4_seq.v, each trace diffed against
# alphaemu -P (make -C ../tests/cpu pal pal-emu builds both)
CPU_RTL = $(RTL)/cpu/ev4_ialu.v $(RTL)/cpu/ev4_imul.v $(RTL)/cpu/ev4_seq.v
T0      = ../tests/cpu/build/pal
SUITES  = inta intl ints intm lda mem branch

obj_cpu/Vev4_seq: $(CPU_RTL) cputest/tb_cpu.cpp
	$(TB_V) --Mdir obj_cpu --top-module ev4_seq -Wno-BLKSEQ $^

cputest: obj_cpu/Vev4_seq
	$(MAKE) -C ../tests/cpu pal-emu >/dev/null
	@fails=0; for s in $(SUITES); do \
		if obj_cpu/Vev4_seq $(T0)/$$s.bin --trace $(T0)/$$s.rtl.trace > $(T0)/$$s.rtl.log; then r=PASS; else r=FAIL; fails=1; fi; \
		if cmp -s $(T0)/$$s.trace $(T0)/$$s.rtl.trace; then t="trace = alphaemu"; \
		else t="trace differs: $$(diff $(T0)/$$s.trace $(T0)/$$s.rtl.trace | head -3 | tr '\n' ' ')"; fails=1; fi; \
		echo "$$r $$s: $$(cat $(T0)/$$s.rtl.log | tr -d '\n'); $$t"; \
	done; exit $$fails

.PHONY: cputest
