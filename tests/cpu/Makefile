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

clean:
	rm -rf $(B)

.PHONY: all user clean
.PRECIOUS: $(B)/%.S $(B)/user/%.o
