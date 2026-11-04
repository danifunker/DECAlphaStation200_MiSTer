#!/usr/bin/env python3
"""A small Alpha disassembler in plain Python (no binutils needed): the integer, memory, branch,
jump, CALL_PAL and misc instructions, the FP ones by opcode and function code, in GNU syntax.

usage: alphadis.py FILE VA [-o FILEOFF] [-n COUNT] [--base BASE]
  FILE      the binary (a PE: with --pe, VA is a virtual address and the section table maps it)
  VA        the first address to disassemble (hex)
  -n COUNT  instructions (default 32)
  --pe      FILE is a PE image: file offsets come from its section table, --base defaults to
            the image base
  -o OFF    plain file: the file offset of VA (default: VA - BASE)
  --base B  the address of file offset 0 (default 0)
"""
import struct, sys

OP_MEM = {0x08: 'lda', 0x09: 'ldah', 0x0A: 'ldbu', 0x0B: 'ldq_u', 0x0C: 'ldwu', 0x0D: 'stw', 0x0E: 'stb',
          0x0F: 'stq_u', 0x20: 'ldf', 0x21: 'ldg', 0x22: 'lds', 0x23: 'ldt', 0x24: 'stf', 0x25: 'stg',
          0x26: 'sts', 0x27: 'stt', 0x28: 'ldl', 0x29: 'ldq', 0x2A: 'ldl_l', 0x2B: 'ldq_l', 0x2C: 'stl',
          0x2D: 'stq', 0x2E: 'stl_c', 0x2F: 'stq_c'}
OP_BR = {0x30: 'br', 0x31: 'fbeq', 0x32: 'fblt', 0x33: 'fble', 0x34: 'bsr', 0x35: 'fbne', 0x36: 'fbge',
         0x37: 'fbgt', 0x38: 'blbc', 0x39: 'beq', 0x3A: 'blt', 0x3B: 'ble', 0x3C: 'blbs', 0x3D: 'bne',
         0x3E: 'bge', 0x3F: 'bgt'}
OPR = {
    0x10: {0x00: 'addl', 0x02: 's4addl', 0x09: 'subl', 0x0B: 's4subl', 0x0F: 'cmpbge', 0x12: 's8addl',
           0x1B: 's8subl', 0x1D: 'cmpult', 0x20: 'addq', 0x22: 's4addq', 0x29: 'subq', 0x2B: 's4subq',
           0x2D: 'cmpeq', 0x32: 's8addq', 0x3B: 's8subq', 0x3D: 'cmpule', 0x40: 'addl/v', 0x49: 'subl/v',
           0x4D: 'cmplt', 0x60: 'addq/v', 0x69: 'subq/v', 0x6D: 'cmple'},
    0x11: {0x00: 'and', 0x08: 'bic', 0x14: 'cmovlbs', 0x16: 'cmovlbc', 0x20: 'bis', 0x24: 'cmoveq',
           0x26: 'cmovne', 0x28: 'ornot', 0x40: 'xor', 0x44: 'cmovlt', 0x46: 'cmovge', 0x48: 'eqv',
           0x61: 'amask', 0x64: 'cmovle', 0x66: 'cmovgt', 0x6C: 'implver'},
    0x12: {0x02: 'mskbl', 0x06: 'extbl', 0x0B: 'insbl', 0x12: 'mskwl', 0x16: 'extwl', 0x1B: 'inswl',
           0x22: 'mskll', 0x26: 'extll', 0x2B: 'insll', 0x30: 'zap', 0x31: 'zapnot', 0x32: 'mskql',
           0x34: 'srl', 0x36: 'extql', 0x39: 'sll', 0x3B: 'insql', 0x3C: 'sra', 0x52: 'mskwh',
           0x57: 'inswh', 0x5A: 'extwh', 0x62: 'msklh', 0x67: 'inslh', 0x6A: 'extlh', 0x72: 'mskqh',
           0x77: 'insqh', 0x7A: 'extqh'},
    0x13: {0x00: 'mull', 0x20: 'mulq', 0x30: 'umulh', 0x40: 'mull/v', 0x60: 'mulq/v'},
}
MISC = {0x0000: 'trapb', 0x0400: 'excb', 0x4000: 'mb', 0x4400: 'wmb', 0x8000: 'fetch', 0xA000: 'fetch_m',
        0xC000: 'rpcc', 0xE000: 'rc', 0xF000: 'rs', 0xE800: 'ecb', 0xF800: 'wh64'}
PAL = {0x00: 'halt', 0x01: 'cflush', 0x02: 'draina', 0x09: 'cserve', 0x0A: 'swppal', 0x0D: 'wrkgp',
       0x0E: 'wrent', 0x10: 'rdmces', 0x11: 'wrmces', 0x12: 'rdksp', 0x13: 'swpksp', 0x14: 'rdpcr',
       0x15: 'wrpcr', 0x1C: 'rdpsr', 0x1D: 'wrpsr', 0x1E: 'swpctx', 0x1F: 'wrpcr', 0x24: 'rdthread',
       0x30: 'rdcounters', 0x80: 'bpt', 0x81: 'bugchk', 0x82: 'callsys', 0x83: 'callkd', 0x86: 'imb',
       0xAA: 'gentrap', 0xAB: 'rdteb', 0xAC: 'kbpt', 0xAD: 'callkd'}
