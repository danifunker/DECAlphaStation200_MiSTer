# Replacement SROM for the AlphaStation 200 core (docs/design/srom.md).
#   make            build/avanti_srom.{bin,bitstream,hex,lst}
#   make check      EV4 opcode scan, size, bitstream round trip
# Options: make DEFS="-DBCACHE=0 -DDROM_CALIBRATE"
CROSS   = alpha-linux-gnu-
AS      = $(CROSS)as -m21064
CPP     = $(CROSS)cpp -P
LD      = $(CROSS)ld
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump
SROM    = python3 -I ../tools/srom/srom.py
B       = build
# 223 blocks x 32 bytes: the 65,536-bit XC1765D
MAX     = 7136

all: $(B)/avanti_srom.bin $(B)/avanti_srom.bitstream $(B)/avanti_srom.hex $(B)/avanti_srom.lst

$(B)/avanti_srom.s: avanti_srom.S
	@mkdir -p $(B)
	$(CPP) $(DEFS) $< > $@
	python3 -I ../tests/cpu/check_ev4.py $@

$(B)/avanti_srom.o: $(B)/avanti_srom.s
	$(AS) -o $@ $<

$(B)/avanti_srom.elf: $(B)/avanti_srom.o
	$(LD) -N -Ttext=0 -e _start -o $@ $<

$(B)/avanti_srom.bin: $(B)/avanti_srom.elf
	$(OBJCOPY) -O binary $< $@
	@n=$$(stat -c %s $@); echo "avanti_srom.bin: $$n bytes (limit $(MAX))"; \
	  test $$n -le $(MAX) || { echo "too big for the XC1765D"; rm -f $@; exit 1; }

$(B)/avanti_srom.bitstream: $(B)/avanti_srom.bin
	$(SROM) encode $< $@

# 64-bit words for $readmemh, 1024 words = the 8 KB I-cache (cpu.md 11.3 srom_data)
$(B)/avanti_srom.hex: $(B)/avanti_srom.bin
	$(SROM) hex $< $@

$(B)/avanti_srom.lst: $(B)/avanti_srom.bin
	$(OBJDUMP) -D -b binary -m alpha:ev4 $< > $@

check: all
	$(SROM) decode $(B)/avanti_srom.bitstream $(B)/roundtrip.bin > $(B)/roundtrip.txt
	cmp -n $$(stat -c %s $(B)/avanti_srom.bin) $(B)/avanti_srom.bin $(B)/roundtrip.bin
	$(SROM) checksum $(B)/avanti_srom.bitstream
	@echo "check: OK"

clean:
	rm -rf $(B)

.PHONY: all check clean
