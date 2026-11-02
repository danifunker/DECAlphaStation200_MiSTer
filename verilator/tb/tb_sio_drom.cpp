// DEC's DROM V1.7 POST run against rtl/sio/sio82378.v: an EV4 integer
// interpreter (from tools/alphaemu) runs the DROM image at PA 0x40000 with
// the SROM's hand-over state (docs/design/srom.md 5); memory, the flashbus
// (NVRAM, LEDs, jumpers) and the 21071 CSRs are modelled crudely here; the
// PCI target bus goes to the Verilated SIO, whose intr/nmi/toy_irq/kbrst are
// the CPU's HIRR (irq_h 2-5). The 53C810's configuration is a stand-in (its
// ID and the 80h-FFh register window the DROM's SCSI test writes). Each
// instruction is one cycle at 100 MHz (RPCC, CC_CTL), plus the I/O waits.
//
//   make -C verilator tb_sio_drom [DROM=...] [DROMARGS='--log --calibrate']
//     --flash FILE   the 1 MB flash image (the DROM checks the console's header there)
//     --log          every PCI configuration and ISA access, with the DROM's PC
//     --calibrate    PA 0x70 = 2: the DROM times the CPU against 8254 counter 0
//     --cycles N     give up after N cycles (default 600M)
//     --floppy FILE  drive A:'s image (hps_io slot 3, modelled here), and the jumpers
//                    set for the floppy loader (J2: 01h); --floppy-test makes a 1.44 MB
//                    image here: a boot block (LBN 30, 20 blocks, its checksum) and
//                    patterned blocks
//     --jumpers N    the jumper byte (default 03h: no mini-console, flash loader)
//
// Passes when the LEDs show the POST steps 24 (NVRAM) .. 2A (interrupts) and
// then 2E (the jump to the flash console) with no beep code; with a floppy, 2B
// (the floppy loader), 2C and the jump to 0x100000 with the image's blocks
// there (docs/design/floppy.md 5). The SIO's DMA master port goes to memory
// here (PCI 0x40000000 = PA 0, the DROM's 1 GB window). The image is
// DEC's, from scratch/ (not in git); this file holds none of it.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cinttypes>
#include <string>
#include <vector>
#include "Vsio82378.h"
#include "verilated.h"
typedef uint64_t u64; typedef int64_t s64; typedef uint32_t u32; typedef int32_t s32;