REG = ['v0', 't0', 't1', 't2', 't3', 't4', 't5', 't6', 't7', 's0', 's1', 's2', 's3', 's4', 's5', 'fp',
       'a0', 'a1', 'a2', 'a3', 'a4', 'a5', 't8', 't9', 't10', 't11', 'ra', 't12', 'at', 'gp', 'sp', 'zero']


def dis(pc, w):
    op = w >> 26; ra = w >> 21 & 31; rb = w >> 16 & 31; rc = w & 31
    if op == 0x00:
        f = w & 0x3FFFFFF
        return 'call_pal %s' % PAL.get(f, '0x%x' % f)
    if op in OP_MEM:
        d = w & 0xFFFF; d -= 0x10000 if d & 0x8000 else 0
        r = ('$f%d' % ra) if 0x20 <= op <= 0x27 else REG[ra]
        return '%s %s,%d(%s)' % (OP_MEM[op], r, d, REG[rb])
    if op == 0x18:
        return MISC.get(w & 0xFFFF, 'misc 0x%x' % (w & 0xFFFF)) + ('' if w & 0xFFFF in (0, 0x400, 0x4000, 0x4400) else ' %s' % REG[ra])
    if op == 0x1A:
        h = w >> 14 & 3
        return '%s %s,(%s),0x%x' % (('jmp', 'jsr', 'ret', 'jsr_coroutine')[h], REG[ra], REG[rb], w & 0x3FFF)
    if op in OP_BR:
        d = w & 0x1FFFFF; d -= 0x200000 if d & 0x100000 else 0
        r = ('$f%d' % ra) if 0x31 <= op <= 0x37 and op != 0x34 else REG[ra]
        return '%s %s,0x%x' % (OP_BR[op], r, (pc + 4 + 4 * d) & 0xFFFFFFFFFFFFFFFF)
    if op in OPR:
        f = w >> 5 & 0x7F; lit = w >> 12 & 1
        b = ('#%d' % (w >> 13 & 0xFF)) if lit else REG[rb]
        return '%s %s,%s,%s' % (OPR[op].get(f, 'op%02x.%02x' % (op, f)), REG[ra], b, REG[rc])
    if op in (0x14, 0x15, 0x16, 0x17):
        f = w >> 5 & 0x7FF
        names = {0x17: {0x020: 'cpys', 0x021: 'cpysn', 0x022: 'cpyse', 0x024: 'mt_fpcr', 0x025: 'mf_fpcr',
                        0x02A: 'fcmoveq', 0x02B: 'fcmovne', 0x02C: 'fcmovlt', 0x02D: 'fcmovge', 0x02E: 'fcmovle',
                        0x02F: 'fcmovgt', 0x010: 'cvtlq', 0x030: 'cvtql'}}.get(op, {})
        return '%s $f%d,$f%d,$f%d' % (names.get(f, 'fop%02x.%03x' % (op, f)), ra, rb, rc)
    if op in (0x19, 0x1B, 0x1D, 0x1E, 0x1F):
        return {0x19: 'hw_mfpr', 0x1B: 'hw_ld', 0x1D: 'hw_mtpr', 0x1E: 'hw_rei', 0x1F: 'hw_st'}[op] + ' %s,0x%x(%s)' % (REG[ra], w & 0xFFFF, REG[rb])
    return 'op%02x 0x%08x' % (op, w)


def pe_map(d):
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    nsec, optsz = struct.unpack_from('<H', d, pe + 6)[0], struct.unpack_from('<H', d, pe + 20)[0]
    base = struct.unpack_from('<I', d, pe + 24 + 28)[0]
    secs = []
    for i in range(nsec):
        s = pe + 24 + optsz + 40 * i
        vsz, va, rsz, rp = struct.unpack_from('<IIII', d, s + 8)
        secs.append((va, max(vsz, rsz), rp))
    return base, secs


def main():
    a = sys.argv[1:]
    f = a[0]; va = int(a[1], 16); n = 32; off = None; base = 0; pe = False
    i = 2
    while i < len(a):
        if a[i] == '-n': n = int(a[i + 1]); i += 2
        elif a[i] == '-o': off = int(a[i + 1], 16); i += 2
        elif a[i] == '--base': base = int(a[i + 1], 16); i += 2
        elif a[i] == '--pe': pe = True; i += 1
        else: sys.exit(__doc__)
    d = open(f, 'rb').read()
    if pe:
        base, secs = pe_map(d)
        rva = va - base
        for sva, ssz, srp in secs:
            if sva <= rva < sva + ssz: off = rva - sva + srp; break
        else: sys.exit('VA %x is in no section' % va)
    elif off is None:
        off = va - base
    for k in range(n):
        w = struct.unpack_from('<I', d, off + 4 * k)[0]
        print('%08x  %08x  %s' % (va + 4 * k, w, dis(va + 4 * k, w)))


if __name__ == '__main__':
    main()
