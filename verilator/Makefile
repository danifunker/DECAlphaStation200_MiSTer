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
	rm -rf obj_dir obj_tb_* obj_cpu obj_pipe obj_sys smoke.png

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

# the pipelined core (rtl/cpu/ev4_core.v) on the same images
PIPE_RTL = $(RTL)/cpu/ev4_ram.v $(RTL)/cpu/ev4_ialu.v $(RTL)/cpu/ev4_imul.v $(RTL)/cpu/ev4_core.v

obj_pipe/Vev4_core: $(PIPE_RTL) cputest/tb_cpu.cpp
	$(TB_V) --Mdir obj_pipe --top-module ev4_core -Wno-BLKSEQ -CFLAGS '-DCPU_TOP=Vev4_core -DCPU_PIPE' $^

cputest-pipe: obj_pipe/Vev4_core
	$(MAKE) -C ../tests/cpu pal-emu >/dev/null
	@fails=0; for s in $(SUITES); do \
		if obj_pipe/Vev4_core $(T0)/$$s.bin --trace $(T0)/$$s.pipe.trace > $(T0)/$$s.pipe.log; then r=PASS; else r=FAIL; fails=1; fi; \
		if cmp -s $(T0)/$$s.trace $(T0)/$$s.pipe.trace; then t="trace = alphaemu"; \
		else t="trace differs: $$(diff $(T0)/$$s.trace $(T0)/$$s.pipe.trace | head -3 | tr '\n' ' ')"; fails=1; fi; \
		echo "$$r $$s: $$(cat $(T0)/$$s.pipe.log | tr -d '\n'); $$t"; \
	done; exit $$fails

# the SROM bitstream (srom/build) loaded into the I-cache: the first
# instructions retired must be the SROM image's (tests/srom/README.md)
sromload: obj_pipe/Vev4_core
	obj_pipe/Vev4_core --srom ../srom/build/avanti_srom.bitstream --iosink --max 300000 --trace sromload.trace > /dev/null || true
	python3 -I ../tests/srom/check_sromload.py ../srom/build/avanti_srom.bin sromload.trace

.PHONY: cputest cputest-pipe sromload

# ---------------------------------------------------------------- system simulation
# rtl/as200_sys.v: the CPU running our SROM, the 21071 model, COM1; the
# flash and DROM images from scratch/ (not in git)
SYS_RTL = $(PIPE_RTL) $(RTL)/apecs/apecs.v $(RTL)/sio/ns16550.v $(RTL)/scsi/ncr53c810.v $(RTL)/as200_sys.v
FLASH   ?= ../scratch/roms/archive_alpha-station-200-roms/flash_v7.0_arc4.58.bin
DROM    ?= ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E47_DROM1.7.bin

obj_sys/Vas200_sys: $(SYS_RTL) system/tb_sys.cpp
	$(TB_V) --Mdir obj_sys --top-module as200_sys -Wno-BLKSEQ \
		-GSROM_HEX='"../srom/build/avanti_srom.bitstream.hex"' $^

$(FLASH):
	cat ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E13_SRMV7.0-9.bin \
	    ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E19_SRMV7.0-9.bin \
	    ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E33_ARC4.58.bin \
	    ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E46_ARC4.58.bin > $@

system: obj_sys/Vas200_sys $(FLASH)
	obj_sys/Vas200_sys --flash $(FLASH) --drom $(DROM) $(SYSARGS)

.PHONY: system

# the SDRAM controller against a behavioural chip
obj_tb_sdram/Vtb_sdram_top: $(RTL)/mister/sdram_ctl.v tb/sdram_model.v tb/tb_sdram_top.v tb/tb_sdram.cpp
	$(TB_V) --Mdir obj_tb_sdram --top-module tb_sdram_top -Wno-BLKSEQ $^

tb_sdram: obj_tb_sdram/Vtb_sdram_top
	obj_tb_sdram/Vtb_sdram_top

.PHONY: tb_sdram

# ---------------------------------------------------------------- the 53C810 and its SCSI targets
# rtl/scsi: PCI header, the DROM's config test, registers through both BARs,
# SCRIPTS against a disk and a CD-ROM (tb/tb_ncr810.cpp)
SCSI_RTL = $(RTL)/scsi/ncr53c810.v $(RTL)/scsi/scsi_targets.v tb/tb_ncr810_top.v

obj_tb_ncr810/Vtb_ncr810_top: $(SCSI_RTL) tb/tb_ncr810.cpp
	$(TB_V) --Mdir obj_tb_ncr810 --top-module tb_ncr810_top -Wno-BLKSEQ $(NCR_FLAGS) $^

tb_ncr810: obj_tb_ncr810/Vtb_ncr810_top
	obj_tb_ncr810/Vtb_ncr810_top

.PHONY: tb_ncr810

# ---------------------------------------------------------------- SIO (82378 and the ISA devices)
# rtl/sio/sio82378.v on its PCI target bus (verilator/tb/tb_sio.cpp; docs/design/sio.md);
# RTC_FAST: the TOY second is 512 ticks of its 32 kHz (the periodic rates unchanged)
SIO_RTL = $(RTL)/sio/sio82378.v $(RTL)/sio/isa_pic.v $(RTL)/sio/isa_pit.v $(RTL)/sio/isa_dma.v \
	$(RTL)/sio/isa_rtc.v $(RTL)/sio/isa_kbc.v $(RTL)/sio/isa_superio.v $(RTL)/sio/ns16550.v
SIO_V   = $(TB_V) --top-module sio82378 -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -GRTC_FAST=1

obj_tb_sio/Vsio82378: $(SIO_RTL) tb/tb_sio.cpp
	$(SIO_V) --Mdir obj_tb_sio $^

tb_sio: obj_tb_sio/Vsio82378
	obj_tb_sio/Vsio82378

.PHONY: tb_sio

# DEC's DROM V1.7 POST (an EV4 interpreter in the bench) against the SIO: the 82378,
# TOY, 8242, 87332 and interrupts tests must pass (the DROM image from scratch/)
obj_tb_sio_drom/Vsio82378: $(SIO_RTL) tb/tb_sio_drom.cpp
	$(TB_V) --top-module sio82378 -Wno-BLKSEQ -Wno-PINCONNECTEMPTY --Mdir obj_tb_sio_drom $^

tb_sio_drom: obj_tb_sio_drom/Vsio82378 $(FLASH)
	obj_tb_sio_drom/Vsio82378 $(DROM) --flash $(FLASH) $(DROMARGS)

.PHONY: tb_sio_drom
