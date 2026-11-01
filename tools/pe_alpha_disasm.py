#!/usr/bin/env python3
"""
pe_alpha_disasm.py - annotated disassembly of Windows NT for Alpha (AXP32) binaries.

Handles PE images (MZ + "PE\\0\\0", machine 0x184) and the raw COFF "ROM" images that
ARC loads directly (osloader.exe, SETUPLDR: no MZ stub, optional-header magic 0x107).

Per input file writes, into <outdir>:
  <name>.dis.txt      disassembly of every executable section, with
                        - function labels from .pdata (the Alpha NT function table:
                          begin/end/handler/handler-data/prolog-end), exports, entry point
                        - import names for loads from the IAT  (ldah rX,hi ; ldl rY,lo(rX))
                        - absolute addresses resolved to labels / ASCII or UTF-16 strings
                        - bsr/br targets named when they hit a known function
  <name>.info.txt     headers, sections, imports, exports, function table
  <name>.strings.txt  ASCII and UTF-16LE strings with virtual addresses

Requires a GNU objdump with Alpha support (Debian/Ubuntu: binutils-alpha-linux-gnu; macOS: brew install binutils).
Usage: pe_alpha_disasm.py <outdir> <file>...
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

class Image:
    def __init__(self, path):
        self.path = path
        d = self.data = open(path, 'rb').read()
        if d[:2] == b'MZ':
            pe = struct.unpack_from('<I', d, 0x3c)[0]
            assert d[pe:pe + 4] == b'PE\0\0', 'not PE'
            coff = pe + 4
            self.kind = 'PE'
        else:
            coff = 0
            self.kind = 'COFF-ROM'
        (self.machine, nsec, self.timestamp, _, _, optsz, self.chars) = struct.unpack_from('<HHIIIHH', d, coff)
        assert self.machine == 0x184, f'machine {self.machine:#x} is not Alpha'
        opt = coff + 20
        self.magic = struct.unpack_from('<H', d, opt)[0]
        self.dirs = []
        if self.magic == 0x10b:
            self.entry_rva = struct.unpack_from('<I', d, opt + 16)[0]
            self.base = struct.unpack_from('<I', d, opt + 28)[0]
            ndirs = struct.unpack_from('<I', d, opt + 92)[0]
            self.dirs = [struct.unpack_from('<II', d, opt + 96 + 8 * i) for i in range(ndirs)]
        elif self.magic == 0x107:   # ROM optional header: entry and bases are absolute
            entry = struct.unpack_from('<I', d, opt + 16)[0]
            self.base = 0
            self.entry_rva = entry
        else:
            raise ValueError(f'unknown optional header magic {self.magic:#x}')
        self.secs = []
        so = opt + optsz
        for i in range(nsec):
            name, vsize, va, rsize, rptr, _, _, _, _, ch = struct.unpack_from('<8sIIIIIIHHI', d, so + 40 * i)
            name = name.rstrip(b'\0').decode('latin1')
            if self.kind == 'COFF-ROM':
                vsize = vsize or rsize   # ROM images: s_paddr/s_vaddr carry the address
            self.secs.append(dict(name=name, vsize=vsize, va=va, rsize=rsize, rptr=rptr, ch=ch))

    def va(self, rva): return (self.base + rva) & 0xffffffff
    def sec_of(self, rva):
        for s in self.secs:
            if s['va'] <= rva < s['va'] + max(s['vsize'], s['rsize']):
                return s
    def read(self, rva, n):
        s = self.sec_of(rva)
        if not s: return b''
        o = rva - s['va']
        if o >= s['rsize']: return b'\0' * n
        return self.data[s['rptr'] + o: s['rptr'] + min(o + n, s['rsize'])]
    def u32(self, rva):
        b = self.read(rva, 4)
        return struct.unpack('<I', b.ljust(4, b'\0'))[0]
    def cstr(self, rva, n=256):
        b = self.read(rva, n)
        return b.split(b'\0')[0].decode('latin1')

    def imports(self):
        res = {}   # IAT va -> "dll!name"
        if len(self.dirs) < 2 or not self.dirs[1][0]: return res
        rva = self.dirs[1][0]
        while True:
            oft, _, _, name_rva, ft = struct.unpack('<IIIII', self.read(rva, 20).ljust(20, b'\0'))
            if not name_rva: break
            dll = self.cstr(name_rva)
            src = oft or ft
            i = 0
            while True:
                t = self.u32(src + 4 * i)
                if not t: break
                nm = f'#{t & 0xffff}' if t & 0x80000000 else self.cstr(t + 2)
                res[self.va(ft + 4 * i)] = f'{dll}!{nm}'
                i += 1
            rva += 20
        return res

    def exports(self):
        res = {}
        if not self.dirs or not self.dirs[0][0]: return res
        e = self.dirs[0][0]
        _, _, _, _, name_rva, ordbase, nfunc, nname, af, an, ao = struct.unpack('<IIHHIIIIIII', self.read(e, 40))
        names = {}
        for i in range(nname):
            names[struct.unpack('<H', self.read(ao + 2 * i, 2))[0]] = self.cstr(self.u32(an + 4 * i))
        for i in range(nfunc):
            f = self.u32(af + 4 * i)
            if f: res[self.va(f)] = names.get(i, f'ord{ordbase + i}')
        return res

    def pdata(self):
        """Alpha function table entries (begin, end, handler, data, prolog_end) as VAs."""
        res = []
        rva = size = 0
        if len(self.dirs) > 3 and self.dirs[3][0]:
            rva, size = self.dirs[3]
        else:
            for s in self.secs:
                if s['name'] == '.pdata':
                    rva, size = s['va'] - self.base if self.kind == 'COFF-ROM' else s['va'], s['vsize']
        if not size: return res
        for i in range(size // 20):
            ent = struct.unpack('<5I', self.read(rva + 20 * i, 20).ljust(20, b'\0'))
            if ent[0]: res.append(ent)
        return res

def strings(img):
    out = {}
    for s in img.secs:
        if s['ch'] & 0x20 and not s['ch'] & 0x40: continue   # skip pure code
        b = img.data[s['rptr']: s['rptr'] + s['rsize']]
        base = img.va(s['va']) if img.kind == 'PE' else s['va']
        for m in re.finditer(rb'[\x20-\x7e\t\r\n]{5,}', b):
            out[base + m.start()] = m.group().decode('latin1')
        for m in re.finditer(rb'(?:[\x20-\x7e]\x00){5,}', b):
            out.setdefault(base + m.start(), 'L"' + m.group().decode('utf-16le') + '"')
    return out

def sext16(v): return v - 0x10000 if v & 0x8000 else v

def dest_reg(ins):
    op = ins >> 26
    if op in (0x08, 0x09, 0x0b, 0x28, 0x29, 0x2a, 0x2b, 0x1a, 0x30, 0x34, 0x19, 0x18): return (ins >> 21) & 31
    if op in (0x10, 0x11, 0x12, 0x13): return ins & 31
    return None

def disasm(img, outdir, name):
    imps, exps, pdata, strs = img.imports(), img.exports(), img.pdata(), strings(img)
    labels = {}
    for b, e, h, hd, pe_ in pdata:
        labels[b] = f'func_{b:08x}'
    for a, n in exps.items(): labels[a] = n
    entry = img.va(img.entry_rva) if img.kind == 'PE' else img.entry_rva
    labels.setdefault(entry, 'EntryPoint')
    labels[entry] = labels[entry] + ' [entry point]'
    known = dict(labels); known.update(imps)

    with open(f'{outdir}/{name}.strings.txt', 'w') as f:
        for a, s in sorted(strs.items()):
            f.write(f'{a:08x}  {s!r}\n')
    with open(f'{outdir}/{name}.info.txt', 'w') as f:
        f.write(f'{img.path}\nformat {img.kind}, optional-header magic {img.magic:#x}, image base {img.base:#x}, entry {entry:#x}, timestamp {img.timestamp:#x}\n\nSections:\n')
        for s in img.secs:
            f.write(f"  {s['name']:8s} va={s['va']:#010x} vsize={s['vsize']:#x} raw={s['rptr']:#x}+{s['rsize']:#x} flags={s['ch']:#010x}\n")
        f.write(f'\nImports ({len(imps)}):\n')
        for a, n in sorted(imps.items(), key=lambda x: x[1]): f.write(f'  IAT {a:#010x}  {n}\n')
        f.write(f'\nExports ({len(exps)}):\n')
        for a, n in sorted(exps.items()): f.write(f'  {a:#010x}  {n}\n')
        f.write(f'\nFunction table (.pdata, {len(pdata)} entries): begin end handler handler_data prolog_end\n')
        for ent in pdata: f.write('  ' + ' '.join(f'{x:08x}' for x in ent) + '\n')

    out = open(f'{outdir}/{name}.dis.txt', 'w')
    out.write(f'; {name}: {img.path}\n; {img.kind}, image base {img.base:#x}, entry {entry:#x}; {len(pdata)} functions (.pdata), {len(imps)} imports, {len(exps)} exports\n')
    out.write('; register names: OSF/1 software names (NT Alpha uses the same calling convention: a0-a5 args, v0 result, ra return, sp stack)\n')
    ends = {b: e for b, e, *_ in pdata}
    rx = re.compile(r'^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} ){4})\s*(.*)$')
    for s in img.secs:
        if not s['ch'] & 0x20 or not s['rsize']: continue
        start = img.va(s['va']) if img.kind == 'PE' else s['va']
        blob = img.data[s['rptr']: s['rptr'] + s['rsize']]
        tmp = f'{outdir}/.sec.bin'
        open(tmp, 'wb').write(blob)
        lines = subprocess.run([OBJDUMP, '-D', '-z', '-b', 'binary', '-m', 'alpha:ev4', f'--adjust-vma={start:#x}', tmp],
                               capture_output=True, text=True, check=True).stdout.splitlines()
        os.remove(tmp)
        out.write(f"\n; ===== section {s['name']} {start:#010x}-{start + s['rsize']:#010x} =====\n")
        hi = {}
        for ln in lines:
            m = rx.match(ln)
            if not m: continue
            a = int(m.group(1), 16)
            if a in labels:
                e = ends.get(a)
                out.write(f'\n{labels[a]}:' + (f'    ; .pdata {a:#x}-{e:#x}' if e else '') + '\n')
                hi.clear()
            ins = struct.unpack('<I', bytes(int(x, 16) for x in m.group(2).split()))[0]
            text = m.group(3).strip()
            op, ra, rb, disp = ins >> 26, (ins >> 21) & 31, (ins >> 16) & 31, sext16(ins & 0xffff)
            note = None
            if op == 0x09 and rb == 31:
                hi[ra] = (disp << 16) & 0xffffffff
            elif op in (0x08, 0x0b, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f) and rb in hi:
                tgt = (hi[rb] + disp) & 0xffffffff
                if tgt in known:
                    note = ('imp ' if tgt in imps else '') + known[tgt]
                elif tgt in strs:
                    note = f'{tgt:#x} -> {strs[tgt][:70]!r}'
                else:
                    note = f'= {tgt:#x}'
            elif op in (0x30, 0x34) or (op >= 0x38):
                t = (a + 4 + (((ins & 0x1fffff) ^ 0x100000) - 0x100000) * 4) & 0xffffffff
                if t in labels and op in (0x30, 0x34): note = f'-> {labels[t]}'
            d = dest_reg(ins)
            if d is not None and d != 31 and not (op == 0x09 and rb == 31):
                hi.pop(d, None)
            line = f'{a:08x}:  {ins:08x}  {text}'
            if note: line = f'{line:<62} ; {note}'
            out.write(line + '\n')
    out.close()
    return len(pdata), len(imps), len(exps), len(strs)

def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    for p in sys.argv[2:]:
        try:
            img = Image(p)
        except (AssertionError, ValueError, struct.error) as e:
            print(f'skip {p}: {e}'); continue
        n = disasm(img, outdir, os.path.basename(p))
        print(f'{os.path.basename(p):14s} {img.kind:8s} funcs={n[0]:5d} imports={n[1]:4d} exports={n[2]:4d} strings={n[3]:5d}')

if __name__ == '__main__':
    main()