static std::vector<uint8_t> mem;
static std::vector<uint8_t> fimg;            // drive A:'s image
static int fd_st, fd_lat, fd_i, fd_n, fd_sub, fd_wr_op; static uint32_t fd_lba;
static int fd_dmapend;
struct Dev {
    Vsio82378 *t; uint8_t ncr[256];
    void fd_step() {
        // the SIO's DMA master port: memory, through the 21071's 1 GB window at PCI 1 GB
        t->dm_ack = 0;
        if (t->dm_req && !fd_dmapend) fd_dmapend = 1;
        else if (t->dm_req) {
            uint32_t a = (t->dm_addr & 0x3FFFFFFC) % mem.size(), q;
            if (t->dm_we) for (int b = 0; b < 4; b++) if (t->dm_be >> b & 1) mem[a + b] = t->dm_wdata >> (8 * b);
            memcpy(&q, &mem[a], 4); t->dm_rdata = q; t->dm_ack = 1; fd_dmapend = 0;
        }
        // hps_io's block device 3
        t->fd_buff_wr = 0;
        switch (fd_st) {
        case 0: if (t->fd_rd || t->fd_wr) { fd_wr_op = t->fd_wr; fd_lba = t->fd_lba; fd_n = (t->fd_blk_cnt + 1) * 512; fd_i = 0; fd_sub = 0; fd_lat = 20000; fd_st = 1; } break;
        case 1: if (--fd_lat == 0) { t->fd_ack = 1; fd_st = 2; } break;
        case 2: {
            size_t at = (size_t)fd_lba * 512 + fd_i;
            if (!fd_wr_op) { if (fd_sub == 0) { t->fd_buff_addr = fd_i; t->fd_buff_dout = at < fimg.size() ? fimg[at] : 0; t->fd_buff_wr = 1; } }
            else if (fd_sub == 0) t->fd_buff_addr = fd_i;
            if (++fd_sub == 3) { if (fd_wr_op && at < fimg.size()) fimg[at] = t->fd_buff_din; fd_sub = 0; if (++fd_i == fd_n) fd_st = 3; }
            break;
        }
        default: t->fd_ack = 0; fd_st = 0; break;
        }
    }
    void tick() { fd_step(); t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    void reset() {
        t = new Vsio82378; memset(ncr, 0, sizeof ncr);
        t->pirq_n = 15; t->com1_rxd = 1; t->com2_rxd = 1; t->com1_cts_n = 0; t->com1_dsr_n = 0; t->com1_dcd_n = 0; t->com1_ri_n = 1;
        t->com2_cts_n = 0; t->com2_dsr_n = 0; t->com2_dcd_n = 0; t->com2_ri_n = 1;
        t->rst = 1; for (int i = 0; i < 8; i++) tick(); t->rst = 0;
        if (!fimg.empty()) { t->fd_size = fimg.size(); t->fd_readonly = 0; t->fd_mounted = 1; tick(); t->fd_mounted = 0; for (int i = 0; i < 400; i++) tick(); }
    }
    int irqs() { return (t->intr << 2) | (t->nmi << 3) | (t->toy_irq << 4) | (t->kbrst << 5); }
    void run(u64 n) { for (u64 i = 0; i < n; i++) { tick(); if (t->com1_tx_stb) { putchar(t->com1_tx_byte); fflush(stdout); } } }
    u32 pci(int cmd, int dn, u32 a, int be, int we, u32 wd, bool &claimed, int &waits) {
        if (cmd == 0 && dn == 6) {                 // a 53C810 stand-in: ID and config RAM 80-FF
            claimed = true; waits = 2;
            if (a < 4) return 0x00011000;
            if (a >= 0x80) { if (we) for (int i = 0; i < 4; i++) if (be >> i & 1) ncr[a + i] = wd >> (8 * i); u32 v; memcpy(&v, &ncr[a], 4); return v; }
            return 0;
        }
        t->pt_req = 1; t->pt_cmd = cmd; t->pt_dev = dn; t->pt_addr = a; t->pt_be = be; t->pt_we = we; t->pt_wdata = wd;
        t->pt_sub = cmd == 1;
        t->clk = 0; t->eval();
        claimed = t->pt_claim;
        waits = 0;
        if (!claimed) { t->pt_req = 0; tick(); waits = 1; return ~0u; }
        u32 r = 0;
        for (;;) { tick(); waits++; if (t->com1_tx_stb) { putchar(t->com1_tx_byte); fflush(stdout); }
                   if (t->pt_ack) { r = t->pt_rdata; break; } if (waits > 100) { fprintf(stderr, "no ack\n"); break; } }
        t->pt_req = 0; tick(); waits++;
        return r;
    }
};

static Dev *dev;
static u64 memsize, instsize;
static std::vector<uint8_t> fb(2u << 20, 0xFF);
static u64 R[32], F[32], pc, cyc, dev_cyc;
static u64 ipr[256];
static u32 fb_index; static uint8_t leds = 0xFF, jumpers = 0x03;
static uint8_t nvram[8192];
static u32 ca[128], da[128];
static int flash_mode;          // 0 read array, 1 ID
static int verbose_io = 1;
static u64 pal_base = 0x40000; static u64 cc_base;

static void die(const char *m) { fprintf(stderr, "FATAL @pc=%#" PRIx64 ": %s\n", pc, m); exit(2); }
static u64 sext(u64 v, int bits) { return (u64)((s64)(v << (64 - bits)) >> (64 - bits)); }
static u64 zapmask(int m) { u64 r = 0; for (int i = 0; i < 8; i++) if (m & (1 << i)) r |= 0xffULL << (8 * i); return r; }
static u64 zap(u64 v, int m) { return v & ~zapmask(m); }
static u64 zapnot(u64 v, int m) { return v & zapmask(m); }
static u64 umulh(u64 a, u64 b) { return (u64)(((unsigned __int128)a * b) >> 64); }

static void catchup() {
    u64 d = cyc - dev_cyc;
    if (d > 2000000) d = 2000000;      // the device idles while the DROM tests memory
    if (d) dev->run(d);
    dev_cyc = cyc;
}

static int sp_be(int len, int lane) {
    return len == 0 ? (1 << lane) : len == 1 ? (3 << lane) : len == 2 ? (7 << lane) : 15;
}

// an I/O-space access; returns the quadword the CPU sees
static u64 io(u64 a, u64 v, int n, int we) {
    u32 wlw = (u32)v;
    if (a < 0x100000000ULL) die("io below 4G");
    if ((a >> 20) == 0x1000) { if (we) fb_index = wlw; return fb_index; }
    if ((a >> 20) == 0x1001) {
        u32 off = (fb_index >> 8) & 0x1FFFFF; int devn = (fb_index >> 26) & 7;
        if (devn == 4) { if (we && (fb_index >> 31)) nvram[off & 8191] = wlw; return nvram[off & 8191]; }
        if (devn == 5) { if (we && (fb_index >> 31)) { leds = wlw; fprintf(stderr, "[%12" PRIu64 "] pc %05" PRIx64 " LED %02X\n", cyc, pc, leds); } return leds; }
        if (devn == 7) return jumpers;
        if (we) {
            if (fb_index >> 31) {
                uint8_t c = wlw;
                if (c == 0x90) flash_mode = 1; else if (c == 0xFF || c == 0x00) flash_mode = 0;
                fprintf(stderr, "[%12" PRIu64 "] flash write %06x = %02x\n", cyc, off, c);
            }
            return 0;
        }
        if (flash_mode == 1 && devn < 4) return (off & 1) ? 0xBD : 0x89;
        return fb[off];
    }
    if ((a >> 12) == 0x180000) { int r = (a >> 5) & 127; if (we) ca[r] = r == 2 ? 0 : wlw; u64 q = ca[r]; return q | q << 32; }
    if ((a >> 12) == 0x1A0000) { int r = (a >> 5) & 127; if (we) da[r] = r == 0 ? (wlw & 0xFFFF009F) : wlw; u64 q = da[r]; return q | q << 32; }
    int len = (a >> 3) & 3, lane = (a >> 5) & 3;
    int cmd = -1, dn = 0; u32 pa32 = 0;
    if ((a >> 29) == 0xE) { cmd = 1; pa32 = (a >> 5) & 0xFFFFFC; }
    else if ((a >> 29) == 0xF) { cmd = 0; dn = (a >> 16) & 31; pa32 = ((a >> 13) & 7) << 8 | ((a >> 7) & 63) << 2; }
    else if ((a >> 28) == 0x1B) { cmd = 3; }
    else if ((a >> 32) == 2) { cmd = 2; pa32 = (a >> 5) & 0x7FFFFFC; }
    else if ((a >> 32) == 3) { cmd = 2; pa32 = a & 0xFFFFFFFC; len = 3; lane = 0; }
    if (cmd < 0) { if (verbose_io) fprintf(stderr, "[%12" PRIu64 "] unmapped %s %#" PRIx64 "\n", cyc, we ? "write" : "read", a); return ~0ULL; }
    int be = cmd == 3 ? 15 : sp_be(len, lane);
    catchup();
    bool claimed = false; int waits = 0;
    u32 r = dev->pci(cmd, dn, pa32, be, we, wlw, claimed, waits);
    cyc += waits; dev_cyc += waits;
    if (!claimed) r = 0xFFFFFFFF;
    if (verbose_io) {
        static const char *cn[] = {"CFG", "IO ", "MEM", "ACK"};
        if (cmd == 1) {
            u32 port = pa32 | (be & 1 ? 0 : be & 2 ? 1 : be & 4 ? 2 : 3);
            fprintf(stderr, "[%12" PRIu64 "] pc %05" PRIx64 " IO  %s %03x len%d %s %08x\n", cyc, pc, we ? "W" : "R", port, len,
                    claimed ? "" : "(nc)", we ? wlw : r);
        } else
            fprintf(stderr, "[%12" PRIu64 "] pc %05" PRIx64 " %s %s dev%d addr %06x be%x %s %08x\n", cyc, pc, cn[cmd], we ? "W" : "R", dn, pa32, be,
                    claimed ? "" : "(nc)", we ? wlw : r);
    }
    u64 q = r; return q | q << 32;
}

static u64 ld(u64 a, int n) {
    a &= 0x3ffffffffULL;
    if (a >= 0x100000000ULL) { u64 q = io(a & ~7ULL, 0, n, 0); if (n == 4 && (a & 4)) q >>= 32; return n == 4 ? (u32)q : q; }
    if (a + n > instsize) return ~0ULL;
    u64 v = 0; memcpy(&v, &mem[a], n); return v;
}
static void st(u64 a, u64 v, int n) {
    a &= 0x3ffffffffULL;
    if (a >= 0x100000000ULL) { io(a & ~7ULL, (n == 4 && (a & 4)) ? v : v, n, 1); return; }
    if (a + n > instsize) return;
    memcpy(&mem[a], &v, n);
}

// SROM-port line decode (SL_XMIT bit 4)
static int s_last = 1, s_nbit = -1, s_byte; static double s_t0; static std::string sline;
static const double SBIT = 100e6 / 19200.0;
static void sl_sample(int v) {
    if (s_nbit < 0) { if (s_last && !v) { s_nbit = 0; s_t0 = cyc; s_byte = 0; } }
    s_last = v;
}
static void sl_poll() {
    if (s_nbit < 0) return;
    double centre = s_t0 + SBIT * (s_nbit + 1.5);
    if (cyc >= centre) {
        if (s_nbit < 8) { s_byte |= s_last << s_nbit; s_nbit++; }
        else {
            s_nbit = -1;
            if (s_byte == '\n') { fprintf(stderr, "[%12" PRIu64 "] DROM: %s\n", cyc, sline.c_str()); sline.clear(); }
            else if (s_byte >= 0x20 && s_byte < 0x7F) sline += (char)s_byte;
        }
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *drom = nullptr, *flash = nullptr, *floppy = nullptr; u64 maxcyc = 600000000ULL; int calibrate = 0, ftest = 0;
    verbose_io = 0;
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        if (s == "--log") verbose_io = 1;
        else if (s == "--calibrate") calibrate = 1;
        else if (s == "--flash" && i + 1 < argc) flash = argv[++i];
        else if (s == "--cycles" && i + 1 < argc) maxcyc = strtoull(argv[++i], 0, 0);
        else if (s == "--floppy" && i + 1 < argc) floppy = argv[++i];
        else if (s == "--floppy-test") ftest = 1;
        else if (s == "--jumpers" && i + 1 < argc) jumpers = strtoul(argv[++i], 0, 0);
        else if (s[0] == '+') ;
        else drom = argv[i];
    }
    if (!drom) { fprintf(stderr, "usage: %s DROM.bin --flash FLASH.bin [--log] [--calibrate] [--cycles N]\n", argv[0]); return 2; }
    memsize = 128u << 20; instsize = 64u << 20;
    mem.assign(memsize, 0);
    FILE *f = fopen(drom, "rb"); if (!f) die("drom");
    size_t nr = fread(&fb[0x180000], 1, 0x10000, f); fclose(f);
    memcpy(&mem[0x3FFC0], &fb[0x180000], nr);
    if (flash) { f = fopen(flash, "rb"); if (!f) die("flash"); nr = fread(&fb[0], 1, 1u << 20, f); fclose(f); }
    auto q = [&](u64 a, u64 v) { memcpy(&mem[a], &v, 8); };
    q(0x08, instsize); q(0x10, 10000); q(0x18, 0xDECB0000ULL); q(0x20, 1); q(0x38, instsize >> 20);
    q(0x68, 100); q(0x70, calibrate ? 2 : 9);
    R[17] = instsize; R[18] = 10000; R[19] = 0xDECB0000ULL; R[20] = 1;
    if (floppy) {
        f = fopen(floppy, "rb"); if (!f) die("floppy");
        fseek(f, 0, SEEK_END); fimg.resize(ftell(f)); fseek(f, 0, SEEK_SET);
        if (fread(fimg.data(), 1, fimg.size(), f) != fimg.size()) die("floppy read"); fclose(f);
    } else if (ftest) {
        // a 1.44 MB floppy with an Alpha boot block: blocks 30..49 to 0x100000 (across cylinder 0 to 1)
        fimg.assign(1474560, 0);
        for (size_t k = 512; k < fimg.size(); k++) fimg[k] = (uint8_t)(k * 31 + (k >> 9) * 7 + 1);
        u64 cnt = 20, lbn = 30, sum = 0;
        memcpy(&fimg[0x1E0], &cnt, 8); memcpy(&fimg[0x1E8], &lbn, 8);
        for (int k = 0; k < 63; k++) { u64 v; memcpy(&v, &fimg[8 * k], 8); sum += v; }
        memcpy(&fimg[0x1F8], &sum, 8);
    }
    if (!fimg.empty() && jumpers == 0x03) jumpers = 0x01;     // J2: the floppy loader
    pc = 0x40000;
    dev = new Dev();
    dev->reset();
    std::vector<int> seen; int last_led = 0xFF, minicon = 0; u64 beep = 0;
    for (; cyc < maxcyc; cyc++) {
        u32 ins = (u32)ld(pc, 4); u64 npc = pc + 4;
        int op = ins >> 26, ra = (ins >> 21) & 31, rb = (ins >> 16) & 31, rc = ins & 31;
        u64 disp16 = sext(ins & 0xffff, 16);
        u64 a = R[ra], b = (ins & 0x1000) ? ((ins >> 13) & 0xff) : R[rb];
        int fn = (ins >> 5) & 0x7f;
        u64 res = 0; int wr = -1;
        sl_poll();
        switch (op) {
        case 0x00: fprintf(stderr, "call_pal %#x at %#" PRIx64 "\n", ins & 0x3ffffff, pc); goto done;
        case 0x08: res = R[rb] + disp16; wr = ra; break;
        case 0x09: res = R[rb] + (disp16 << 16); wr = ra; break;
        case 0x0b: res = ld((R[rb] + disp16) & ~7ULL, 8); wr = ra; break;
        case 0x0f: st((R[rb] + disp16) & ~7ULL, a, 8); break;
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
            case 0x64: if ((s64)a <= 0) res = b; else wr = -1; break;
            case 0x66: if ((s64)a > 0) res = b; else wr = -1; break;
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
        case 0x17:
            if (fn == 0x20) { F[rc] = (F[ra] & (1ULL << 63)) | (F[rb] & ~(1ULL << 63)); if (rc == 31) F[31] = 0; }
            else die("unimpl FP op");
            break;
        case 0x18:
            switch (ins & 0xffff) {
            case 0x0000: case 0x0400: case 0x4000: case 0x4400: case 0x8000: case 0xa000: break;
            case 0xc000: res = (cyc - cc_base) & 0xffffffffULL; wr = ra; break;
            default: die("unimpl 0x18");
            }
            break;
        case 0x19: {
            int ix = ins & 0xff;
            if (ix == 0x2c || ix == 0x2d || ix == 0x2e) {      // HIRR / SIRR / ASTRR
                catchup();
                int irq = dev->irqs();                         // bit n = irq_h[n]
                res = ((u64)(irq & 7) << 10) | ((u64)((irq >> 3) & 7) << 5);
            } else res = ipr[ix];
            wr = ra; break;
        }
        case 0x1a: { u64 t = R[rb] & ~3ULL; res = npc; wr = ra; npc = t; } break;
        case 0x1b: { u64 ad = R[rb] + sext(ins & 0xfff, 12); res = (ins & 0x1000) ? ld(ad, 8) : sext(ld(ad, 4), 32); wr = ra; } break;
        case 0x1d: {
            int ix = ins & 0xff; ipr[ix] = R[rb];
            if ((ins & 0x40) && (ins & 0x1f) == 17) cc_base = cyc - (R[rb] & 0xffffffffULL);
            if ((ix & 0x3f) == 0x36 || ix == 0x36 || ix == 0xb6) sl_sample((R[rb] >> 4) & 1);
            if ((ins & 0x20) && (ins & 0x1f) == 11) pal_base = R[rb] & 0x3ffffc000ULL;
        } break;
        case 0x1e: npc = ipr[0x24] & ~3ULL; break;
        case 0x1f: { u64 ad = R[rb] + sext(ins & 0xfff, 12); st(ad, a, (ins & 0x1000) ? 8 : 4); } break;
        case 0x23: F[ra] = ld(R[rb] + disp16, 8); if (ra == 31) F[31] = 0; break;
        case 0x27: st(R[rb] + disp16, F[ra], 8); break;
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
        pc = npc;
        // DROM V1.7: 0x44158 sounds a beep code (t11 = its three groups), 0x40570 is the
        // mini-console a failed test ends in; LED 2E is the jump to the flash console
        if (pc == 0x44158) { beep = R[25]; break; }
        if (pc == 0x40570) { minicon = 1; break; }
        if (pc == 0x100000 && !fimg.empty()) break;                 // the floppy loader's jump
        if (leds != last_led) { seen.push_back(leds); last_led = leds; if (leds == 0x2E) break; }
    }
done:
    if (!sline.empty()) fprintf(stderr, "DROM (partial): %s\n", sline.c_str());
    static const struct { int led; const char *name; } steps[] = {
        {0x24, "NVRAM test"}, {0x25, "53C810 test"}, {0x26, "82378 test"}, {0x27, "TOY (3287) test"},
        {0x28, "8242 test"}, {0x29, "87332 test"}, {0x2A, "Interrupts test"}, {0x2D, "flash loader"},
        {0x2E, "jump to the flash console"}};
    int ok = 1; size_t k = 0;
    if (!fimg.empty()) {
        // the floppy loader: LED 2B, the blocks the boot block names at 0x100000, LED 2C, the jump
        static const struct { int led; const char *name; } fsteps[] = {
            {0x24, "NVRAM test"}, {0x2A, "Interrupts test"}, {0x2B, "floppy loader"}, {0x2C, "floppy image loaded"}};
        for (auto &st : fsteps) {
            while (k < seen.size() && seen[k] != st.led) k++;
            bool got = k < seen.size();
            printf("%s LED %02X %s\n", got ? "PASS" : "FAIL", st.led, st.name);
            if (!got) ok = 0;
        }
        u64 cnt, lbn; memcpy(&cnt, &fimg[0x1E0], 8); memcpy(&lbn, &fimg[0x1E8], 8);
        bool at = pc == 0x100000, same = cnt < 2048 && !memcmp(&mem[0x100000], &fimg[lbn * 512], cnt * 512);
        printf("%s the jump to 0x100000 (pc %05" PRIx64 ")\n", at ? "PASS" : "FAIL", pc);
        printf("%s %" PRIu64 " blocks from LBN %" PRIu64 " at 0x100000\n", same ? "PASS" : "FAIL", cnt, lbn);
        if (!at || !same) ok = 0;
        if (beep) { printf("FAIL beep code %d-%d-%d at LED %02X\n", (int)(beep & 0xFFFF), (int)(beep >> 16 & 0xFFFF), (int)(beep >> 32), leds); ok = 0; }
        if (minicon) { printf("FAIL the DROM fell into its mini-console at LED %02X\n", leds); ok = 0; }
        printf("cycles %" PRIu64 "\n%s\n", cyc, ok ? "PASS: DROM V1.7 floppy loader" : "FAIL: DROM V1.7 floppy loader");
        return ok ? 0 : 1;
    }
    for (auto &st : steps) {
        while (k < seen.size() && seen[k] != st.led) k++;
        bool got = k < seen.size();
        printf("%s LED %02X %s\n", got ? "PASS" : "FAIL", st.led, st.name);
        if (!got) ok = 0;
    }
    if (beep) { printf("FAIL beep code %d-%d-%d at LED %02X\n", (int)(beep & 0xFFFF), (int)(beep >> 16 & 0xFFFF), (int)(beep >> 32), leds); ok = 0; }
    if (minicon) { printf("FAIL the DROM fell into its mini-console at LED %02X\n", leds); ok = 0; }
    u64 p10, p68, p70; memcpy(&p10, &mem[0x10], 8); memcpy(&p68, &mem[0x68], 8); memcpy(&p70, &mem[0x70], 8);
    printf("cycles %" PRIu64 ", PA 0x10 = %" PRIu64 " ps, 0x68 = %" PRIu64 " MHz, 0x70 = %" PRIu64 "\n", cyc, p10, p68, p70);
    if (calibrate && (p10 != 10000 || p70 != 9)) { printf("FAIL the calibration did not find 100 MHz\n"); ok = 0; }
    printf("%s\n", ok ? "PASS: DROM V1.7 POST" : "FAIL: DROM V1.7 POST");
    return ok ? 0 : 1;
}
