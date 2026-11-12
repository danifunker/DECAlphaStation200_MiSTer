#!/bin/bash
# Branch prediction stress (make -C verilator bpstress): tests/cpu/bp_stress.py images on the
# pipelined core against tools/alphaemu. Without interrupts the retire traces must be the same
# line for line (instant memory, the board's latencies, random delays); with random interrupts
# the checksums the image leaves at TOHOST + 8 / + 16 must be alphaemu's.
#   bp_stress.sh SEED...      (run from verilator/; GEN=brz_stress.py runs that generator instead)
set -u
here=$(cd "$(dirname "$0")" && pwd)
b=$here/build/pal
emu=$here/build/alphaemu
mkdir -p "$b"
[ -x "$emu" ] || cc -O2 -o "$emu" "$here/../../tools/alphaemu/alphaemu.c" || exit 1
rc=0
for s in "$@"; do
    python3 -I "$here/${GEN:-bp_stress.py}" "$s" "$b/bp_stress.bin" || exit 1
    "$emu" -P -H 0x800000 -m 16 -l "$b/bp_stress.bin@0:0" -p 0 -T "$b/bp_stress.ref" > "$b/bp_stress.emu.log" 2>&1
    n=$(wc -l < "$b/bp_stress.ref")
    # the checksums: the two stores before the last instruction of the trace
    want=$(tail -3 "$b/bp_stress.ref" | head -2 | sed 's/.* m[0-9a-f]*=\([0-9a-f]*\)\/.*/\1/' | tr '\n' ' ')
    if [ "$n" -lt 2000 ]; then echo "bp_stress $s: the reference ran only $n instructions"; rc=1; continue; fi
    run() {     # NAME ENV...
        local name=$1; shift
        local o
        o=$(env "$@" obj_pipe/Vev4_core "$b/bp_stress.bin" --max 60000000 --trace "$b/bp_stress.trace" 2>&1 | grep TOHOST)
        case "$o" in "TOHOST 0x1 "*) ;; *) echo "bp_stress $s $name: $o"; rc=1; return;; esac
        local got
        got=$(echo "$o" | sed 's/.*+8 \(0x\)\{0,1\}\([0-9a-f]*\), +16 \(0x\)\{0,1\}\([0-9a-f]*\)).*/\2 \4/')
        local w1 w2 g1 g2
        read w1 w2 <<< "$want"; read g1 g2 <<< "$got"
        if [ $((16#$w1)) != $((16#$g1)) ] || [ $((16#$w2)) != $((16#$g2)) ]; then
            echo "bp_stress $s $name: checksums $got, alphaemu $want"; rc=1; return
        fi
        if [ "$name" != irq ] && ! cmp -s "$b/bp_stress.ref" "$b/bp_stress.trace"; then
            echo "bp_stress $s $name: the trace differs from alphaemu's:"
            diff "$b/bp_stress.ref" "$b/bp_stress.trace" | head -6; rc=1; return
        fi
    }
    run plain X=0
    run board BOARD=1
    run delay MEMDELAY=9 MEMSEED=$s
    run delay2 MEMDELAY=30 MEMSEED=$s FASTLINE=1
    run irq IRQRATE=40 IRQSEED=$s MEMDELAY=20 FASTLINE=1
    run irq IRQRATE=15 IRQSEED=$s MEMDELAY=5 MEMSEED=$s
    run irq IRQRATE=7 IRQSEED=$s BOARD=1
    echo "${GEN:-bp_stress.py} $s: $n instructions, checksums $want: rc $rc"
done
exit $rc
