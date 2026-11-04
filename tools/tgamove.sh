#!/bin/sh
# One traced window move on the board (NT 4.0, OSD Serial port = TGA trace): dumps VRAM, starts
# the trace, moves the active window with the keyboard (Alt+Space, M, KEY x N, Enter), stops the
# trace and dumps VRAM again, into DIR/{before.bin,trace.log,after.bin}.
#   tools/tgamove.sh DIR KEY N [mister]
D=$1; KEY=$2; N=$3; M=${4:-192.168.99.143}
K="$HOME/Downloads/MiSTerKVMS-1.0.27-linux-x86_64/misterkvms-cli --mister $M"
mkdir -p "$D"
ssh root@$M 'test -x /tmp/memdump' 2>/dev/null || scp -q "$(dirname "$0")/../scratch/memdump" root@$M:/tmp/memdump
ssh root@$M '/tmp/memdump 0x30100000 0x200000' 2>/dev/null > "$D/before.bin"
ssh root@$M 'killall socat cat 2>/dev/null; stty -F /dev/ttyS1 921600 raw -echo; setsid nohup cat /dev/ttyS1 > /tmp/t.log 2>/dev/null < /dev/null & sleep 0.3' 2>/dev/null
$K key alt+space >/dev/null 2>&1; sleep 0.5
$K key m >/dev/null 2>&1; sleep 0.5
i=0; while [ $i -lt $N ]; do $K key $KEY >/dev/null 2>&1; sleep 0.3; i=$((i+1)); done
sleep 2.5; $K key Enter >/dev/null 2>&1
sleep 3
ssh root@$M 'killall cat 2>/dev/null; cat /tmp/t.log' 2>/dev/null > "$D/trace.log"
ssh root@$M '/tmp/memdump 0x30100000 0x200000' 2>/dev/null > "$D/after.bin"
wc -l "$D/trace.log"
