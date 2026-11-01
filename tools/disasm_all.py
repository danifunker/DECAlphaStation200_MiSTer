#!/usr/bin/env python3
"""
disasm_all.py - produce annotated EV4 disassembly listings of every AlphaStation 200
firmware image in scratch/roms/.

Requires a GNU objdump with Alpha support (Debian/Ubuntu: binutils-alpha-linux-gnu; macOS: brew install binutils).
Run from the repo root:  python3 -I tools/disasm_all.py

Annotations added to objdump's output:
  * region headers (ROM header, decompressor stub, compressed payload, PALcode, console)
  * EV4 PALcode entry-point labels (21064 HRM Table 4-1/4-2) at each PAL base
  * EV4 IPR names for HW_MFPR / HW_MTPR (21064 HRM Table 4-7)
  * absolute constants built by LDAH/LDA pairs: value, printable ASCII, string at that address
Also writes <name>.strings.txt (address-sorted printable strings, >= 5 chars).
"""
import os, re, struct, subprocess, sys

def _find_objdump():
    """Locate a GNU objdump that can decode Alpha: $OBJDUMP, a cross objdump, binutils-multiarch, or Homebrew."""
    import shutil
    for c in [os.environ.get('OBJDUMP'), 'alpha-linux-gnu-objdump', 'multiarch-objdump',
              '/opt/homebrew/opt/binutils/bin/objdump', 'gobjdump', 'objdump']:
        if not c:
            continue
        p = shutil.which(c) or (c if os.path.isfile(c) else None)
        if p and 'alpha' in subprocess.run([p, '-i'], capture_output=True, text=True).stdout:
            return p
    sys.exit('No Alpha-capable objdump found: install binutils-alpha-linux-gnu (or binutils-multiarch), or set $OBJDUMP')

OBJDUMP = _find_objdump()
OUT = 'scratch/disasm'
K32 = 0xffffffff80000000  # NT/ARC 32-bit superpage base

PAL_ENTRIES = {0x0000: 'RESET', 0x0020: 'MCHK', 0x0060: 'ARITH', 0x00E0: 'INTERRUPT',
               0x01E0: 'D_FAULT', 0x03E0: 'ITB_MISS', 0x07E0: 'ITB_ACV', 0x08E0: 'DTB_MISS_NATIVE',
               0x09E0: 'DTB_MISS_PAL', 0x11E0: 'UNALIGN', 0x13E0: 'OPCDEC', 0x17E0: 'FEN'}
for i in range(128):  # CALL_PAL: 0x2000 + bit7<<12 + bits5..0<<6
    fn = (i & 0x3f) | ((i & 0x40) << 1)
    PAL_ENTRIES[0x2000 + (i << 6)] = f'CALL_PAL_{fn:02X}' + ('' if fn < 0x80 else ' (unprivileged)')

IBOX = {0: 'TB_TAG', 1: 'ITB_PTE', 2: 'ICCSR', 3: 'ITB_PTE_TEMP', 4: 'EXC_ADDR', 5: 'SL_RCV', 6: 'ITBZAP',
        7: 'ITBASM', 8: 'ITBIS', 9: 'PS', 10: 'EXC_SUM', 11: 'PAL_BASE', 12: 'HIRR', 13: 'SIRR',
        14: 'ASTRR', 16: 'HIER', 17: 'SIER', 18: 'ASTER', 19: 'SL_CLR', 22: 'SL_XMIT'}
ABOX = {0: 'TB_CTL', 2: 'DTB_PTE', 3: 'DTB_PTE_TEMP', 4: 'MM_CSR', 5: 'VA', 6: 'DTBZAP', 7: 'DTBASM',
        8: 'DTBIS', 9: 'BIU_ADDR', 10: 'BIU_STAT', 12: 'DC_STAT', 13: 'FILL_ADDR', 14: 'ABOX_CTL',
        15: 'ALT_MODE', 16: 'CC', 17: 'CC_CTL/DC_CTL', 18: 'BIU_CTL', 19: 'FILL_SYNDROME', 20: 'BC_TAG',
        21: 'FLUSH_IC', 23: 'FLUSH_IC_ASM'}

# AS200 physical addresses worth naming when they show up as constants
HW = [(0x100000000, 'flashbus index reg'), (0x100100000, 'flashbus data reg'),
      (0x180000000, '21071-CA CSRs'), (0x1A0000000, '21071-DA CSRs'), (0x1C0000000, 'PCI sparse I/O'),
      (0x1E0000000, 'PCI config space'), (0x200000000, 'PCI sparse mem'), (0x300000000, 'PCI dense mem')]

def ipr_note(ins):
    op = ins >> 26
    if op not in (0x19, 0x1d):
        return ''
    idx, pal, abx, ibx = ins & 0x1f, (ins >> 7) & 1, (ins >> 6) & 1, (ins >> 5) & 1
    names = []
    if ibx: names.append('I:' + IBOX.get(idx, f'?{idx}'))
    if abx: names.append('A:' + ABOX.get(idx, f'?{idx}'))
    if pal: names.append(f'PAL_TEMP{idx}')
    return ' '.join(names) if names else 'nop (no box selected)'

