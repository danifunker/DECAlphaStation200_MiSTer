#!/bin/sh
# gen_memx.py over N seeds (default 40) x 4 memory timings, each retire trace vs alphaemu.
# Needs ../../build/alphaemu and ../../verilator/obj_pipe (make -C verilator cputest-pipe).
cd "$(dirname "$0")"
fails=0
for seed in $(seq 1 ${1:-40}); do
  python3 -I gen_memx.py build/memx.S $seed 4000 && make -s build/pal/memx.bin >/dev/null 2>&1
  ../../build/alphaemu -P -H 0x800000 -m 16 -l build/pal/memx.bin@0:0 -p 0 -T build/pal/memx.trace 2>/dev/null
  for mode in "" "FASTLINE=1" "MEMDELAY=12" "MEMDELAY=30 FASTLINE=1"; do
    env $mode MEMSEED=$seed ../../verilator/obj_pipe/Vev4_core build/pal/memx.bin --trace build/pal/memx.pipe.trace > /dev/null 2>&1
    if ! cmp -s build/pal/memx.trace build/pal/memx.pipe.trace; then
      echo "DIFF seed $seed mode [$mode]: $(diff build/pal/memx.trace build/pal/memx.pipe.trace | head -2 | tr '\n' ' ')"
      cp build/pal/memx.S build/memx_fail_$seed.S; fails=$((fails+1))
    fi
  done
done
echo "done, $fails differing runs"
