# DEC AlphaStation 200 -- Verilator benches, headless: the CPU and each device on its own, and the
# whole machine (rtl/as200_sys.v) from reset through the firmware (system/tb_sys.cpp).
#
#   make -C verilator            build the system simulator (obj_sys/Vas200_sys)
#   make -C verilator system     run it: SROM, DROM V1.7 POST, SRM (images from scratch/)
#   make -C verilator cputest-pipe / tb_<device>   the CPU suites and the unit benches
V   = verilator
RTL = ../rtl

all: obj_sys/Vas200_sys

clean:
	rm -rf obj_dir obj_tb_* obj_cpu obj_pipe obj_perf obj_sys obj_sys_fast*

.PHONY: all clean

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
PIPE_RTL = $(RTL)/cpu/ev4_ram.v $(RTL)/cpu/ev4_ialu.v $(RTL)/cpu/ev4_imul.v $(RTL)/cpu/ev4_fpu.v $(RTL)/cpu/ev4_fpu_dec.v $(RTL)/cpu/ev4_core.v

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

# T3 privileged tests on the pipelined core (tests/cpu/t3_*.S)
# T3 fpld: FP loads feeding FP compares after a trapping one, under random interrupts (the NT 4.0 +
# IE 4.01 STOP 0x3B, 2026-11-04); built by tests/cpu/t3_fpld.py with tools/alphaasm.py (no binutils)
t3-fpld: obj_pipe/Vev4_core
	python3 -I ../tests/cpu/t3_fpld.py $(T0)/t3_fpld.bin
	obj_pipe/Vev4_core $(T0)/t3_fpld.bin --max 60000000
	IRQRATE=40 IRQSEED=5 MEMDELAY=20 FASTLINE=1 obj_pipe/Vev4_core $(T0)/t3_fpld.bin --max 60000000
	IRQRATE=25 IRQSEED=11 MEMDELAY=7 FASTLINE=1 obj_pipe/Vev4_core $(T0)/t3_fpld.bin --max 60000000

# T3 rwc: HW_LD with RWC (PROBEW) against the DTB's protection (OpenVMS 7.3's installer ACCVIO)
t3-rwc: obj_pipe/Vev4_core
	python3 -I ../tests/cpu/t3_rwc.py $(T0)/t3_rwc.bin
	obj_pipe/Vev4_core $(T0)/t3_rwc.bin

# T3 prefetch: loads to R31/F31 never fault (OpenVMS 8.4's CDSA, lds $$f31 into an unmapped page)
t3-prefetch: obj_pipe/Vev4_core
	python3 -I ../tests/cpu/t3_prefetch.py $(T0)/t3_prefetch.bin
	obj_pipe/Vev4_core $(T0)/t3_prefetch.bin

t3: obj_pipe/Vev4_core
	$(MAKE) -C ../tests/cpu t3 >/dev/null
	obj_pipe/Vev4_core $(T0)/t3_tlb.bin --trace $(T0)/t3_tlb.pipe.trace
	obj_pipe/Vev4_core $(T0)/t3_intr.bin --trace $(T0)/t3_intr.pipe.trace
	obj_pipe/Vev4_core $(T0)/t3_fp.bin --trace $(T0)/t3_fp.pipe.trace
	obj_pipe/Vev4_core $(T0)/t3_fparith.bin --trace $(T0)/t3_fparith.pipe.trace
	obj_pipe/Vev4_core $(T0)/t3_dfill.bin --trace $(T0)/t3_dfill.pipe.trace
	obj_pipe/Vev4_core $(T0)/t3_lock.bin --iosink --trace $(T0)/t3_lock.pipe.trace
	obj_pipe/Vev4_core $(T0)/t3_intrprio.bin --trace $(T0)/t3_intrprio.pipe.trace

