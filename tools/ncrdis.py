#!/usr/bin/env python3
"""Disassemble NCR 53C810 SCRIPTS out of a memory image (a simulator checkpoint's .mem, a
DRAM dump) or a raw file.

usage: ncrdis.py FILE --at FILEOFF --pci PCIADDR --len BYTES [--start PCIADDR]
  FILEOFF   where the SCRIPTS start in FILE (the .mem of a system-sim checkpoint is the DRAM
            from PA 0, so FILEOFF = the SCRIPTS' PA)
  PCIADDR   the PCI (DSP) address of that same byte: jump targets print in this space
  --start   begin the listing at this PCI address (default PCIADDR)

Decodes block moves (table/absolute), I/O (SELECT, WAIT DISCONNECT/RESELECT, SET/CLEAR),
read-modify-write with the register names, transfer control (JUMP/CALL/RETURN/INT with the
phase and SFBR tests, relative targets resolved) and the 3-longword memory moves.
"""
import struct, sys

PHASE = ['DATA_OUT', 'DATA_IN', 'CMD', 'STATUS', 'res4', 'res5', 'MSG_OUT', 'MSG_IN']
REGS = {0x00: 'SCNTL0', 0x01: 'SCNTL1', 0x02: 'SCNTL2', 0x03: 'SCNTL3', 0x04: 'SCID', 0x05: 'SXFER',
        0x06: 'SDID', 0x07: 'GPREG', 0x08: 'SFBR', 0x09: 'SOCL', 0x0A: 'SSID', 0x0B: 'SBCL', 0x0C: 'DSTAT',
        0x0D: 'SSTAT0', 0x0E: 'SSTAT1', 0x0F: 'SSTAT2', 0x10: 'DSA0', 0x11: 'DSA1', 0x12: 'DSA2', 0x13: 'DSA3',
        0x14: 'ISTAT', 0x18: 'CTEST0', 0x19: 'CTEST1', 0x1A: 'CTEST2', 0x1B: 'CTEST3', 0x1C: 'TEMP0',
        0x1D: 'TEMP1', 0x1E: 'TEMP2', 0x1F: 'TEMP3', 0x20: 'DFIFO', 0x21: 'CTEST4', 0x22: 'CTEST5',
        0x23: 'CTEST6', 0x24: 'DBC0', 0x25: 'DBC1', 0x26: 'DBC2', 0x27: 'DCMD', 0x28: 'DNAD0', 0x29: 'DNAD1',
        0x2A: 'DNAD2', 0x2B: 'DNAD3', 0x2C: 'DSP0', 0x2D: 'DSP1', 0x2E: 'DSP2', 0x2F: 'DSP3', 0x30: 'DSPS0',
        0x31: 'DSPS1', 0x32: 'DSPS2', 0x33: 'DSPS3', 0x34: 'SCRATCHA0', 0x35: 'SCRATCHA1', 0x36: 'SCRATCHA2',
        0x37: 'SCRATCHA3', 0x38: 'DMODE', 0x39: 'DIEN', 0x3A: 'DWT', 0x3B: 'DCNTL', 0x3C: 'ADDER0',
        0x3D: 'ADDER1', 0x3E: 'ADDER2', 0x3F: 'ADDER3', 0x40: 'SIEN0', 0x41: 'SIEN1', 0x42: 'SIST0',
        0x43: 'SIST1', 0x44: 'SLPAR', 0x46: 'MACNTL', 0x47: 'GPCNTL', 0x48: 'STIME0', 0x49: 'STIME1',
        0x4A: 'RESPID', 0x4C: 'STEST0', 0x4D: 'STEST1', 0x4E: 'STEST2', 0x4F: 'STEST3', 0x50: 'SIDL0',
        0x51: 'SIDL1', 0x54: 'SODL0', 0x55: 'SODL1', 0x58: 'SBDL0', 0x59: 'SBDL1', 0x5C: 'SCRATCHB0',
        0x5D: 'SCRATCHB1', 0x5E: 'SCRATCHB2', 0x5F: 'SCRATCHB3'}
RMW_OP = ['MOVE', 'SHL', 'OR', 'XOR', 'AND', 'SHR', 'ADD', 'ADDC']


def reg(n):
    return REGS.get(n, 'reg%02X' % n)


def cond(w):
    """the test of a transfer-control instruction"""
    parts = []
    if w & (1 << 21):
        parts.append('CARRY' + ('' if w & (1 << 19) else ' CLEAR'))
    else:
        t = [] if w & (1 << 19) else ['NOT']
        if w & (1 << 17):
            t.append(PHASE[(w >> 24) & 7])
        if w & (1 << 18):
            mask = (w >> 8) & 0xFF
            t.append('SFBR==%02X' % (w & 0xFF) + ('' if mask == 0 else ' (bits %02X)' % (0xFF & ~mask)))
        if t:
            parts.append(('WHEN ' if w & (1 << 16) else 'IF ') + ' '.join(t))
    if w & (1 << 20):
        parts.append('(INT on the fly)')
    return ' '.join(parts)


