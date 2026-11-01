# T0 CPU tests (README.md). `make` generates the suites, builds the qemu-alpha
# user programs, checks them for non-EV4 opcodes and runs them under
# `qemu-alpha -cpu ev4`: the expected values (gen_int.py's model) are then
# confirmed by QEMU.
CROSS  = alpha-linux-gnu-
AS     = $(CROSS)as -m21064
CPP    = $(CROSS)cpp -P -I rt
LD     = $(CROSS)ld
OBJDUMP= $(CROSS)objdump
QEMU   = qemu-alpha -cpu ev4
B      = build

SUITES = inta intl ints intm lda mem branch

all: user

$(B)/.gen: gen_int.py
	python3 -I gen_int.py $(B)
	@touch $@

$(B)/%.S: $(B)/.gen ;

$(B)/user/%.o: $(B)/%.S rt/t0.h
	@mkdir -p $(B)/user
	$(CPP) -DT0_USER $< > $(B)/user/$*.s
	$(AS) -o $@ $(B)/user/$*.s

$(B)/user/fail.o: rt/user_fail.S
	@mkdir -p $(B)/user
	$(CPP) $< > $(B)/user/fail.s
	$(AS) -o $@ $(B)/user/fail.s

# -N: text writable (the mem suite stores into its inline data)
$(B)/user/%: $(B)/user/%.o $(B)/user/fail.o
	$(LD) -N -e _start -o $@ $^
	@python3 -I check_ev4.py $(B)/user/$*.s rt/user_fail.S

user: $(SUITES:%=$(B)/user/%)
	@fails=0; for s in $(SUITES); do \
		if $(QEMU) $(B)/user/$$s; then echo "PASS $$s"; else echo "FAIL $$s"; fails=1; fi; \
	done; exit $$fails

# bare-metal PALmode images (rt/t0_pal.h): ELF linked at PA 0 and a raw .bin
# for the RTL harness; `make pal-emu` runs them on alphaemu -P
OBJCOPY = $(CROSS)objcopy
$(B)/pal/%.o: $(B)/%.S rt/t0.h rt/t0_pal.h
	@mkdir -p $(B)/pal
	$(CPP) $< > $(B)/pal/$*.s
	@python3 -I check_ev4.py $(B)/pal/$*.s
	$(AS) -o $@ $(B)/pal/$*.s

$(B)/pal/%.elf: $(B)/pal/%.o
	$(LD) -N -Ttext=0 -e _start -o $@ $<

$(B)/pal/%.bin: $(B)/pal/%.elf
	$(OBJCOPY) -O binary $< $@

pal: $(SUITES:%=$(B)/pal/%.bin)

# T3 privileged tests: hand-written PALmode images (no T0 harness)
$(B)/pal/t3_%.o: t3_%.S
	@mkdir -p $(B)/pal
	$(CPP) $< > $(B)/pal/t3_$*.s
	@python3 -I check_ev4.py $(B)/pal/t3_$*.s
	$(AS) -o $@ $(B)/pal/t3_$*.s

t3: $(B)/pal/t3_tlb.bin $(B)/pal/t3_intr.bin

TOHOST = 0x800000
pal-emu: $(EMU) pal
	@fails=0; for s in $(SUITES); do \
		if $(EMU) -P -H $(TOHOST) -m 16 -l $(B)/pal/$$s.bin@0:0 -p 0 -T $(B)/pal/$$s.trace 2>$(B)/pal/$$s.log; \
		then echo "PASS $$s (alphaemu -P)"; else echo "FAIL $$s (alphaemu -P)"; tail -2 $(B)/pal/$$s.log; fails=1; fi; \
	done; exit $$fails

# the same programs on tools/alphaemu (the golden model for the RTL lockstep)
EMU = ../../build/alphaemu
$(EMU): ../../tools/alphaemu/alphaemu.c
	cc -O2 -Wall -o $@ $<

emu: $(EMU) $(SUITES:%=$(B)/user/%)
	@fails=0; for s in $(SUITES); do \
		if $(EMU) -e $(B)/user/$$s -T $(B)/user/$$s.trace 2>/dev/null; then echo "PASS $$s (alphaemu)"; \
		else echo "FAIL $$s (alphaemu)"; fails=1; fi; \
	done; exit $$fails

clean:
	rm -rf $(B)

.PHONY: all user emu pal pal-emu clean
.PRECIOUS: $(B)/%.S $(B)/user/%.o $(B)/pal/%.o $(B)/pal/%.elf
