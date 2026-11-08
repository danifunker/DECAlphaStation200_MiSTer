#!/usr/bin/env python3
"""Decode a board SCRIPTS trace (OSD Serial port = TGA trace, ncr53c810.v's E3F0t lines).

  ncrtrace.py LOG [--all]      the interrupts (E3F02), host writes (E3F03) and bus changes (E3F04),
                               with the status bits named; --all also prints the fetches (E3F01)

Lines: E3F01 DSP DCMD|DBC (a fetch); E3F02 DSP {DSTAT, SIST0, SIST1, ISTAT}; E3F03 DSP {be, reg,
data[15:0]}; E3F04 DSP {sfbr, flags, target state, CDB opcode}: flags = {selecting, con, atn, ackhold, bsy,
phase[2:0]}. "Dnnnnnnnn" lines are dropped events (the ring overflowed).
"""
import sys

DSTAT = {0x80: 'DFE', 0x40: 'MDPE', 0x20: 'BF', 0x10: 'ABRT', 0x08: 'SSI', 0x04: 'SIR', 0x01: 'IID'}
SIST0 = {0x80: 'M/A', 0x40: 'CMP', 0x20: 'SEL', 0x10: 'RSL', 0x08: 'SGE', 0x04: 'UDC', 0x02: 'RST', 0x01: 'PAR'}
SIST1 = {0x04: 'STO', 0x02: 'GEN', 0x01: 'HTH'}
ISTAT = {0x80: 'ABRT', 0x40: 'SRST', 0x20: 'SIGP', 0x10: 'SEM', 0x08: 'CON', 0x04: 'INTF', 0x02: 'SIP', 0x01: 'DIP'}
PHASE = ['DOUT', 'DIN', 'CMD', 'STAT', '?4', '?5', 'MOUT', 'MIN']
# scsi_targets.v's states (the trace carries them in hex)
TGT = {0: 'FREE', 1: 'MOUT', 2: 'MIN', 3: 'CMD', 4: 'EXEC', 5: 'DIN', 6: 'DOUT', 7: 'FETCH', 8: 'STORE', 9: 'STAT',
       10: 'DONE', 11: 'DISC', 12: 'TOC', 13: 'TOCW', 14: 'TOCCP', 15: 'TOCFK', 16: 'TRK', 17: 'PRE1', 18: 'PRE2',
       19: 'DLEN', 20: 'PLAY', 21: 'DMSG', 22: 'RSEL', 23: 'RMSG'}
REG = {0x00: 'SCNTL0', 0x01: 'SCNTL1', 0x02: 'SCNTL2', 0x03: 'SCNTL3', 0x04: 'SCID', 0x05: 'SXFER', 0x06: 'SDID',
       0x07: 'GPREG', 0x08: 'SFBR', 0x09: 'SOCL', 0x0A: 'SSID', 0x0B: 'SBCL', 0x0C: 'DSTAT', 0x0D: 'SSTAT0',
       0x0E: 'SSTAT1', 0x0F: 'SSTAT2', 0x10: 'DSA', 0x14: 'ISTAT', 0x18: 'CTEST0', 0x19: 'CTEST1', 0x1A: 'CTEST2',
       0x1B: 'CTEST3', 0x1C: 'TEMP', 0x20: 'DFIFO', 0x21: 'CTEST4', 0x22: 'CTEST5', 0x23: 'CTEST6', 0x24: 'DBC',
       0x27: 'DCMD', 0x28: 'DNAD', 0x2C: 'DSP', 0x30: 'DSPS', 0x34: 'SCRATCHA', 0x38: 'DMODE', 0x39: 'DIEN',
       0x3A: 'DWT', 0x3B: 'DCNTL', 0x3C: 'ADDER', 0x40: 'SIEN0', 0x41: 'SIEN1', 0x42: 'SIST0', 0x43: 'SIST1',
       0x44: 'SLPAR', 0x46: 'MACNTL', 0x47: 'GPCNTL', 0x48: 'STIME0', 0x49: 'STIME1', 0x4A: 'RESPID',
       0x4C: 'STEST0', 0x4D: 'STEST1', 0x4E: 'STEST2', 0x4F: 'STEST3', 0x50: 'SIDL', 0x54: 'SODL', 0x58: 'SBDL',
       0x5C: 'SCRATCHB'}


def bits(v, names):
    return '|'.join(n for b, n in names.items() if v & b) or '-'


def main():
    import io; sys.stdout = io.TextIOWrapper(sys.stdout.buffer, errors='replace')
    allf = '--all' in sys.argv
    n = 0
    for line in open(sys.argv[1], 'rb'):
        line = line.decode('latin-1').strip()
        n += 1
        if line.startswith('D'):
            if allf: print('%7d  dropped' % n)
            continue
        p = line.split()
        if len(p) != 3 or not p[0].startswith('E3F0'): continue
        try: dsp, w = int(p[1], 16), int(p[2], 16)
        except ValueError: continue
        t = p[0][4]
        if t == '1':
            if allf: print('%7d  fetch %08X  %08X' % (n, dsp, w))
        elif t == '2':
            print('%7d  INT   %08X  DSTAT %s  SIST0 %s  SIST1 %s  ISTAT %s' % (
                n, dsp, bits(w >> 24, DSTAT), bits((w >> 16) & 0xFF, SIST0), bits((w >> 8) & 0xFF, SIST1), bits(w & 0xFF, ISTAT)))
        elif t == '3':
            be, reg, data = w >> 24, (w >> 16) & 0xFF, w & 0xFFFF
            name = REG.get(reg & 0x7C if reg >= 0x10 else reg, '%02X' % reg)
            print('%7d  write %08X  %s(%02X) be %X = %04X%s' % (n, dsp, name, reg, be, data,
                  '  ** SCSI RESET' if reg == 0x01 and data & 0x08 else ''))
        elif t == '4':
            sfbr, f, st, op = w >> 24, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF
            fl = ('sel ' if f & 0x80 else '') + ('con ' if f & 0x40 else '') + ('atn ' if f & 0x20 else '') + \
                 ('ackhold ' if f & 0x10 else '') + ('bsy ' if f & 0x08 else '')
            print('%7d  bus   %08X  %s%s  target st %02X %-5s cdb %02X  sfbr %02X' % (n, dsp, fl, PHASE[f & 7], st, TGT.get(st, '?'), op, sfbr))


if __name__ == '__main__':
    main()