def dis(mem, pci0, start, length):
    base = start - pci0
    out = []
    a = start
    end = pci0 + length
    while a + 8 <= end:
        o = a - pci0
        w0, w1 = struct.unpack_from('<II', mem, o)
        op = w0 >> 30
        size = 8
        if op == 0:
            n = w0 & 0xFFFFFF
            if w0 & (1 << 28):
                s = 'MOVE FROM table+%X, %s' % (n, PHASE[(w0 >> 24) & 7])
            elif w0 & (1 << 29):
                s = 'MOVE %d, %08X (indirect), %s' % (n, w1, PHASE[(w0 >> 24) & 7])
            else:
                s = 'MOVE %d, %08X, %s' % (n, w1, PHASE[(w0 >> 24) & 7])
            s += ' WHEN' if w0 & (1 << 27) else ' WITH'
        elif op == 1:
            k = (w0 >> 27) & 7
            if k == 0:
                tgt = (a + 8 + w1) & 0xFFFFFFFF if w0 & (1 << 26) else w1
                if w0 & (1 << 25):
                    s = 'SELECT%s FROM table+%X, alt %08X' % (' ATN' if w0 & (1 << 24) else '', w0 & 0xFFFFFF, tgt)
                else:
                    s = 'SELECT%s id %d, alt %08X' % (' ATN' if w0 & (1 << 24) else '', (w0 >> 16) & 0xF, tgt)
            elif k == 1:
                s = 'WAIT DISCONNECT'
            elif k == 2:
                tgt = (a + 8 + w1) & 0xFFFFFFFF if w0 & (1 << 26) else w1
                s = 'WAIT RESELECT, alt %08X' % tgt
            elif k in (3, 4):
                b = [n for bit, n in ((3, 'ATN'), (6, 'ACK'), (9, 'TARGET'), (10, 'CARRY')) if w0 & (1 << bit)]
                s = ('SET ' if k == 3 else 'CLEAR ') + ' '.join(b)
            elif k in (5, 6, 7):
                r = (w0 >> 16) & 0x7F
                opn = RMW_OP[(w0 >> 24) & 7]
                d = (w0 >> 8) & 0xFF
                if k == 5:
                    s = '%s SFBR%s -> %s' % (opn, '' if (w0 >> 24) & 7 == 0 else ' %02X' % d, reg(r))
                    if (w0 >> 24) & 7 == 0:
                        s = 'MOVE SFBR -> %s' % reg(r)
                elif k == 6:
                    s = '%s %s%s -> SFBR' % (opn, reg(r), '' if (w0 >> 24) & 7 in (0,) else ' %02X' % d)
                    if (w0 >> 24) & 7 == 0:
                        s = 'MOVE %s -> SFBR' % reg(r)
                else:
                    s = '%s %s %02X -> %s' % (opn, reg(r), d, reg(r)) if (w0 >> 24) & 7 else 'MOVE %02X -> %s' % (d, reg(r))
            else:
                s = '?io %08X' % w0
        elif op == 2:
            k = (w0 >> 27) & 7
            name = ['JUMP', 'CALL', 'RETURN', 'INT', '?4', '?5', '?6', '?7'][k]
            tgt = (a + 8 + ((w1 & 0xFFFFFF) - (0x1000000 if w1 & 0x800000 else 0))) & 0xFFFFFFFF if w0 & (1 << 23) else w1
            if k == 3:
                s = 'INT %08X %s' % (w1, cond(w0))
            elif k == 2:
                s = 'RETURN %s' % cond(w0)
            else:
                s = '%s %08X %s' % (name, tgt, cond(w0))
        else:
            size = 12
            w2 = struct.unpack_from('<I', mem, o + 8)[0] if o + 12 <= length else 0
            if w0 & (1 << 29):
                s = '%s %d bytes, %s%08X, %s' % ('LOAD' if w0 & (1 << 24) else 'STORE', w0 & 7, 'DSA+' if w0 & (1 << 28) else '', w1, reg((w0 >> 16) & 0x7F))
            else:
                s = 'MEMORY MOVE %d bytes %08X -> %08X' % (w0 & 0xFFFFFF, w1, w2)
        words = '%08X %08X' % (w0, w1) + (' %08X' % w2 if size == 12 else '         ')
        out.append('%08X: %s  %s' % (a, words, s))
        a += size
    return out


def main():
    a = sys.argv[1:]
    if not a or '--at' not in a or '--pci' not in a or '--len' not in a:
        print(__doc__); return
    f = a[0]
    at = int(a[a.index('--at') + 1], 0)
    pci = int(a[a.index('--pci') + 1], 0)
    ln = int(a[a.index('--len') + 1], 0)
    start = int(a[a.index('--start') + 1], 0) if '--start' in a else pci
    with open(f, 'rb') as fh:
        fh.seek(at)
        mem = fh.read(ln)
    for l in dis(mem, pci, start, ln):
        print(l)


if __name__ == '__main__':
    main()
