#!/bin/sh
# Control-flow smoke test of the replacement SROM on tools/alphaemu -P
# (no RTL needed). alphaemu has flat memory and no 21071, so this is NOT a
# system test (README.md): the 21071 CSRs are plain memory, memory sizing
# sees no aliasing (3 x 128 MB = 384 MB) and the flashbus is replaced by a
# RAM copy (-DTEST_FLASH_RAM). It checks: the LED sequence, the DROM copy and
# its checksum/header test against the real DROM, the parameter block, the
# flush stub and the HW_REI into the DROM at 0x40000.
#
#   tests/srom/emu_smoke.sh [DROM.bin]   (default: DROM V1.7 in scratch/)
set -e
R=$(cd "$(dirname "$0")/../.." && pwd)
DROM=${1:-$R/scratch/roms/archive_alpha-station-200-roms/AVANTI_E47_DROM1.7.bin}
[ -f "$DROM" ] || { echo "SKIP: no $DROM"; exit 0; }
B=$R/tests/srom/build
EMU=$R/build/alphaemu
[ -x "$EMU" ] || cc -O2 -Wall -o "$EMU" "$R/tools/alphaemu/alphaemu.c"
make -s -C "$R/srom" B="$B" DEFS="-DZERO_BASE=0x2000 -DTEST_FLASH_RAM" "$B/avanti_srom.bin"
# 8 GB of lazily allocated flat memory covers the CSRs at 1.8000.0000/1.A000.0000
"$EMU" -P -m 8192 -l "$B/avanti_srom.bin@0:0" -l "$DROM@0:0x110180000" -p 0 \
	-n 4000000 -T "$B/emu.trace" > "$B/emu.log" 2>&1 || true
python3 -I - "$B/emu.trace" "$DROM" <<'EOF'
import sys
trace, drom = sys.argv[1], open(sys.argv[2], 'rb').read()
leds, mem, pcs = [], {}, []
for line in open(trace):
    f = line.split()
    pc = int(f[0], 16)
    pcs.append(pc)
    for x in f[2:]:
        if x.startswith('m'):
            a, v = x[1:].split('=')
            v, n = v.split('/')
            a, v = int(a, 16), int(v, 16)
            if a == 0x100100000 and pc < 0x2000:
                leds.append(v)
            mem[a] = v
ok = True
def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok = ok and cond
want = [0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8, 0xF7, 0xF6, 0xF3, 0xF1, 0xF0]
check('LED sequence ' + ' '.join('%02X' % x for x in leds), leds == want)
img = b''.join(mem.get(0x3FFC0 + 8 * k, 0).to_bytes(8, 'little') for k in range(0x2000))
check('DROM copied to 0x3FFC0..0x4FFBF byte for byte', img == drom)
size = 3 * 128 << 20       # alphaemu: no aliasing, every bank looks like 128 MB
pb = {0x00: 0, 0x08: size, 0x10: 10000, 0x18: 0xDECB0000, 0x20: 1, 0x28: 0,
      0x38: size >> 20, 0x68: 100, 0x70: 9, 0x110: 0}
for a, v in pb.items():
    check('PA %#05x = %#x' % (a, v), mem.get(a) == v)
stub = [0x74000024, 0x77FF0055] + [0x47FF041F] * 5 + [0x7BFF8000]
got = [(mem.get(0x4FFC0 + 8 * (k // 2), 0) >> (32 * (k % 2))) & 0xFFFFFFFF for k in range(8)]
check('flush stub at 0x4FFC0', got == stub)
i = next((k for k, p in enumerate(pcs) if p == 0x4FFC0), None)
check('HW_REI into the stub', i is not None)
check('stub HW_REIs to the DROM entry 0x40000', i is not None and pcs[i + 8] == 0x40000)
check('DROM runs: its br at image 0x40 reaches image 0xbc = PA 0x4007c', 0x4007C in pcs)
sys.exit(0 if ok else 1)
EOF