# The performance bench: the pipelined core with every signal public (cputest/tb_cpu.cpp CPU_PERF
# reads the stall causes), the memory at the board's latencies (BOARD=1), the microbenchmarks of
# tests/cpu/perf_bench.py (tools/alphaasm.py). docs/design/cpu-perf.md has the numbers.
PERF_BENCH = calls memcpy_in memcpy_out branchy bias loaduse stackmix missmix fpmix divq
obj_perf/Vev4_core: $(PIPE_RTL) cputest/tb_cpu.cpp
	$(TB_V) --Mdir obj_perf --top-module ev4_core -Wno-BLKSEQ --public-flat-rw -CFLAGS '-DCPU_TOP=Vev4_core -DCPU_PIPE -DCPU_PERF' $^

perf: obj_perf/Vev4_core
	@mkdir -p $(T0)
	@for b in $(PERF_BENCH); do 		python3 -I ../tests/cpu/perf_bench.py $$b $(T0)/perf_$$b.bin || exit 1; 		echo "== $$b"; BOARD=1 obj_perf/Vev4_core $(T0)/perf_$$b.bin --max 400000000 || exit 1; 	done

# The write buffer (four line entries that merge) against a model of the memory kept by the
# generator, tests/cpu/wb_stress.py: instant memory, the board's latencies, random delays
wbstress: obj_pipe/Vev4_core
	@mkdir -p $(T0)
	@for s in 1 2 3 4 5 6; do \
		python3 -I ../tests/cpu/wb_stress.py $$s $(T0)/wb_stress.bin || exit 1; \
		obj_pipe/Vev4_core $(T0)/wb_stress.bin --max 20000000 || exit 1; \
		BOARD=1 obj_pipe/Vev4_core $(T0)/wb_stress.bin --max 20000000 || exit 1; \
		MEMDELAY=9 MEMSEED=$$s obj_pipe/Vev4_core $(T0)/wb_stress.bin --max 20000000 || exit 1; \
		IRQRATE=0 MEMDELAY=30 MEMSEED=$$s FASTLINE=1 obj_pipe/Vev4_core $(T0)/wb_stress.bin --max 40000000 || exit 1; \
	done

# FP operations in flight (several in the unit at a time, results in order, forwarding from M2,
# kills by interrupts) against the generator's own registers and memory, tests/cpu/fp_stress.py
fpstress: obj_pipe/Vev4_core
	@mkdir -p $(T0)
	@for s in 1 2 3 4 5 6 7 8; do 		python3 -I ../tests/cpu/fp_stress.py $$s $(T0)/fp_stress.bin || exit 1; 		obj_pipe/Vev4_core $(T0)/fp_stress.bin --max 20000000 || exit 1; 		BOARD=1 obj_pipe/Vev4_core $(T0)/fp_stress.bin --max 20000000 || exit 1; 		MEMDELAY=9 MEMSEED=$$s obj_pipe/Vev4_core $(T0)/fp_stress.bin --max 20000000 || exit 1; 		IRQRATE=40 IRQSEED=$$s MEMDELAY=20 FASTLINE=1 obj_pipe/Vev4_core $(T0)/fp_stress.bin --max 40000000 || exit 1; 		IRQRATE=15 IRQSEED=$$s MEMDELAY=5 MEMSEED=$$s obj_pipe/Vev4_core $(T0)/fp_stress.bin --max 40000000 || exit 1; 	done

# Branch prediction (static prediction and the return stack in F2, checked in X) on random
# control flow, tests/cpu/bp_stress.py, and branches right behind their operand's producer,
# tests/cpu/brz_stress.py: retire traces against tools/alphaemu, checksums under random
# interrupts (tests/cpu/bp_stress.sh)
bpstress: obj_pipe/Vev4_core
	@bash ../tests/cpu/bp_stress.sh 1 2 3 4 5 6 7 8 9 10 11 12
	@GEN=brz_stress.py bash ../tests/cpu/bp_stress.sh 1 2 3 4 5 6