def sext16(v): return v - 0x10000 if v & 0x8000 else v

def load_strings(data, vma, minlen=5):
    res = {}
    for m in re.finditer(rb'[\x20-\x7e\t\r\n]{%d,}' % minlen, data):
        s = m.group().decode('latin1').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
        res[vma + m.start()] = s
    return res

def disasm(name, path, vma, regions, palbases=(), skip=()):
    data = open(path, 'rb').read()
    strings = load_strings(data, vma)
    os.makedirs(OUT, exist_ok=True)
    with open(f'{OUT}/{name}.strings.txt', 'w') as f:
        f.write(f'# printable strings in {path} (address = load address {vma:#x} + file offset)\n')
        for a, s in sorted(strings.items()):
            f.write(f'{a & 0xffffffffffffffff:016x}  {s}\n')
    labels = {}
    for base, tag in palbases:
        for off, nm in PAL_ENTRIES.items():
            labels[base + off] = f'{tag} PAL entry {nm} (PAL_BASE+{off:#06x})'
    for a, e, txt in regions:
        labels.setdefault(a, '')
        labels[a] = (f'===== REGION {a & 0xffffffffffffffff:#x}-{e & 0xffffffffffffffff:#x}: {txt} =====\n; ' + labels[a]).rstrip('; ')
    cmd = [OBJDUMP, '-D', '-b', 'binary', '-m', 'alpha:ev4', f'--adjust-vma={vma:#x}']
    lines = subprocess.run(cmd + [path], capture_output=True, text=True, check=True).stdout.splitlines()
    skip_ranges = [(a, b, why) for a, b, why in skip]
    rx = re.compile(r'^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} ){4})\s*(.*)$')
    lo_val = {}   # reg -> (value from lda r,x(zero))
    hi_val = {}   # reg -> value from ldah r,x(zero)
    out = open(f'{OUT}/{name}.dis.txt', 'w')
    out.write(f'; {name}: {path}\n; load address {vma & 0xffffffffffffffff:#x}, EV4 (21064) disassembly by GNU objdump, annotated by tools/disasm_all.py\n')
    out.write('; register names are OSF/1 software names (v0=r0 t0-t7=r1-r8 s0-s5=r9-r14 fp=r15 a0-a5=r16-r21 t8-t11=r22-r25 ra=r26 t12/pv=r27 at=r28 gp=r29 sp=r30 zero=r31)\n')
    skipping = None
    for ln in lines:
        m = rx.match(ln)
        if not m:
            if ln.strip() == '...' and not skipping:
                out.write('                  ...       (run of zero words)\n')
            continue
        addr = int(m.group(1), 16)
        sk = next(((a, b, w) for a, b, w in skip_ranges if a <= addr < b), None)
        if sk:
            if skipping != sk:
                out.write(f'\n; ----- {sk[0]:#x}-{sk[1]:#x} not disassembled: {sk[2]} -----\n')
                skipping = sk
            continue
        skipping = None
        if addr in labels:
            out.write(f'\n; {labels[addr]}\n')
            lo_val.clear(); hi_val.clear()
        b = bytes(int(x, 16) for x in m.group(2).split())
        ins = struct.unpack('<I', b)[0]
        text = m.group(3).strip()
        notes = []
        n = ipr_note(ins)
        if n:
            notes.append(n)
        op, ra, rb, disp = ins >> 26, (ins >> 21) & 31, (ins >> 16) & 31, sext16(ins & 0xffff)
        val = None
        if op == 0x08:  # lda
            if rb == 31:
                lo_val[ra] = disp; hi_val.pop(ra, None)
            elif rb == ra and ra in hi_val:
                val = hi_val.pop(ra) + disp
            else:
                lo_val.pop(ra, None); hi_val.pop(ra, None)
        elif op == 0x09:  # ldah
            if rb == 31:
                hi_val[ra] = disp << 16; lo_val.pop(ra, None)
            elif rb == ra and ra in lo_val:
                val = lo_val.pop(ra) + (disp << 16)
            else:
                lo_val.pop(ra, None); hi_val.pop(ra, None)
        if val is not None:
            u = val & 0xffffffffffffffff
            note = f'= {u:#x}'
            asc = struct.pack('<q', val)[:4]
            if all(32 <= c < 127 for c in asc):
                note += f' "{asc.decode()}"'
            if u in strings:
                note += f' (if address) -> "{strings[u][:60]}"'
            for hwa, hwn in HW:
                if hwa <= (u & 0x3ffffffff) < hwa + 0x20000000 and u > 0xffffffff:
                    note += f' [{hwn}]'
            notes.append(note)
        if ins == 0:
            text = 'halt  (0x00000000)'
        s = f'{addr & 0xffffffffffffffff:016x}:  {ins:08x}  {text}'
        if notes:
            s = f'{s:<64} ; ' + '; '.join(notes)
        out.write(s + '\n')
    out.close()
    print(f'{name}: {path} -> {OUT}/{name}.dis.txt, {len(strings)} strings')

