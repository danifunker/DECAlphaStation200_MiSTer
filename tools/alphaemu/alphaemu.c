/*
 * alphaemu - minimal Alpha (EV4, no BWX) integer interpreter.
 *
 * Purpose: run DEC firmware self-decompressing stubs ("WimC" images) offline
 * to recover the decompressed SRM / ARC / update-utility images.
 * It is also a starting point for a reference model of the 21064 core.
 *
 * Model: flat physical memory, PAL mode, VA == PA (masked to 34 bits).
 *   HW_MFPR returns 0, HW_MTPR is ignored, CALL_PAL and HW_REI stop execution.
 *   Addresses 0xFFFFFFFF8xxxxxxx (NT superpage) map to PA 0x0xxxxxxx.
 *   Execution stops when PC leaves [stop_lo, stop_hi) - normally the address
 *   range the stub was loaded into - so the jump into the freshly
 *   decompressed image is caught and reported.
 *
 * Usage:
 *   alphaemu -l <file>@<fileoff>:<addr>[:len] ... -p <start_pc>
 *            [-s lo:hi] [-d <addr>:<len>:<outfile>]... [-m <memMB>] [-n maxinsn]
 *            [-r reg=value]... [-t trace_count]
 *   alphaemu -e <elf> [-m <memMB>] [-n maxinsn] [-T tracefile]
 *
 * -e runs a static Alpha Linux ELF (the T0 CPU tests, tests/cpu) as a user
 * program: its segments are loaded at their virtual addresses (memory is
 * the window [lowest segment, +memMB)), the stack is at the top, and
 * CALL_PAL callsys handles exit (1) and write (4). The exit status is the
 * program's.
 *
 * -P (PAL harness, the T0 bare-metal images): HW_MTPR/HW_MFPR keep a
 * 256-entry IPR array indexed by the instruction's low byte (only EXC_ADDR,
 * 0x24, matters), HW_REI continues at EXC_ADDR & ~3 instead of stopping,
 * and PC is not checked against the load window (KSEG addresses map to
 * PA = VA[33:0] like every other address). -H <pa> stops on a store to
 * that physical address: value 1 = exit 0, anything else = exit 1.
 *
 * -T writes one line per retired instruction for lockstep comparison with
 * the RTL: "<pc> <insn> [r<n>=<value>] [m<addr>=<value>/<size>]".
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>

typedef uint64_t u64; typedef int64_t s64; typedef uint32_t u32; typedef int32_t s32;

static uint8_t *mem; static u64 memsize;
static u64 R[32], F[32], pc;
static u64 wlo = ~0ULL, whi = 0;          /* write range outside stop window */
static u64 stop_lo, stop_hi;
static u64 user_base; static int user_mode;    /* -e: VA - user_base = offset into mem */
static int pal_mode; static u64 ipr[256]; static u64 tohost = ~0ULL;
static FILE *tf;                                /* -T trace */
static u64 t_maddr, t_mval; static int t_msize; /* the instruction's store, for -T */

static void die(const char *m) { fprintf(stderr, "FATAL @pc=%#" PRIx64 ": %s\n", pc, m); exit(2); }

static u64 pa(u64 a, int n) {
    if (user_mode) {
        a -= user_base;
        if (a + n > memsize || a + n < a) { fprintf(stderr, "bad addr %#" PRIx64 "\n", a + user_base); die("memory access out of range"); }
        return a;
    }
    if ((a >> 31) == 0x1ffffffffULL) a &= 0x7fffffffULL;   /* NT 32-bit superpage 0x80000000 -> PA 0 */
    a &= 0x3ffffffffULL;
    if (a + n > memsize) { fprintf(stderr, "bad addr %#" PRIx64 "\n", a); die("memory access out of range"); }
    return a;
}
static u64 ld(u64 a, int n) { a = pa(a, n); u64 v = 0; memcpy(&v, mem + a, n); return v; }
static void st(u64 a, u64 v, int n) {
    if (pal_mode && (a & 0x3ffffffffULL) == tohost) {
        fprintf(stderr, "TOHOST %#" PRIx64 " (+8 %#" PRIx64 ", +16 %#" PRIx64 ")\n", v, ld(a + 8, 8), ld(a + 16, 8));
        if (tf) fclose(tf);
        exit(v == 1 ? 0 : 1);
    }
    t_maddr = a; t_mval = n == 8 ? v : v & ((1ULL << (8 * n)) - 1); t_msize = n;
    a = pa(a, n); memcpy(mem + a, &v, n);
    if (a < stop_lo || a >= stop_hi) { if (a < wlo) wlo = a; if (a + n > whi) whi = a + n; }
}
static u64 sext(u64 v, int bits) { return (u64)((s64)(v << (64 - bits)) >> (64 - bits)); }
static u64 zapmask(int m) { u64 r = 0; for (int i = 0; i < 8; i++) if (m & (1 << i)) r |= 0xffULL << (8 * i); return r; }
static u64 zap(u64 v, int m) { return v & ~zapmask(m); }
static u64 zapnot(u64 v, int m) { return v & zapmask(m); }