.PHONY: cputest cputest-pipe sromload t3 t3-rwc t3-prefetch perf wbstress fpstress bpstress

# ---------------------------------------------------------------- system simulation
# rtl/as200_sys.v: the CPU running our SROM, the 21071 model, COM1; the
# flash and DROM images from scratch/ (not in git)
SIO_RTL = $(RTL)/sio/ns16550.v $(RTL)/sio/isa_pic.v $(RTL)/sio/isa_pit.v $(RTL)/sio/isa_dma.v $(RTL)/sio/isa_lutram.v \
	$(RTL)/sio/isa_rtc.v $(RTL)/sio/isa_kbc.v $(RTL)/sio/isa_superio.v $(RTL)/sio/isa_fdc.v $(RTL)/sio/isa_fdc_img.v $(RTL)/sio/sio82378.v
SIM_FAST ?= 1
# the OPL3 (SystemVerilog; its package first, as opl3.qip lists it)
OPL3_RTL = $(addprefix $(RTL)/audio/opl3_fpga/,$(shell grep '^set_global' $(RTL)/audio/opl3_fpga/opl3.qip | grep -o '[a-z0-9_]*\.s\?v ') synchronizer.sv)
AUDIO_RTL = $(RTL)/audio/wss_ad1848.v $(RTL)/audio/opl_isa.v $(RTL)/audio/audio_mix.v $(RTL)/audio/as200_audio.v
SYS_RTL = $(PIPE_RTL) $(RTL)/apecs/apecs.v $(RTL)/apecs/bcache.v $(RTL)/apecs/flash28f020.v $(SIO_RTL) $(RTL)/scsi/ncr53c810.v $(RTL)/scsi/scsi_targets.v $(RTL)/scsi/cd_audio.v $(OPL3_RTL) $(AUDIO_RTL) $(RTL)/net/tulip_nb.v $(RTL)/net/tulip21040.v $(RTL)/tga/tga_bt485.v $(RTL)/tga/tga_video.v $(RTL)/tga/tga.v $(RTL)/as200_sys.v
FLASH   ?= ../scratch/roms/archive_alpha-station-200-roms/flash_v7.0_arc4.58.bin
DROM    ?= ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E47_DROM1.7.bin

obj_sys/Vas200_sys: $(SYS_RTL) system/tb_sys.cpp
	$(TB_V) --Mdir obj_sys --top-module as200_sys -Wno-BLKSEQ --savable \
		-GSROM_HEX='"../srom/build/avanti_srom.bitstream.hex"' -GSIM_FAST=$(SIM_FAST) +define+SIM_PCILOG $^

$(FLASH):
	cat ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E13_SRMV7.0-9.bin \
	    ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E19_SRMV7.0-9.bin \
	    ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E33_ARC4.58.bin \
	    ../scratch/roms/archive_alpha-station-200-roms/AVANTI_E46_ARC4.58.bin > $@

system: obj_sys/Vas200_sys $(FLASH)
	obj_sys/Vas200_sys --flash $(FLASH) --drom $(DROM) $(SYSARGS)

# the same machine for long firmware runs: no FM synthesizer (about 20% faster), the SCRIPTS and
# SCSI command trace; run with +ccstep=16 to shorten RPCC delay loops 16x, +iolog for the 8259/8242
obj_sys_fast/Vas200_sys: $(SYS_RTL) system/tb_sys.cpp
	$(TB_V) --Mdir obj_sys_fast --top-module as200_sys -Wno-BLKSEQ --savable \
		-GSROM_HEX='"../srom/build/avanti_srom.bitstream.hex"' -GSIM_FAST=$(SIM_FAST) +define+SIM_PCILOG \
		+define+NCR_TRACE +define+SIM_NOFM $^

