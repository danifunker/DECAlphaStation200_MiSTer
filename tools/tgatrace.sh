#!/bin/sh
# The TGA trace (OSD P5 Serial port = TGA trace) from the board: prints the lines
# (rtl/mister/dbg_trace.v) and keeps a copy in scratch/tgatrace.log.
#   tools/tgatrace.sh [speed] [mister-address]   (speed = the MiSTer's UART menu speed)
S=${1:-115200}
M=${2:-192.168.99.143}
ssh root@$M "killall socat 2>/dev/null; stty -F /dev/ttyS1 $S raw -echo; cat /dev/ttyS1" | \
	tee "$(dirname "$0")/../scratch/tgatrace.log"
