#!/bin/sh
# Interrupts at random points: the T0 suites and gen_memx.py seeds built with T0_IRQ
# (rt/t0_pal.h: a transparent handler for irq_h[0]) run on the pipelined core with
# IRQRATE=R (tb_cpu: irq_h[0] at random), and must still pass, with the native part of
# the retire trace (the PALmode handler's lines dropped) the same as alphaemu's run
# without interrupts: an instruction run twice or skipped across an interrupt shows.
#   irq_sweep.sh [MEMX_SEEDS] [RATES]
# Needs ../../build/alphaemu and ../../verilator/obj_pipe/Vev4_core.
cd "$(dirname "$0")"
X=alpha-linux-gnu-
B=build/irq
mkdir -p $B
EMU=../../build/alphaemu
CORE=../../verilator/obj_pipe/Vev4_core
nseeds=${1:-10}
rates=${2:-"40 150 700"}
fails=0
python3 -I gen_int.py build >/dev/null
one() {   # $1 = name, $2 = source .S
  ${X}cpp -P -I rt -DT0_IRQ $2 > $B/$1.s && ${X}as -m21064 -o $B/$1.o $B/$1.s &&
  ${X}ld -N -Ttext=0 -e _start -o $B/$1.elf $B/$1.o && ${X}objcopy -O binary $B/$1.elf $B/$1.bin || { echo "BUILD $1"; fails=$((fails+1)); return; }
  $EMU -P -H 0x800000 -m 16 -l $B/$1.bin@0:0 -p 0 -T $B/$1.trace 2>/dev/null
  grep -v '^0000000000' $B/$1.trace > $B/$1.ntrace
  for r in $rates; do
    for mode in "" "MEMDELAY=20 FASTLINE=1"; do
      env $mode IRQRATE=$r IRQSEED=$r MEMSEED=$r $CORE $B/$1.bin --max 20000000 --trace $B/$1.pt > $B/$1.plog 2>&1
      ok=$?
      grep -v '^0000000000' $B/$1.pt > $B/$1.npt
      if [ $ok != 0 ] || ! cmp -s $B/$1.ntrace $B/$1.npt; then
        echo "FAIL $1 rate $r [$mode]: $(tr '\n' ' ' < $B/$1.plog) $(diff $B/$1.ntrace $B/$1.npt | head -3 | tr '\n' ' ')"
        cp $B/$1.s $B/fail_$1_$r.s; fails=$((fails+1))
      else echo "ok $1 rate $r [$mode]: $(tr '\n' ' ' < $B/$1.plog)"; fi
    done
  done
}
for s in inta intl ints intm lda mem branch; do one $s build/$s.S; done
for seed in $(seq 1 $nseeds); do python3 -I gen_memx.py $B/memx$seed.S $seed 3000; one memx$seed $B/memx$seed.S; done
echo "done, $fails failures"