# the same build under another name (obj_sys_fast2, ...): keeps a binary and its checkpoints
# while the RTL moves on (a checkpoint loads only into the binary that wrote it)
obj_sys_fast%/Vas200_sys: $(SYS_RTL) system/tb_sys.cpp
	$(TB_V) --Mdir obj_sys_fast$* --top-module as200_sys -Wno-BLKSEQ --savable 		-GSROM_HEX='"../srom/build/avanti_srom.bitstream.hex"' -GSIM_FAST=$(SIM_FAST) +define+SIM_PCILOG 		+define+NCR_TRACE +define+SIM_NOFM $^

system-fast: obj_sys_fast/Vas200_sys $(FLASH)
	obj_sys_fast/Vas200_sys --flash $(FLASH) --drom $(DROM) +ccstep=16 $(SYSARGS)

.PHONY: system system-fast

# the SDRAM controller against a behavioural chip
obj_tb_sdram/Vtb_sdram_top: $(RTL)/mister/sdram_ctl.v tb/sdram_model.v tb/tb_sdram_top.v tb/tb_sdram.cpp
	$(TB_V) --Mdir obj_tb_sdram --top-module tb_sdram_top -Wno-BLKSEQ $^

tb_sdram: obj_tb_sdram/Vtb_sdram_top
	obj_tb_sdram/Vtb_sdram_top

.PHONY: tb_sdram

# the board cache alone, 64 lines (rtl/apecs/bcache.v; verilator/tb/tb_bcache.cpp)
obj_tb_bcache/Vbcache: $(RTL)/apecs/bcache.v tb/tb_bcache.cpp
	$(TB_V) --Mdir obj_tb_bcache --top-module bcache -GLB=6 $^

tb_bcache: obj_tb_bcache/Vbcache
	obj_tb_bcache/Vbcache

.PHONY: tb_bcache

# ---------------------------------------------------------------- the 53C810 and its SCSI targets
# rtl/scsi: PCI header, the DROM's config test, registers through both BARs,
# SCRIPTS against a disk and a CD-ROM (tb/tb_ncr810.cpp)
SCSI_RTL = $(RTL)/scsi/ncr53c810.v $(RTL)/scsi/scsi_targets.v $(RTL)/scsi/cd_audio.v tb/tb_ncr810_top.v

obj_tb_ncr810/Vtb_ncr810_top: $(SCSI_RTL) tb/tb_ncr810.cpp
	$(TB_V) --Mdir obj_tb_ncr810 --top-module tb_ncr810_top -Wno-BLKSEQ $(NCR_FLAGS) $^

tb_ncr810: obj_tb_ncr810/Vtb_ncr810_top
	obj_tb_ncr810/Vtb_ncr810_top

.PHONY: tb_ncr810

# ---------------------------------------------------------------- SIO (82378 and the ISA devices)
# rtl/sio/sio82378.v on its PCI target bus (verilator/tb/tb_sio.cpp; docs/design/sio.md);
# RTC_FAST: the TOY second is 512 ticks of its 32 kHz (the periodic rates unchanged)
SIO_RTL = $(RTL)/sio/sio82378.v $(RTL)/sio/isa_pic.v $(RTL)/sio/isa_pit.v $(RTL)/sio/isa_dma.v $(RTL)/sio/isa_lutram.v \
	$(RTL)/sio/isa_rtc.v $(RTL)/sio/isa_kbc.v $(RTL)/sio/isa_superio.v $(RTL)/sio/isa_fdc.v $(RTL)/sio/isa_fdc_img.v $(RTL)/sio/ns16550.v
SIO_V   = $(TB_V) --top-module sio82378 -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -GRTC_FAST=1 -GFD_SPEED=100

obj_tb_sio/Vsio82378: $(SIO_RTL) tb/tb_sio.cpp
	$(SIO_V) --Mdir obj_tb_sio $^

tb_sio: obj_tb_sio/Vsio82378
	obj_tb_sio/Vsio82378

.PHONY: tb_sio