def find(data, pat, start=0):
    i = data.find(pat, start)
    return i

def main():
    R = 'scratch/roms'
    # --- raw flash/ROM images ---
    disasm('drom_v1.2', f'{R}/flash/drom_v1.2.bin', 0,
           [(0, 0x40, 'DEC ROM header (data)'), (0x40, 0x10000, 'DROM code (runs in PALmode; load address not yet known, addresses = ROM offset)')],
           skip=[(0, 0x40, 'ROM header')])
    for nm, f in [('srm_v6.4-1', 'srm_v6.4-1.img'), ('srm_v6.9-4', 'srm_v6.9-4.img'), ('srm_v7.0-9', 'srm_v7.0-9.img')]:
        d = open(f'{R}/flash/{f}', 'rb').read(); w = d.find(b'WimC')
        v = 0x400000 - 0x40
        disasm(f'{nm}_flash_stub', f'{R}/flash/{f}', v,
               [(v, v + 0x40, 'DEC ROM header'), (v + 0x40, v + w, 'self-relocating decompressor stub (runs at 0x400000, PALmode)'),
                (v + w, v + len(d), 'WimC header + DEFLATE payload (decompresses to 0x8000)')],
               skip=[(v, v + 0x40, 'ROM header'), (v + w, v + len(d), 'compressed payload - see scratch/roms/extracted/')])
    for nm, f in [('arc_v4.49', 'arc_v4.49.img'), ('arc_v4.57', 'arc_v4.57.img'), ('arc_v4.58', 'arc_v4.58.img')]:
        d = open(f'{R}/flash/{f}', 'rb').read(); w = d.find(b'WimC')
        v = K32 + 0x100000 - 0x40
        disasm(f'{nm}_flash_stub', f'{R}/flash/{f}', v,
               [(v, v + 0x40, 'DEC ROM header'), (v + 0x40, v + w, 'ARC loader/decompressor stub (PA 0x100000 = VA 0x80100000)'),
                (v + w, v + len(d), 'WimC header + DEFLATE payload (decompresses to PA 0x700000)')],
               skip=[(v, v + 0x40, 'ROM header'), (v + w, v + len(d), 'compressed payload - see scratch/roms/extracted/')])
    # --- outer stub of the update-utility .exe images (same stub as SRM flash image, no ROM header) ---
    for nm, f in [('apu_v7.0_exe_stub', 'as200_v7_0.exe'), ('apu_v6.9_exe_stub', 'AS200_V6_9.EXE'),
                  ('arcboot_exe_stub', 'arcboot.exe'), ('pci_update_v1.4_exe_stub', 'as200_pci_v1_4.exe')]:
        p = f'{R}/dec_firmware_v7.0/{f}'; d = open(p, 'rb').read(); w = d.find(b'WimC')
        disasm(nm, p, 0x400000, [(0x400000, 0x400000 + w, 'decompressor stub'), (0x400000 + w, 0x400000 + len(d), 'compressed payload')],
               skip=[(0x400000 + w, 0x400000 + len(d), 'compressed payload - see scratch/roms/extracted/')])
    # --- decompressed images ---
    X = f'{R}/extracted'
    for nm in ['srm_v6.4-1', 'srm_v6.9-4', 'srm_v7.0-9', 'apu_v7.0_update_utility', 'apu_v6.9_update_utility',
               'pci_update_v1.4', 'arcboot']:
        p = f'{X}/{nm}.load_0x8000.bin'; d = open(p, 'rb').read()
        regions = [(0x8000, 0x14000, 'VMS PALcode (PAL_BASE=0x8000; RESET is the image entry point)'),
                   (0x14000, 0x1c000, 'OSF PALcode (PAL_BASE=0x14000)'),
                   (0x1c000, 0x8000 + len(d), 'console / application code and data')]
        skip = []
        o = 0
        while True:  # embedded flashable ROM images inside update utilities
            o = d.find(b'\x01\x01\x00\x00\x55\x00\xaa\xff', o)
            if o < 0: break
            w = d.find(b'WimC', o); clen = struct.unpack_from('<I', d, w + 4)[0]
            end = w + clen + 0x20
            nmx = d[o + 0x30:o + 0x3c].split(b'\0')[0].decode(); ver = d[o + 8:o + 0x10].split(b'\0')[0].decode()
            skip.append((0x8000 + o, 0x8000 + end, f'embedded flash image {nmx} {ver} (compressed) - see scratch/roms/flash/'))
            o = end
        disasm(nm, p, 0x8000, regions, palbases=[(0x8000, 'VMS'), (0x14000, 'OSF')], skip=skip)
    for nm in ['arc_v4.49', 'arc_v4.57', 'arc_v4.58', 'arcboot_inner_arc']:
        p = f'{X}/{nm}.load_0x700000.bin'; d = open(p, 'rb').read()
        v = K32 + 0x700000
        disasm(nm, p, v, [(v, v + len(d), 'ARC console (PA 0x700000, runs at VA 0x80700000 via 32-bit superpage)')])

if __name__ == '__main__':
    main()