static u64 umulh(u64 a, u64 b) { return (u64)(((unsigned __int128)a * b) >> 64); }

int main(int argc, char **argv) {
    u64 maxinsn = 4000000000ULL, mb = 64, trace = 0;
    struct { u64 a, l; char *f; } dumps[16]; int nd = 0;
    struct { char *f; u64 off, a, l; } loads[16]; int nl = 0;
    int have_pc = 0, have_stop = 0; char *elf = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-m")) mb = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-t")) trace = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-n")) maxinsn = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-p")) { pc = strtoull(argv[++i], 0, 0); have_pc = 1; }
        else if (!strcmp(argv[i], "-s")) { char *s = argv[++i]; stop_lo = strtoull(s, &s, 0); stop_hi = strtoull(s + 1, 0, 0); have_stop = 1; }
        else if (!strcmp(argv[i], "-l")) {
            char *s = argv[++i]; char *at = strrchr(s, '@'); if (!at) die("-l file@off:addr[:len]");
            *at = 0; loads[nl].f = s; char *p = at + 1;
            loads[nl].off = strtoull(p, &p, 0); loads[nl].a = strtoull(p + 1, &p, 0);
            loads[nl].l = (*p == ':') ? strtoull(p + 1, 0, 0) : ~0ULL; nl++;
        } else if (!strcmp(argv[i], "-d")) {
            char *s = argv[++i]; dumps[nd].a = strtoull(s, &s, 0); dumps[nd].l = strtoull(s + 1, &s, 0); dumps[nd].f = s + 1; nd++;
        } else if (!strcmp(argv[i], "-e")) { elf = argv[++i]; have_pc = 1;
        } else if (!strcmp(argv[i], "-P")) { pal_mode = 1;
        } else if (!strcmp(argv[i], "-H")) { tohost = strtoull(argv[++i], 0, 0);
        } else if (!strcmp(argv[i], "-T")) { tf = fopen(argv[++i], "w"); if (!tf) die("open trace");
        } else if (!strcmp(argv[i], "-r")) {
            char *s = argv[++i]; int r = strtol(s, &s, 0); R[r] = strtoull(s + 1, 0, 0);
        } else die("bad arg");
    }
    if (!have_pc) die("need -p");
    memsize = mb << 20; mem = calloc(1, memsize); if (!mem) die("oom");
    u64 lo = ~0ULL, hi = 0;
    if (elf) {
        FILE *fp = fopen(elf, "rb"); if (!fp) die("open elf");
        uint8_t eh[64]; if (fread(eh, 1, 64, fp) != 64 || memcmp(eh, "\177ELF\2\1", 6)) die("not an ELF64 LE file");
        u64 phoff, entry; uint16_t phent, phnum;
        memcpy(&entry, eh + 24, 8); memcpy(&phoff, eh + 32, 8); memcpy(&phent, eh + 54, 2); memcpy(&phnum, eh + 56, 2);
        user_mode = 1; user_base = ~0ULL;
        for (int pass = 0; pass < 2; pass++)
            for (int k = 0; k < phnum; k++) {
                uint8_t ph[56]; uint32_t type; u64 off, va, fsz, msz;
                fseek(fp, phoff + (u64)k * phent, SEEK_SET); if (fread(ph, 1, 56, fp) != 56) die("read phdr");
                memcpy(&type, ph, 4); memcpy(&off, ph + 8, 8); memcpy(&va, ph + 16, 8);
                memcpy(&fsz, ph + 32, 8); memcpy(&msz, ph + 40, 8);
                if (type != 1) continue;                                 /* PT_LOAD */
                if (pass == 0) { if ((va & ~0xffffULL) < user_base) user_base = va & ~0xffffULL; continue; }
                if (va - user_base + msz > memsize) die("ELF segment beyond memory");
                fseek(fp, off, SEEK_SET);
                if (fsz && fread(mem + (va - user_base), 1, fsz, fp) != fsz) die("read segment");
            }
        fclose(fp);
        pc = entry;
        R[30] = user_base + memsize - 4096;                             /* sp */
        stop_lo = 0; stop_hi = ~0ULL; have_stop = 1;
    }
    for (int i = 0; i < nl; i++) {
        FILE *fp = fopen(loads[i].f, "rb"); if (!fp) die("open load file");
        fseek(fp, 0, SEEK_END); u64 sz = ftell(fp); fseek(fp, loads[i].off, SEEK_SET);
        u64 n = sz - loads[i].off; if (loads[i].l < n) n = loads[i].l;
        if (loads[i].a + n > memsize) die("load too big");
        if (fread(mem + loads[i].a, 1, n, fp) != n) die("read");
        fclose(fp);
        if (loads[i].a < lo) lo = loads[i].a;
        if (loads[i].a + n > hi) hi = loads[i].a + n;
        fprintf(stderr, "loaded %s+%#" PRIx64 " -> %#" PRIx64 " (%#" PRIx64 " bytes)\n", loads[i].f, loads[i].off, loads[i].a, n);
    }
    if (!have_stop) { stop_lo = lo; stop_hi = hi; }

    u64 n;
    for (n = 0; n < maxinsn; n++) {
        if (!pal_mode && (pc < stop_lo || pc >= stop_hi)) {
            fprintf(stderr, "STOP: pc left window -> %#" PRIx64 " after %" PRIu64 " insns\n", pc, n);
            break;
        }
        u32 ins = (u32)ld(pc, 4); u64 npc = pc + 4;
        if (n < trace) fprintf(stderr, "T %016" PRIx64 " %08x\n", pc, ins);
        int op = ins >> 26, ra = (ins >> 21) & 31, rb = (ins >> 16) & 31, rc = ins & 31;
        u64 disp16 = sext(ins & 0xffff, 16);
        u64 a = R[ra], b = (ins & 0x1000) ? ((ins >> 13) & 0xff) : R[rb];
        int fn = (ins >> 5) & 0x7f;
        u64 res = 0; int wr = -1;
        switch (op) {
        case 0x00:
            if (user_mode && (ins & 0x3ffffff) == 0x83) {            /* callsys */
                if (R[0] == 1) {
                    if (tf) fprintf(tf, "%016" PRIx64 " %08x exit %" PRIu64 "\n", pc, ins, R[16]);
                    fprintf(stderr, "exit(%" PRIu64 ") after %" PRIu64 " insns\n", R[16], n);
                    if (tf) fclose(tf);
                    exit((int)R[16]);
                }
                if (R[0] == 4) {
                    u64 len = R[18]; u64 b = pa(R[17], len);
                    fwrite(mem + b, 1, len, R[16] == 2 ? stderr : stdout);
                    R[0] = len; R[19] = 0;
                    if (tf) fprintf(tf, "%016" PRIx64 " %08x r0=%016" PRIx64 "\n", pc, ins, len);
                    pc = npc; continue;
                }
                die("unsupported syscall");
            }
            fprintf(stderr, "STOP: call_pal %#x at %#" PRIx64 " after %" PRIu64 " insns\n", ins & 0x3ffffff, pc, n);
            goto done;
        case 0x08: res = R[rb] + disp16; wr = ra; break;                    /* lda  */
        case 0x09: res = R[rb] + (disp16 << 16); wr = ra; break;            /* ldah */
        case 0x0b: res = ld((R[rb] + disp16) & ~7ULL, 8); wr = ra; break;   /* ldq_u */
        case 0x0f: st((R[rb] + disp16) & ~7ULL, a, 8); break;               /* stq_u */
        case 0x10:
            switch (fn) {
            case 0x00: res = sext((u32)(a + b), 32); break;
            case 0x02: res = sext((u32)(a * 4 + b), 32); break;
            case 0x09: res = sext((u32)(a - b), 32); break;
            case 0x0b: res = sext((u32)(a * 4 - b), 32); break;
            case 0x0f: res = 0; for (int i = 0; i < 8; i++) if (((a >> (8*i)) & 0xff) >= ((b >> (8*i)) & 0xff)) res |= 1 << i; break;
            case 0x12: res = sext((u32)(a * 8 + b), 32); break;
            case 0x1b: res = sext((u32)(a * 8 - b), 32); break;
            case 0x1d: res = a < b; break;
            case 0x20: res = a + b; break;
            case 0x22: res = a * 4 + b; break;
            case 0x29: res = a - b; break;
            case 0x2b: res = a * 4 - b; break;
            case 0x2d: res = a == b; break;
            case 0x32: res = a * 8 + b; break;
            case 0x3b: res = a * 8 - b; break;
            case 0x3d: res = a <= b; break;
            case 0x40: res = sext((u32)(a + b), 32); break;
            case 0x49: res = sext((u32)(a - b), 32); break;
            case 0x4d: res = (s64)a < (s64)b; break;
            case 0x60: res = a + b; break;
            case 0x69: res = a - b; break;
            case 0x6d: res = (s64)a <= (s64)b; break;
            default: die("unimpl 0x10");
            }
            wr = rc; break;
        case 0x11:
            wr = rc;
            switch (fn) {
            case 0x00: res = a & b; break;
            case 0x08: res = a & ~b; break;
            case 0x14: if (a & 1) res = b; else wr = -1; break;
            case 0x16: if (!(a & 1)) res = b; else wr = -1; break;
            case 0x20: res = a | b; break;
            case 0x24: if (a == 0) res = b; else wr = -1; break;
            case 0x26: if (a != 0) res = b; else wr = -1; break;
            case 0x28: res = a | ~b; break;
            case 0x40: res = a ^ b; break;
            case 0x44: if ((s64)a < 0) res = b; else wr = -1; break;
            case 0x46: if ((s64)a >= 0) res = b; else wr = -1; break;
            case 0x48: res = a ^ ~b; break;
            case 0x61: res = b; break;            /* amask: EV4 has no extensions */
            case 0x64: if ((s64)a <= 0) res = b; else wr = -1; break;
            case 0x66: if ((s64)a > 0) res = b; else wr = -1; break;
            case 0x6c: res = 0; break;            /* implver: EV4 */
            default: die("unimpl 0x11");
            }
            break;
        case 0x12: {
            int sh = b & 7, bl = 8 * sh, bh = (64 - 8 * sh) & 63;
            wr = rc;
            switch (fn) {
            case 0x02: res = zap(a, (0x01 << sh) & 0xff); break;
            case 0x06: res = (a >> bl) & 0xff; break;
            case 0x0b: res = zapnot(a << bl, (0x01 << sh) & 0xff); break;
            case 0x12: res = zap(a, (0x03 << sh) & 0xff); break;
            case 0x16: res = (a >> bl) & 0xffff; break;
            case 0x1b: res = zapnot(a << bl, (0x03 << sh) & 0xff); break;
            case 0x22: res = zap(a, (0x0f << sh) & 0xff); break;
            case 0x26: res = (a >> bl) & 0xffffffffULL; break;
            case 0x2b: res = zapnot(a << bl, (0x0f << sh) & 0xff); break;
            case 0x30: res = zap(a, b & 0xff); break;
            case 0x31: res = zapnot(a, b & 0xff); break;
            case 0x32: res = zap(a, (0xff << sh) & 0xff); break;
            case 0x34: res = a >> (b & 63); break;
            case 0x36: res = a >> bl; break;
            case 0x39: res = a << (b & 63); break;
            case 0x3b: res = zapnot(a << bl, (0xff << sh) & 0xff); break;
            case 0x3c: res = (u64)((s64)a >> (b & 63)); break;
            case 0x52: res = zap(a, (0x03 << sh) >> 8); break;
            case 0x57: { int m = (0x03 << sh) >> 8; res = m ? zapnot(a >> bh, m) : 0; } break;
            case 0x5a: res = zapnot(a << bh, 0x03); break;
            case 0x62: res = zap(a, (0x0f << sh) >> 8); break;
            case 0x67: { int m = (0x0f << sh) >> 8; res = m ? zapnot(a >> bh, m) : 0; } break;
            case 0x6a: res = zapnot(a << bh, 0x0f); break;
            case 0x72: res = zap(a, (0xff << sh) >> 8); break;
            case 0x77: { int m = (0xff << sh) >> 8; res = m ? zapnot(a >> bh, m) : 0; } break;
            case 0x7a: res = zapnot(a << bh, 0xff); break;
            default: die("unimpl 0x12");
            }
        } break;
        case 0x13:
            switch (fn) {
            case 0x00: case 0x40: res = sext((u32)(a * b), 32); break;
            case 0x20: case 0x60: res = a * b; break;
            case 0x30: res = umulh(a, b); break;
            default: die("unimpl 0x13");
            }
            wr = rc; break;
        case 0x17:  /* only raw register moves are supported */
            if (fn == 0x20) { F[rc] = (F[ra] & (1ULL << 63)) | (F[rb] & ~(1ULL << 63)); if (rc == 31) F[31] = 0; }
            else die("unimpl FP op");
            break;
        case 0x18:
            switch (ins & 0xffff) {
            case 0x0000: case 0x0400: case 0x4000: case 0x4400: case 0x8000: case 0xa000: break; /* trapb excb mb wmb fetch */
            case 0xc000: res = n; wr = ra; break; /* rpcc */
            default: die("unimpl 0x18");
            }
            break;
        case 0x19: res = pal_mode ? ipr[ins & 0xff] : 0; wr = ra; break;   /* hw_mfpr */
        case 0x1a: { u64 t = R[rb] & ~3ULL; res = npc; wr = ra; npc = t; } break;
        case 0x1b: { u64 ad = R[rb] + sext(ins & 0xfff, 12); res = (ins & 0x1000) ? ld(ad, 8) : sext(ld(ad, 4), 32); wr = ra; } break;
        case 0x1d: if (pal_mode) ipr[ins & 0xff] = R[rb]; break;            /* hw_mtpr */
        case 0x1e:
            if (pal_mode) { npc = ipr[0x24] & ~3ULL; break; }
            fprintf(stderr, "STOP: hw_rei at %#" PRIx64 " after %" PRIu64 " insns\n", pc, n);
            goto done;
        case 0x1f: { u64 ad = R[rb] + sext(ins & 0xfff, 12); st(ad, a, (ins & 0x1000) ? 8 : 4); } break;
        case 0x23: F[ra] = ld(R[rb] + disp16, 8); if (ra == 31) F[31] = 0; break;   /* ldt raw */
        case 0x27: st(R[rb] + disp16, F[ra], 8); break;                               /* stt raw */
        case 0x28: case 0x2a: res = sext(ld(R[rb] + disp16, 4), 32); wr = ra; break;
        case 0x29: case 0x2b: res = ld(R[rb] + disp16, 8); wr = ra; break;
        case 0x2c: st(R[rb] + disp16, a, 4); break;
        case 0x2d: st(R[rb] + disp16, a, 8); break;
        case 0x2e: st(R[rb] + disp16, a, 4); res = 1; wr = ra; break;
        case 0x2f: st(R[rb] + disp16, a, 8); res = 1; wr = ra; break;
        default:
            if (op >= 0x30) {
                u64 tgt = npc + (sext(ins & 0x1fffff, 21) << 2); int t = 0;
                switch (op) {
                case 0x30: case 0x34: res = npc; wr = ra; t = 1; break;
                case 0x38: t = !(a & 1); break;
                case 0x39: t = a == 0; break;
                case 0x3a: t = (s64)a < 0; break;
                case 0x3b: t = (s64)a <= 0; break;
                case 0x3c: t = a & 1; break;
                case 0x3d: t = a != 0; break;
                case 0x3e: t = (s64)a >= 0; break;
                case 0x3f: t = (s64)a > 0; break;
                default: die("FP branch");
                }
                if (t) npc = tgt;
            } else { fprintf(stderr, "opcode %#x ins %08x\n", op, ins); die("unimpl opcode"); }
        }
        if (wr >= 0 && wr != 31) R[wr] = res;
        R[31] = 0;
        if (tf) {
            fprintf(tf, "%016" PRIx64 " %08x", pc, ins);
            if (wr >= 0 && wr != 31) fprintf(tf, " r%d=%016" PRIx64, wr, res);
            if (t_msize) fprintf(tf, " m%016" PRIx64 "=%016" PRIx64 "/%d", t_maddr, t_mval, t_msize);
            fputc('\n', tf);
        }
        t_msize = 0;
        pc = npc;
    }
done:
    fprintf(stderr, "final pc=%#" PRIx64 " v0=%#" PRIx64 " ra=%#" PRIx64 " insns=%" PRIu64 "\n", pc, R[0], R[26], n);
    if (whi) fprintf(stderr, "writes outside window: %#" PRIx64 " .. %#" PRIx64 " (%" PRIu64 " bytes)\n", wlo, whi, whi - wlo);
    for (int i = 0; i < 32; i++) fprintf(stderr, "r%-2d=%016" PRIx64 "%s", i, R[i], (i % 4 == 3) ? "\n" : "  ");
    for (int i = 0; i < nd; i++) {
        FILE *fp = fopen(dumps[i].f, "wb"); if (!fp) die("open dump");
        fwrite(mem + pa(dumps[i].a, dumps[i].l), 1, dumps[i].l, fp); fclose(fp);
        fprintf(stderr, "dumped %#" PRIx64 "+%#" PRIx64 " -> %s\n", dumps[i].a, dumps[i].l, dumps[i].f);
    }
    return 0;
}