# the TOY CMOS kept with the NVRAM image and the OSD Console modes (rtl/sio/isa_rtc.v,
# rtl/mister/nvsave.v; verilator/tb/tb_cmos.cpp)
obj_tb_cmos/Vtb_cmos_top: tb/tb_cmos_top.v $(RTL)/sio/isa_rtc.v $(RTL)/sio/isa_lutram.v $(RTL)/mister/nvsave.v tb/tb_cmos.cpp
	$(TB_V) --top-module tb_cmos_top -Wno-BLKSEQ --Mdir obj_tb_cmos $^

tb_cmos: obj_tb_cmos/Vtb_cmos_top
	obj_tb_cmos/Vtb_cmos_top

.PHONY: tb_cmos

# the 8259 pair alone (rtl/sio/isa_pic.v; verilator/tb/tb_isa_pic.cpp): the cascade's corner cases
obj_tb_isa_pic/Visa_pic: $(RTL)/sio/isa_pic.v tb/tb_isa_pic.cpp
	$(TB_V) --top-module isa_pic -Wno-BLKSEQ -Wno-PINCONNECTEMPTY --Mdir obj_tb_isa_pic $^

tb_isa_pic: obj_tb_isa_pic/Visa_pic
	obj_tb_isa_pic/Visa_pic

.PHONY: tb_isa_pic

# the floppy controller (rtl/sio/isa_fdc.v, isa_fdc_img.v) inside the SIO, its image on a model of
# hps_io's slot 3 (verilator/tb/tb_fdc.cpp; docs/design/floppy.md); the drive 100 times a real one's speed
obj_tb_fdc/Vsio82378: $(SIO_RTL) tb/tb_fdc.cpp
	$(SIO_V) --Mdir obj_tb_fdc $^

tb_fdc: obj_tb_fdc/Vsio82378
	obj_tb_fdc/Vsio82378

.PHONY: tb_fdc

# DEC's DROM V1.7 POST (an EV4 interpreter in the bench) against the SIO: the 82378,
# TOY, 8242, 87332 and interrupts tests must pass (the DROM image from scratch/)
obj_tb_sio_drom/Vsio82378: $(SIO_RTL) tb/tb_sio_drom.cpp
	$(TB_V) --top-module sio82378 -Wno-BLKSEQ -Wno-PINCONNECTEMPTY --Mdir obj_tb_sio_drom $^

tb_sio_drom: obj_tb_sio_drom/Vsio82378 $(FLASH)
	obj_tb_sio_drom/Vsio82378 $(DROM) --flash $(FLASH) $(DROMARGS)

.PHONY: tb_sio_drom

# the same DROM with the J2 jumper set: its floppy loader reads a boot block and 20 blocks from a
# 1.44 MB image made by the bench (docs/design/floppy.md 5), and jumps to them at 0x100000
tb_sio_drom_floppy: obj_tb_sio_drom/Vsio82378 $(FLASH)
	obj_tb_sio_drom/Vsio82378 $(DROM) --flash $(FLASH) --floppy-test --cycles 2000000000 $(DROMARGS)

.PHONY: tb_sio_drom_floppy

# ---------------------------------------------------------------- audio (the sound card and the mix)
# rtl/audio on the SIO's xio bus (verilator/tb/tb_audio.cpp; docs/design/audio.md)

obj_tb_audio/Vtb_audio_top: $(OPL3_RTL) $(AUDIO_RTL) $(SIO_RTL) tb/tb_audio_top.v tb/tb_audio.cpp
	$(TB_V) --Mdir obj_tb_audio --top-module tb_audio_top -Wno-BLKSEQ -Wno-PINCONNECTEMPTY $^

tb_audio: obj_tb_audio/Vtb_audio_top
	obj_tb_audio/Vtb_audio_top

.PHONY: tb_audio

# ---------------------------------------------------------------- FPU (rtl/cpu/ev4_fpu.v)
# vectors from tests/fpu/gen_fpu.py (fpmodel.py: the architecture with the EV4 rules),
# piped straight into the bench; FPU_N random operand sets per function code, FPU_MIX
# mixed back-to-back operations (docs/design/fpu.md)
FPU_N   ?= 20000
FPU_MIX ?= 400000
FPU_SEED ?= 1

