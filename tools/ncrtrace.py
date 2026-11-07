#!/usr/bin/env python3
"""Decode the SCRIPTS trace (ncr53c810.v's dbg_*, OSD Serial port = TGA trace, 921600 baud on
/dev/ttyS1): E3F0t lines into readable events.

usage: ncrtrace.py LOG [-n LAST] [--no-ins]
  -n LAST    only the last LAST events
  --no-ins   leave out the instruction lines (t = 1)
"""
import sys

PHASE = ['DATA_OUT', 'DATA_IN', 'CMD', 'STATUS', 'res4', 'res5', 'MSG_OUT', 'MSG_IN']
REG = {0x00: 'SCNTL0-3', 0x04: 'SCID/SXFER/SDID/GPREG', 0x08: 'SFBR/SOCL/SSID/SBCL', 0x0C: 'DSTAT/SSTAT',
       0x10: 'DSA', 0x14: 'ISTAT', 0x18: 'CTEST0-3', 0x1C: 'TEMP', 0x20: 'DFIFO/CTEST4-6', 0x24: 'DBC/DCMD',
       0x28: 'DNAD', 0x2C: 'DSP', 0x30: 'DSPS', 0x34: 'SCRATCHA', 0x38: 'DMODE/DIEN/DWT/DCNTL', 0x3C: 'ADDER',
       0x40: 'SIEN/SIST', 0x44: 'SLPAR/MACNTL/GPCNTL', 0x48: 'STIME/RESPID', 0x4C: 'STEST', 0x50: 'SIDL',
       0x54: 'SODL', 0x58: 'SBDL', 0x5C: 'SCRATCHB'}


def ins(w):
    op = w >> 30
    if op == 0:
        return 'MOVE%s %d phase %s' % (' table' if w & (1 << 28) else '', w & 0xFFFFFF, PHASE[(w >> 24) & 7])
    if op == 2:
        k = ['JUMP', 'CALL', 'RETURN', 'INT', '?', '?', '?', '?'][(w >> 27) & 7]
        c = '%s%s%s%s' % ('' if w & (1 << 19) else ' NOT', ' WHEN' if w & (1 << 16) else ' IF',
                          ' ' + PHASE[(w >> 24) & 7] if w & (1 << 17) else '',
                          ' data %02X mask %02X' % (w & 0xFF, (w >> 8) & 0xFF) if w & (1 << 18) else '')
        return k + c
    if op == 3:
        return 'MEMMOVE/LOADSTORE %08X' % w
    o = (w >> 27) & 7
    if o == 0:
        return 'SELECT%s' % (' ATN' if w & (1 << 24) else '')
    if o == 1:
        return 'WAIT DISCONNECT'
    if o == 2:
        return 'WAIT RESELECT'
    if o in (3, 4):
        b = [n for bit, n in ((3, 'ATN'), (6, 'ACK'), (9, 'TARGET'), (10, 'CARRY')) if w & (1 << bit)]
        return ('SET ' if o == 3 else 'CLEAR ') + ' '.join(b)
    return 'REG %08X' % w


def bus(v):
    f = [n for bit, n in ((7, 'selecting'), (6, 'con'), (5, 'atn'), (4, 'ackhold'), (3, 'bsy')) if v & (1 << bit)]
    return ' '.join(f) + ' ' + PHASE[v & 7]


def main():
    a = sys.argv[1:]
    noins = '--no-ins' in a
    last = int(a[a.index('-n') + 1]) if '-n' in a else 0
    out = []
    for l in open(a[0], errors='replace'):
        p = l.split()
        if l.startswith('D') and len(p) == 1:
            out.append('--- %d events lost' % int(p[0][1:], 16))
            continue
        if len(p) != 3 or not p[0].startswith('E3F0'):
            continue
        t = int(p[0][4], 16)
        d = int(p[1], 16)
        b = int(p[2], 16)
        if t == 1 and not noins:
            out.append('%08X  %08X  %s' % (d, b, ins(b)))
        elif t == 2:
            out.append('%08X  INT  DSTAT %02X SIST0 %02X SIST1 %X ISTAT %02X' %
                       (d, b >> 24, (b >> 16) & 255, (b >> 8) & 7, b & 255))
        elif t == 3:
            r = ((b >> 20) & 31) * 4
            out.append('%08X  HOST write %02X %s be %X data %04X' % (d, r, REG.get(r, '?'), b >> 28, b & 0xFFFF))
        elif t == 4:
            out.append('%08X  BUS  %s  sfbr %02X target st %d op %02X' %
                       (d, bus((b >> 16) & 255), b >> 24, (b >> 8) & 31, b & 255))
    print('\n'.join(out[-last:] if last else out))


if __name__ == '__main__':
    main()
