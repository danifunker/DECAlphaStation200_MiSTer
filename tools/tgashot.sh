#!/bin/sh
# A screenshot of the TGA picture straight from VRAM (the core's DDR3 at 0x30100000) over ssh,
# no capture needed: tools/tgashot.sh OUT.png [mister]  (memdump: tools/memdump.c, ARM static)
M=${2:-192.168.99.143}
D=$(cd "$(dirname "$0")/.." && pwd)
[ -x "$D/scratch/memdump" ] || arm-linux-gnueabihf-gcc -O2 -static -o "$D/scratch/memdump" "$D/tools/memdump.c"
ssh root@$M 'test -x /tmp/memdump' 2>/dev/null || scp -q "$D/scratch/memdump" root@$M:/tmp/memdump 2>/dev/null
ssh root@$M '/tmp/memdump 0x30100000 0x200000' 2>/dev/null > /tmp/tgashot.$$.bin
python3 - "$1" /tmp/tgashot.$$.bin <<'PY'
import sys
from PIL import Image
d = open(sys.argv[2], 'rb').read()
# the stride: the autocorrelation peak among the TGA's line lengths
best = max((sum(1 for i in range(20000, 80000, 7) if d[i] == d[i + w]), w) for w in (640, 644, 800, 804, 1024, 1028, 1152, 1156, 1280, 1284))
w = best[1]; h = {640: 480, 644: 480, 800: 600, 804: 600, 1024: 768, 1028: 768, 1152: 900, 1156: 900, 1280: 1024, 1284: 1024}[w]
pal = {0: (0, 0, 0), 1: (0, 0, 170), 2: (0, 170, 0), 3: (0, 170, 170), 4: (0, 0, 170), 7: (170, 170, 170), 8: (85, 85, 85),
       9: (85, 85, 255), 12: (255, 85, 85), 14: (255, 255, 85), 15: (255, 255, 255)}
im = Image.new('RGB', (w, h)); im.putdata([pal.get(b, (b, b, b)) for b in d[:w * h]]); im.save(sys.argv[1])
print(w, h)
PY
rm -f /tmp/tgashot.$$.bin