obj_tb_fpu/Vev4_fpu: $(RTL)/cpu/ev4_fpu.v tb/tb_fpu.cpp
	$(TB_V) --Mdir obj_tb_fpu --top-module ev4_fpu $^

tb_fpu: obj_tb_fpu/Vev4_fpu
	python3 -I ../tests/fpu/gen_fpu.py --n $(FPU_N) --mix $(FPU_MIX) --seed $(FPU_SEED) --jobs 3 2>/dev/null | \
		obj_tb_fpu/Vev4_fpu - --kill 0

obj_tb_fpu_dec/Vev4_fpu_dec: $(RTL)/cpu/ev4_fpu_dec.v tb/tb_fpu_dec.cpp
	$(TB_V) --Mdir obj_tb_fpu_dec --top-module ev4_fpu_dec $^

# the decoder against fpmodel.legal() for every function code of opcodes 15 and 16
tb_fpu_dec: obj_tb_fpu_dec/Vev4_fpu_dec
	python3 -I -c 'import sys; sys.path.insert(0, "../tests/fpu"); from fpmodel import legal; \
		[print("%08x %d" % (ir, legal(ir))) for opc in (0x15, 0x16) for fn in range(2048) \
		 for ir in [(opc << 26) | (31 << 21) | (31 << 16) | (fn << 5) | 31]]' | obj_tb_fpu_dec/Vev4_fpu_dec

.PHONY: tb_fpu tb_fpu_dec

# the 21071 model's DMA translation: direct and scatter/gather windows, the S/G TLB, TBIA
obj_tb_apecs/Vapecs: $(RTL)/apecs/apecs.v tb/tb_apecs.cpp
	$(TB_V) --Mdir obj_tb_apecs --top-module apecs -Wno-BLKSEQ $^

tb_apecs: obj_tb_apecs/Vapecs
	obj_tb_apecs/Vapecs

.PHONY: tb_apecs

# rtl/net: the DECchip 21040 with its mailbox side, against a modelled memory, DDR3 mailbox and
# Main's bridge (verilator/tb/tb_tulip.cpp; docs/design/ethernet.md)
NET_RTL = $(RTL)/net/tulip21040.v $(RTL)/net/tulip_nb.v
obj_tb_tulip/Vtulip21040: $(NET_RTL) tb/tb_tulip.cpp
	$(TB_V) --Mdir obj_tb_tulip --top-module tulip21040 -Wno-BLKSEQ -Wno-UNUSEDPARAM $^

tb_tulip: obj_tb_tulip/Vtulip21040
	obj_tb_tulip/Vtulip21040

.PHONY: tb_tulip

# ---------------------------------------------------------------- TGA (rtl/tga, docs/design/tga.md)
# the 21030 + Bt485 + display with rtl/mister/ddr3_arb.v and fbrom.v on a modelled
# DDRAM bridge (tb/tb_tga.cpp); the displayed frame goes to TGA_PPM
TGA_RTL = $(RTL)/tga/tga.v $(RTL)/tga/tga_bt485.v $(RTL)/tga/tga_video.v $(RTL)/tga/tga_vsel.v \
	$(RTL)/mister/ddr3_arb.v $(RTL)/mister/fbrom.v tb/tb_tga_top.v
TGA_PPM ?= ../scratch/tga_frame.ppm

obj_tb_tga/Vtb_tga_top: $(TGA_RTL) tb/tb_tga.cpp
	$(TB_V) --Mdir obj_tb_tga --top-module tb_tga_top -Wno-BLKSEQ $^

tb_tga: obj_tb_tga/Vtb_tga_top
	obj_tb_tga/Vtb_tga_top --ppm $(TGA_PPM)

.PHONY: tb_tga
