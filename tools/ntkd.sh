#!/bin/sh
# NT's kernel debugger for the board's NT: COM1 (the MiSTer UART, OSD P5 Serial port = COM1) ->
# the MiSTer's /dev/ttyS1 -> TCP -> a pty here -> Wine's COM1 -> ALPHAKD.EXE (NT 4.0 CD,
# SUPPORT/DEBUG/I386; the Alpha symbols in SUPPORT/DEBUG/ALPHA/SYMBOLS).
# NT boots with OSLOADOPTIONS "/DEBUG /DEBUGPORT=COM1 /BAUDRATE=115200" (ARC: Manage boot
# selection menu). The MiSTer's UART menu speed must be 115200.
#   tools/ntkd.sh [mister-address]        (scratch/ntkd holds ALPHAKD.EXE and SUPPORT/)
set -e
M=${1:-192.168.99.143}
D=$(cd "$(dirname "$0")/../scratch/ntkd" && pwd)
ssh root@$M 'killall socat 2>/dev/null; setsid nohup socat TCP-LISTEN:5150,reuseaddr /dev/ttyS1,raw,echo=0,b115200 >/dev/null 2>&1 < /dev/null &'
sleep 1
mkdir -p "$HOME/.wine/dosdevices"
rm -f "$HOME/.wine/dosdevices/com1"
socat PTY,link="$HOME/.wine/dosdevices/com1",raw,echo=0 TCP:$M:5150 &
SOCAT=$!
trap 'kill $SOCAT 2>/dev/null' EXIT
sleep 1
cd "$D"
_NT_DEBUG_PORT=com1 _NT_DEBUG_BAUD_RATE=115200 \
_NT_SYMBOL_PATH="$D/SUPPORT/DEBUG/ALPHA/SYMBOLS" WINEDEBUG=${WINEDEBUG:--all} wine ALPHAKD.EXE -v "$@"
