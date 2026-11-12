// Bench for the TGA (rtl/tga/, docs/design/tga.md) with its DDR3 arbiter and
// the flashbus ROM behind it (verilator/tb/tb_tga_top.v). The bench models
// the DDRAM bridge (random busy, read latency), apecs's PCI target cycles and
// DMA, and keeps a reference copy of VRAM with the drawing semantics of
// tga.md 4 to check every operation against.
//
//   tb_tga [--ppm FILE] [--seed N]
//
// Checks: the PCI header and BAR sizing, the ROM word, register read-back,
// SRM's block-stipple probe, block / opaque / transparent fills (frame buffer
// and address+start forms), opaque / transparent / block stipple, simple
// writes with raster ops, plane and pixel masks, copy mode, COPY64, DMA write
// and read copy (SRM's scroll), fills, stipples and copies through the address
// and continue registers (XFree86), the Bt485 palette and registers (read back),
// a displayed frame (1024x768 SRM mode, VVBR 1, Bt485 cursor) against VRAM,
// the end-of-frame interrupt, the video selector, and flash reads and writes
// through the arbiter while the engine and the display use DDR3.
#include "Vtb_tga_top.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <deque>
#include <random>
#include <string>

static Vtb_tga_top *t;
static std::mt19937_64 rng(1);
static long fails = 0;
#define CHECK(c, ...) do { if (!(c)) { if (fails++ < 40) { printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } } while (0)

// ---------------------------------------------------------------- DDR3 model
static const uint32_t DBASE = 0x06000000;           // flash at word 0, VRAM at word 0x20000
static std::vector<uint64_t> ddr(0x60000);
// a read's data is taken when the command is accepted: later writes do not show in it
struct Burst { long at; uint32_t a; int n; std::vector<uint64_t> d; size_t i; };
static std::deque<Burst> rq;
static long cyc = 0;
static int wr_left = 0; static uint32_t wr_a = 0;
static long ddr_reads = 0, ddr_writes = 0, busy_pct = 15;

static std::vector<uint64_t> nbm(8192);             // the LAN mailbox, word 0x03FE_0000
static uint64_t &dw(uint32_t a) {
    if (a - 0x03FE0000u < 8192) return nbm[a - 0x03FE0000u];
    uint32_t i = a - DBASE;
    if (i >= ddr.size()) { static uint64_t junk; CHECK(false, "DDR3 access outside the map: %08x", a); return junk; }
    return ddr[i];
}

static void ddr_pre_edge() {
    if (t->DDRAM_BUSY) return;
    if (t->DDRAM_RD) {
        int n = t->DDRAM_BURSTCNT;
        CHECK(n >= 1 && n <= 32, "burst count %d", n);
        Burst rb{cyc + 8 + (long)(rng() % 12), t->DDRAM_ADDR, n, {}, 0};
        for (int k = 0; k < n; k++) rb.d.push_back(dw(t->DDRAM_ADDR + k));
        rq.push_back(rb);
        ddr_reads++;
    }
    if (t->DDRAM_WE) {
        uint32_t a;
        if (wr_left == 0) { a = t->DDRAM_ADDR; wr_left = t->DDRAM_BURSTCNT; wr_a = a; }
        else a = wr_a;
        uint64_t &m = dw(a);
        for (int b = 0; b < 8; b++) if (t->DDRAM_BE >> b & 1)
            m = (m & ~(0xFFull << 8 * b)) | (t->DDRAM_DIN & (0xFFull << 8 * b));
        wr_a++; wr_left--; ddr_writes++;
    }
}
static void ddr_post_edge() {
    t->DDRAM_BUSY = (long)(rng() % 100) < busy_pct;
    t->DDRAM_DOUT_READY = 0;
    if (!rq.empty() && rq.front().at <= cyc) {
        Burst &b = rq.front();
        t->DDRAM_DOUT = b.d[b.i++]; t->DDRAM_DOUT_READY = 1;
        b.a++; b.at = cyc + ((rng() % 8) == 0 ? 2 : 1);
        if (--b.n == 0) rq.pop_front();
    }
}

// ---------------------------------------------------------------- host memory and DMA
static const uint32_t HBASE = 0x00100000;
static std::vector<uint8_t> host(0x40000);
static int dma_cnt = 0; static bool dma_busy = false; static long dma_n = 0;
static uint32_t dma_a; static bool dma_w; static uint32_t dma_d;
static void dma_pre_edge() {
    if (t->dm_ack) return;
    if (t->dm_req && !dma_busy) {
        dma_busy = true; dma_cnt = 3 + rng() % 6;
        dma_a = t->dm_addr; dma_w = t->dm_we; dma_d = t->dm_wdata;
        CHECK((dma_a & 3) == 0 && t->dm_be == 0xF, "DMA %08x be %x", dma_a, t->dm_be);
    }
}
static void dma_post_edge() {
    t->dm_ack = 0;
    if (dma_busy && --dma_cnt == 0) {
        uint32_t o = dma_a - HBASE;
        if (o + 4 > host.size()) { CHECK(false, "DMA outside host memory: %08x", dma_a); o = 0; }
        if (dma_w) memcpy(&host[o], &dma_d, 4);
        else { uint32_t v; memcpy(&v, &host[o], 4); t->dm_rdata = v; }
        t->dm_ack = 1; dma_busy = false; dma_n++;
    }
}

// ---------------------------------------------------------------- video capture
static const int FW = 2048, FH = 1024;
static std::vector<uint32_t> frame(FW * FH);
static int vx = 0, vy = 0, frames = 0, line_w = 0, lines = 0, last_w = 0, last_h = 0;
static bool pde = false, pvb = false, capture = false;
static void video_sample() {
    if (!t->ce_pix) return;
    if (t->de) {
        if (!pde) vx = 0;
        if (capture && vx < FW && vy < FH) frame[vy * FW + vx] = t->r << 16 | t->g << 8 | t->b;
        vx++;
    } else if (pde) { line_w = vx; vy++; }
    if (t->vblank && !pvb) { last_w = line_w; last_h = vy; frames++; vy = 0; }
    pde = t->de; pvb = t->vblank;
}

// ---------------------------------------------------------------- clocks: 100 MHz and 65 MHz
static uint64_t ts = 5000, tp = 7692;
static void cycle() {
    for (;;) {
        if (ts <= tp) {
            bool rise = !t->clk;
            if (rise) { ddr_pre_edge(); dma_pre_edge(); }
            t->clk = rise; t->eval();
            ts += 5000;
            if (rise) { cyc++; ddr_post_edge(); dma_post_edge(); t->eval(); return; }
        } else {
            bool rise = !t->clk_pix;
            t->clk_pix = rise; t->eval();
            tp += 7692;
            if (rise) video_sample();
        }
    }
}
static void ticks(long n) { while (n--) cycle(); }

// ---------------------------------------------------------------- PCI
static const uint32_t BAR = 0x10000000;
static uint32_t pci(int cmd, int dev, uint32_t addr, int be, bool we, uint32_t wd, bool *claimed = nullptr) {
    t->pt_req = 1; t->pt_cmd = cmd; t->pt_dev = dev; t->pt_addr = addr; t->pt_be = be; t->pt_we = we;
    t->pt_wdata = wd; t->eval();
    bool cl = t->pt_claim;
    if (claimed) *claimed = cl;
    if (!cl) { t->pt_req = 0; cycle(); return 0xFFFFFFFF; }
    uint32_t r = 0; long k = 0;
    for (;;) {
        cycle();
        if (t->pt_ack) { r = t->pt_rdata; break; }
        if (++k > 2000000) { CHECK(false, "no pt_ack for %08x", addr); break; }
    }
    t->pt_req = 0; cycle();
    return r;
}
static uint32_t cfg_rd(int reg) { return pci(0, 12, reg, 0xF, false, 0); }
static void cfg_wr(int reg, uint32_t v) { pci(0, 12, reg, 0xF, true, v); }
static uint32_t mrd(uint32_t o) { return pci(2, 0, BAR + o, 0xF, false, 0); }
static void mwr(uint32_t o, uint32_t v, int be = 0xF) { pci(2, 0, BAR + o, be, true, v); }
static void reg_wr(int r, uint32_t v) { mwr(0x100000 + r, v); }
static uint32_t reg_rd(int r) { return mrd(0x100000 + r); }
static void fb_wr(uint32_t o, uint32_t v, int be = 0xF) { mwr(0x200000 + o, v, be); }
static uint32_t fb_rd(uint32_t o) { return mrd(0x200000 + o); }
static void wait_idle() {
    long k = 0;
    while (reg_rd(0x1FC) != 0) if (++k > 200000) { CHECK(false, "engine stays busy"); break; }
    ticks(60);                          // the arbiter's merge register and FIFO
}

// ---------------------------------------------------------------- reference VRAM
static const uint32_t VSZ = 0x200000;
static std::vector<uint8_t> ref(VSZ);
static uint32_t r_fg, r_bg, r_pm = ~0u, r_pxm = ~0u, r_rop = 3, r_data = ~0u, r_bc0, r_bc1, r_dbase;
static bool r_os;                       // the pixel mask was written one-shot (02C)
// 21030 4.4.21.3: after a one-shot mask's operation the GPXR reinitializes to FFFFFFFF
static void os_done() { if (r_os) { r_pxm = ~0u; r_os = false; } }
static uint8_t vram(uint32_t a) { a &= VSZ - 1; return dw(DBASE + 0x20000 + a / 8) >> (8 * (a & 7)) & 0xFF; }
static uint8_t ropb(int c, uint8_t s, uint8_t d) {
    return ((c & 8) ? ~s & ~d : 0) | ((c & 4) ? ~s & d : 0) | ((c & 2) ? s & ~d : 0) | ((c & 1) ? s & d : 0);
}
static void put(uint32_t a, uint8_t s, bool rop) {
    a &= VSZ - 1;
    uint8_t d = ref[a], pmb = r_pm >> (8 * (a & 3));
    uint8_t v = rop ? ropb(r_rop, s, d) : s;
    ref[a] = (v & pmb) | (d & ~pmb);
}
static uint8_t fgb(uint32_t a) { return r_fg >> (8 * (a & 3)); }
static uint8_t bgb(uint32_t a) { return r_bg >> (8 * (a & 3)); }
static uint8_t bcb(uint32_t a) { return (a & 4 ? r_bc1 : r_bc0) >> (8 * (a & 3)); }
static void compare(const char *what) {
    long bad = 0;
    for (uint32_t a = 0; a < VSZ; a++) if (vram(a) != ref[a]) {
        if (bad++ < 6) printf("  %s: VRAM %06x = %02x, expected %02x\n", what, a, vram(a), ref[a]);
    }
    CHECK(bad == 0, "%s: %ld VRAM bytes differ", what, bad);
}
// backdoor: VRAM and reference together
static void poke(uint32_t a, uint8_t v) {
    a &= VSZ - 1; ref[a] = v;
    uint64_t &m = dw(DBASE + 0x20000 + a / 8);
    m = (m & ~(0xFFull << 8 * (a & 7))) | ((uint64_t)v << 8 * (a & 7));
}

// the register writes the reference follows
static void set_fg(uint32_t v) { r_fg = v; reg_wr(0x20, v); }
static void set_bg(uint32_t v) { r_bg = v; reg_wr(0x24, v); }
static void set_pm(uint32_t v) { r_pm = v; reg_wr(0x28, v); }
static void set_pxm(uint32_t v) { r_pxm = v; r_os = false; reg_wr(0x5C, v); }
static void set_pxm_os(uint32_t v) { r_pxm = v; r_os = true; reg_wr(0x2C, v); }
static void set_rop(uint32_t v) { r_rop = v & 15; reg_wr(0x34, v); }
static void set_mode(uint32_t v) { reg_wr(0x30, v); }
static void set_data(uint32_t v) { r_data = v; reg_wr(0x80, v); }
static void set_bc(uint32_t a, uint32_t b) { r_bc0 = a; r_bc1 = b; reg_wr(0x140, a); reg_wr(0x144, b); }

static void ref_fill(uint32_t p0, int n, int mode) {
    for (int i = 0; i < n; i++) {
        uint32_t p = p0 + i;
        bool bit = r_data >> ((p - (p0 & ~3u)) & 31) & 1;
        if (mode == 0x2D) { if (bit) put(p, bcb(p), false); }
        else if (mode == 0x21) put(p, bit ? fgb(p) : bgb(p), true);
        else if (bit) put(p, fgb(p), true);
    }
    os_done();
}
static void ref_stip(uint32_t o, uint32_t m, int mode) {
    uint32_t p0 = o & ~3u;
    for (int i = 0; i < 32; i++) {
        if (mode == 0x01 && !(r_pxm >> i & 1)) continue;   // the pixel mask: opaque stipple only (4.4.21)
        uint32_t p = p0 + i; bool bit = m >> i & 1;
        if (mode == 0x01) put(p, bit ? fgb(p) : bgb(p), true);
        else if (mode == 0x03 || mode == 0x05) { if (bit) put(p, fgb(p), true); }
        else if (bit) put(p, bcb(p), false);
    }
    os_done();
}
static void ref_simple(uint32_t o, uint32_t w, int be) {
    for (int b = 0; b < 4; b++) {
        uint32_t p = (o & ~3u) + b;
        if ((be >> b & 1) && (r_pxm >> b & 1)) put(p, w >> (8 * b), true);   // mask bit k = byte k
    }
    os_done();
}

int main(int argc, char **argv) {
    const char *ppm = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--ppm") && i + 1 < argc) ppm = argv[++i];
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) rng.seed(strtoul(argv[++i], 0, 0));
    }
    t = new Vtb_tga_top;
    for (auto &w : ddr) w = rng();
    for (uint32_t a = 0; a < VSZ; a++) ref[a] = vram(a);
    t->gfx = 1; t->rst = 1; ticks(20); t->rst = 0; ticks(20);

    // ------------------------------------------------ 1. PCI configuration
    CHECK(cfg_rd(0x00) == 0x00041011, "ID %08x", cfg_rd(0x00));
    CHECK(cfg_rd(0x08) == 0x03800003, "class/rev %08x", cfg_rd(0x08));
    bool cl; pci(0, 11, 0, 0xF, false, 0, &cl); CHECK(!cl, "claimed device 11");
    pci(0, 12, 0x100, 0xF, false, 0, &cl); CHECK(!cl, "claimed function 1");
    cfg_wr(0x10, 0xFFFFFFFF);
    CHECK(cfg_rd(0x10) == 0xF8000008, "BAR sizing %08x", cfg_rd(0x10));
    cfg_wr(0x10, BAR);
    CHECK(cfg_rd(0x10) == (BAR | 8), "BAR %08x", cfg_rd(0x10));
    pci(2, 0, BAR + 0x100000, 0xF, false, 0, &cl); CHECK(!cl, "memory claimed while disabled");
    cfg_wr(0x04, 0x6);
    CHECK((cfg_rd(0x04) & 0xFFFF) == 0x6, "command %08x", cfg_rd(0x04));
    CHECK((cfg_rd(0x3C) >> 8 & 0xFF) == 1, "interrupt pin");
    cfg_wr(0x40, 0); cfg_wr(0x44, 0x12340000);
    CHECK(cfg_rd(0x44) == 0x12340000, "cfg 44");
    pci(2, 0, BAR + 0x08000000, 0xF, false, 0, &cl); CHECK(!cl, "claimed outside the BAR");
    printf("tb_tga: PCI header done\n");

    // ------------------------------------------------ 2. ROM word, registers
    CHECK(mrd(0) == 0x800, "ROM word %08x", mrd(0));
    CHECK((reg_rd(0x54) & 0xFF) == 3, "revision %08x", reg_rd(0x54));
    {
        static const int regs[] = {0x20, 0x24, 0x28, 0x5C, 0x64, 0x68, 0x74, 0x80, 0x98, 0x140, 0x144, 0x84, 0xB8, 0x40, 0x3C};
        for (int r : regs) {
            uint32_t v = rng();
            reg_wr(r, v);
            CHECK(reg_rd(r) == v, "register %03x reads %08x, wrote %08x", r, reg_rd(r), v);
            CHECK(reg_rd(r + 0x400) == v, "register %03x alias", r);
        }
        reg_wr(0x30, 0x2D); CHECK(reg_rd(0x30) == 0x80002D, "mode %08x (GMOR<23>: the pixel mask is persistent)", reg_rd(0x30));
        reg_wr(0x38, 0xFFFFFFFF); CHECK(reg_rd(0x38) == 0xF, "pixel shift %08x", reg_rd(0x38));
        reg_wr(0x7C, 0x001F001F); CHECK(reg_rd(0x7C) == 0x001F0000, "SISR %08x", reg_rd(0x7C));
        reg_wr(0x7C, 0x0000001F); wait_idle();
        CHECK(reg_rd(0x1FC) == 0 && reg_rd(0x1F8) == 0, "command status");
    }
    // the deep register and the rest of SRM's asic_reset
    reg_wr(0x50, 0x0001C000);
    CHECK(reg_rd(0x50) == 0x0001C000, "deep");
    set_pxm(0xFFFFFFFF); reg_wr(0x2C, 0xFFFFFFFF); set_rop(3); set_pm(0xFFFFFFFF);
    set_mode(0x0D); set_mode(0x00); set_rop(3);
    for (int i = 0; i < 16; i++) { fb_wr(0x400 + 4 * i, 0); ref_simple(0x400 + 4 * i, 0, 0xF); }
    set_mode(0x0D); wait_idle();
    set_bc(0x12345678, 0x12345678);
    fb_wr(0x400, 0xFFFFFFFF); ref_stip(0x400, 0xFFFFFFFF, 0x0D);
    CHECK(fb_rd(0x400) == 0x12345678, "SRM block-stipple probe reads %08x", fb_rd(0x400));
    set_mode(0x00);
    wait_idle(); compare("asic_reset");
    printf("tb_tga: registers done\n");

    // ------------------------------------------------ 3. fills
    for (int i = 0; i < 40; i++) {
        int mode = (i % 4 == 0) ? 0x2D : (i % 4 == 1) ? 0x21 : (i % 4 == 2) ? 0x23 : 0x25;   // 25: transparent (NT)
        set_fg(rng()); set_bg(rng()); set_bc(rng(), rng());
        set_data(i < 6 ? 0xFFFFFFFF : (uint32_t)rng());
        set_rop(i & 1 ? 3 : rng() % 16);
        set_pm(i % 4 == 3 ? (uint32_t)rng() : 0xFFFFFFFF);
        set_mode(mode);
        uint32_t o = (rng() % (VSZ - 8192)) & ~3u;
        int n = 1 + rng() % (i < 20 ? 64 : 2048);
        if (i % 2) {
            int al = rng() % 4;
            fb_wr(o, (n - 1) | al << 16); ref_fill(o + al, n, mode);
        } else {
            uint32_t p0 = o + rng() % 4;
            reg_wr(0x3C, p0); reg_wr(0x54, n - 1); ref_fill(p0, n, mode);
        }
        wait_idle();
        if (getenv("TGA_DBG")) { printf("fill %d mode %x o %x n %d rop %d pm %08x data %08x\n", i, mode, o, n, r_rop, r_pm, r_data); compare("fill"); }
    }
    set_mode(0); set_rop(3); set_pm(0xFFFFFFFF);
    compare("fills");
    // SRM's clear: count words every 32 bytes, overlapping
    set_bc(0x01010101, 0x01010101); set_data(0xFFFFFFFF); set_mode(0x2D);
    for (uint32_t o = 0x10000; o < 0x10000 + 4096; o += 32) { fb_wr(o, 2047); ref_fill(o, 2048, 0x2D); }
    wait_idle(); set_mode(0);
    compare("SRM clear");
    printf("tb_tga: fills done\n");

    // ------------------------------------------------ 4. stipple (SRM's text) and simple writes
    for (int i = 0; i < 60; i++) {
        int mode = (i % 4 == 0) ? 0x01 : (i % 4 == 1) ? 0x03 : (i % 4 == 2) ? 0x05 : 0x0D;   // 05: transparent (NT)
        set_fg(rng()); set_bg(rng()); set_bc(rng(), rng());
        set_rop(i % 5 ? 3 : rng() % 16);
        set_pm(i % 7 == 6 ? (uint32_t)rng() : 0xFFFFFFFF);
        uint32_t o = 0x20000 + (rng() % 0x10000);
        set_pxm(i % 4 ? 0x1FFu << (o & 3) : (uint32_t)rng());
        set_mode(mode);
        for (int l = 0; l < 4; l++) {
            uint32_t m = rng();
            fb_wr((o & ~3u) + 1028 * l, m); ref_stip((o & ~3u) + 1028 * l, m, mode);
        }
        wait_idle();
    }
    set_mode(0); set_pxm(0xFFFFFFFF);
    compare("stipples");
    for (int i = 0; i < 200; i++) {
        set_rop(i % 3 ? 3 : rng() % 16);
        set_pm(i % 5 == 4 ? (uint32_t)rng() : 0xFFFFFFFF);
        set_pxm(i % 6 == 5 ? (uint32_t)rng() : 0xFFFFFFFF);
        uint32_t o = 0x30000 + (rng() % 0x4000 & ~3u); uint32_t w = rng(); int be = rng() % 16;
        fb_wr(o, w, be); ref_simple(o, w, be);
        if (i % 10 == 0) { wait_idle(); uint32_t a = o & ~3u;
            uint32_t e = ref[a] | ref[a + 1] << 8 | ref[a + 2] << 16 | ref[a + 3] << 24;
            CHECK(fb_rd(a) == e, "simple read-back %06x %08x want %08x", a, fb_rd(a), e); }
    }
    wait_idle(); set_rop(3); set_pm(0xFFFFFFFF); set_pxm(0xFFFFFFFF);
    compare("simple writes");
    // NT 4.0's 1-pixel vertical lines: the persistent mask 05C = 1, a longword per row with the
    // pixel in byte 0, then the one-shot 02C = FFFFFFFF and no further 05C write. The 21030's
    // GPXR is one register: after a one-shot's operation it reinitializes to FFFFFFFF, not to
    // the value written persistently before (4.4.21.3). With two registers the mask stayed 1:
    // the Start menu's icons drew one pixel in four and its text nothing, and every window
    // move after such a line went wrong (2026-11-04)
    set_pxm(0x00000001);
    for (int i = 0; i < 13; i++) { uint32_t o = 0x3C000 + 0x320 * i; fb_wr(o, 0x000700F8); ref_simple(o, 0x000700F8, 0xF); }
    set_pxm_os(0xFFFFFFFF);
    for (int i = 0; i < 8; i++) { uint32_t o = 0x3C100 + 4 * i, w = rng(); fb_wr(o, w); ref_simple(o, w, 0xF); }
    // a one-shot 0F over a persistent 1, then the rest of the row unmasked (NT's icons)
    set_pxm(0x00000001); set_pxm_os(0x0000000F);
    for (int i = 0; i < 8; i++) { uint32_t o = 0x3C200 + 4 * i, w = rng(); fb_wr(o, w); ref_simple(o, w, 0xF); }
    // text (transparent stipple) after the same
    set_mode(0x05); set_fg(0x0F0F0F0F); set_pxm(0x00000001); set_pxm_os(0xFFFFFFFF);
    for (int l = 0; l < 4; l++) { uint32_t m = rng(); fb_wr(0x3C400 + 1028 * l, m); ref_stip(0x3C400 + 1028 * l, m, 0x05); }
    // NT's caret leaves the persistent mask 4 (05C) and then draws its status bar text with
    // transparent stipples and block stipples with no mask write in between: the pixel mask is
    // an opaque-stipple / simple-mode parameter only (4.4.21, 6.2.4), so they draw every pixel
    // (2026-11-09: glyph fragments in Notepad++'s status bar after every caret move)
    set_pxm(0x00000004);
    for (int l = 0; l < 6; l++) { uint32_t m = rng(); fb_wr(0x3D000 + 800 * l, m); ref_stip(0x3D000 + 800 * l, m, 0x05); }
    set_mode(0x0D); set_bc(0x3A3A3A3A, 0x5C5C5C5C);
    for (int l = 0; l < 6; l++) { uint32_t m = rng(); fb_wr(0x3D100 + 800 * l, m); ref_stip(0x3D100 + 800 * l, m, 0x0D); }
    set_mode(0x01);      // the opaque stipple is masked
    for (int l = 0; l < 6; l++) { uint32_t m = rng(); fb_wr(0x3D200 + 800 * l, m); ref_stip(0x3D200 + 800 * l, m, 0x01); }
    set_pxm(0xFFFFFFFF);
    set_mode(0); wait_idle();
    CHECK(reg_rd(0x5C) == 0xFFFFFFFF && reg_rd(0x2C) == 0xFFFFFFFF, "GPXR after the one-shot: %08x %08x", reg_rd(0x5C), reg_rd(0x2C));
    CHECK(reg_rd(0x30) >> 23 & 1, "GMOR<23> GPXR state: persistent");
    set_pxm_os(0x0000000F); CHECK(!(reg_rd(0x30) >> 23 & 1), "GMOR<23> GPXR state: one-shot");
    fb_wr(0x3C300, 0x11223344); ref_simple(0x3C300, 0x11223344, 0xF);
    wait_idle(); set_pxm(0xFFFFFFFF);
    compare("one-shot pixel mask");
    // NT's byte stores without BWX: read the longword, change one byte, write it back,
    // back to back (a read let past a write still in ddr3_arb's merge flush got old data)
    for (int i = 0; i < 400; i++) {
        uint32_t a = 0x38000 + (rng() % 0x800 & ~3u);
        for (int b = 0; b < 4; b++) {
            uint32_t v = fb_rd(a);
            uint32_t e = ref[a] | ref[a + 1] << 8 | ref[a + 2] << 16 | ref[a + 3] << 24;
            CHECK(v == e, "byte RMW read %06x %08x want %08x", a, v, e);
            v = e;
            uint8_t nb = rng();
            v = (v & ~(0xFFu << (8 * b))) | (uint32_t)nb << (8 * b);
            fb_wr(a, v); ref_simple(a, v, 0xF);
        }
    }
    wait_idle();
    compare("byte read-modify-writes");
    printf("tb_tga: stipple and simple done\n");

    // ------------------------------------------------ 5. copies
    reg_wr(0x38, 0);
    for (int i = 0; i < 60; i++) {
        set_rop(i % 4 ? 3 : rng() % 16);
        uint32_t s = 0x40000 + (rng() % 0x8000), d = 0x50000 + (rng() % 0x8000);
        if (i < 20) { s &= ~7u; d &= ~7u; }
        std::vector<uint8_t> src(ref.begin() + s, ref.begin() + s + 64);
        reg_wr(0x160 + 8 * (i & 3), s); reg_wr(0x164 + 8 * (i & 3), d);   // all four pairs (NT)
        for (int k = 0; k < 64; k++) put(d + k, src[k], true);
        if (i % 8 == 0) { set_mode(0); CHECK(reg_rd(0x30) == 0x800000, "copy flag after a mode write"); }
        wait_idle();
    }
    set_rop(3); compare("COPY64");
    // NT's tga.dll restoring a save-under: rows of 256 bytes as four back-to-back COPY64 pairs
    // (160/164 .. 178/17C), source stride 336 (off-screen), destination stride 640, misaligned
    for (int row = 0; row < 24; row++) {
        uint32_t s = 0x4C060 + row * 336, d = 0x13A78 + row * 640;
        std::vector<uint8_t> src(ref.begin() + s, ref.begin() + s + 256);
        for (int p = 0; p < 4; p++) { reg_wr(0x160 + 8 * p, s + 64 * p); reg_wr(0x164 + 8 * p, d + 64 * p); }
        for (int k = 0; k < 256; k++) put(d + k, src[k], true);
    }
    wait_idle(); compare("COPY64 rows (NT)");
    // ... with 8-byte aligned addresses and the byte offset in the pixel shift (038), as NT does:
    // destination byte d + k comes from source byte s - shift + k
    for (int row = 0; row < 32; row++) {
        int sh = row & 7;
        reg_wr(0x38, sh);
        uint32_t s = 0x4E000 + row * 336, d = 0x15000 + row * 640;
        std::vector<uint8_t> src(ref.begin() + s - sh, ref.begin() + s - sh + 256);
        for (int p = 0; p < 4; p++) { reg_wr(0x160 + 8 * p, s + 64 * p); reg_wr(0x164 + 8 * p, d + 64 * p); }
        for (int k = 0; k < 256; k++) put(d + k, src[k], true);
    }
    reg_wr(0x38, 0);
    wait_idle(); compare("COPY64 with pixel shift (NT)");

    // lines (modes 02/06), the 21030's Bresenham engine (manual 6.2.12). The reference below is the
    // manual's set-up and step: the error in half units, errinc per octant (X), a slope write draws
    // (major + cap ends) mod 16 pixels (0 = 16), each continue 16 more. Two mechanisms are driven:
    // NT's (a slope register 120 + 4 octant = |dy|<<16 | |dx| draws; address 03C, pattern 080,
    // continue 04C) and Tru64 X's (a slope-no-go register 100 + 4 octant sets up, GB3R 048 sets the
    // length and the initial error, a frame buffer write in the line mode draws from its address
    // with data<17:16> the address's low bits and data<15:0> the mask, continues 04C)
    {
        const uint32_t W = 640, base = 0x60000;
        reg_wr(0x9C, W);
        for (int i = 0; i < 96; i++) {
            bool std = i >= 48;                     // the frame buffer write mechanism
            int mode = i & 1 ? 0x06 : 0x02;
            int cap = (i & 2) ? 1 : 0;              // GMOR<15>: the last pixel drawn by a slope write
            set_fg(rng()); set_bg(rng()); set_rop(i % 5 == 4 ? 6 : 3);
            int oct = rng() % 8;
            int maj = 1 + rng() % 60, mnr = i % 16 < 8 ? 0 : rng() % (maj + 1);
            int dx = oct & 4 ? maj : mnr, dy = oct & 4 ? mnr : maj;
            uint32_t a = base + (100 + rng() % 200) * W + 100 + rng() % 400;
            uint32_t pat0 = i % 3 ? 0xFFFF : rng() & 0xFFFF;
            // the manual's set-up (X environment: GMOR<13> clear)
            bool xmaj = oct & 4, majp = xmaj ? (oct & 2) : (oct & 1), minp = xmaj ? (oct & 1) : (oct & 2);
            int errinc = xmaj ? ((oct & 1) ? 1 : 0) : ((oct & 2) ? 0 : 1);
            int ai1 = (xmaj ? 1 : (int)W) * (majp ? 1 : -1);
            int ai2 = (xmaj ? (int)W : 1) * (minp ? 1 : -1) + ai1;
            int e = (2 * mnr - maj - 1 + errinc) >> 1;      // arithmetic shift
            int ei1 = mnr, ei2 = maj - mnr;
            int total = maj + cap;                      // pixels the software wants drawn
            int first = (maj + cap) & 15; if (first == 0) first = 16;
            set_mode(mode | cap << 15);
            uint32_t p = a, pat = pat0; int drawn = 0, seg = 0, seglen = 0;
            if (!std) {
                reg_wr(0x3C, a); set_data(pat0);
                reg_wr(0x120 + 4 * oct, (uint32_t)dy << 16 | dx);
                seglen = first;
            } else if (i & 4) {
                reg_wr(0x100 + 4 * oct, (uint32_t)dy << 16 | dx);          // set up, no drawing
                int len = first; if (len == 16) len = 0;
                reg_wr(0x48, (uint32_t)((e << 15) & 0xFFFF8000) | len);     // GB3R: the same error and length
                fb_wr(a & ~3u, (a & 3) << 16 | pat0);                        // draws from a
                seglen = first;
            } else {
                // as Tru64's X server: the slope-no-go register, THEN the address register, GB3R,
                // and the first segment by a continue (no frame buffer write)
                reg_wr(0x100 + 4 * oct, (uint32_t)dy << 16 | dx);
                reg_wr(0x3C, a);
                int len = first; if (len == 16) len = 0;
                reg_wr(0x48, (uint32_t)((e << 15) & 0xFFFF8000) | len);
                reg_wr(0x4C, pat0);
                seglen = first;
            }
            while (drawn < total) {
                if (seg == seglen) { pat = rng() & 0xFFFF; if (i % 3) pat = 0xFFFF; reg_wr(0x4C, pat); seg = 0; seglen = 16; }
                int bit = pat >> seg & 1;
                if (mode == 0x02) put(p, bit ? fgb(p) : bgb(p), true);
                else if (bit) put(p, fgb(p), true);
                if (e < 0) { p += ai1; e += ei1; } else { p += ai2; e -= ei2; }
                drawn++; seg++;
            }
            wait_idle();
        }
        set_mode(0); set_rop(3); compare("lines");
    }
    set_mode(0x07);
    for (int i = 0; i < 60; i++) {
        set_rop(i % 4 ? 3 : rng() % 16);
        set_pxm(i % 5 == 4 ? (uint32_t)rng() : 0xFFFFFFFF);
        uint32_t s = 0x60000 + (rng() % 0x8000 & ~3u), d = 0x70000 + (rng() % 0x8000 & ~3u);
        uint32_t ms = 0xFFFFFFFF, md = i % 3 ? 0xFFFFFFFF : (uint32_t)rng();
        std::vector<uint8_t> src(ref.begin() + s, ref.begin() + s + 32);
        fb_wr(s, ms); os_done();
        CHECK(reg_rd(0x30) == 0x900007, "copy flag after the source: %08x", reg_rd(0x30));
        fb_wr(d, md);
        // the pixel mask is not a copy-mode parameter (4.4.21): a stale 05C = 4 left by NT's caret
        // used to keep the edge spans of a closed menu menu-coloured (2026-11-10)
        for (int k = 0; k < 32; k++) if (md >> k & 1) put(d + k, src[k], true);
        os_done();
        wait_idle();
    }
    set_mode(0); set_rop(3); set_pxm(0xFFFFFFFF);
    compare("copy mode");
    // the copy buffer read back (21030 4.4.6): a copy-mode source write fills it; GCBR0-7
    // (000-01C) read entries 0-3 as the destination would get them, i.e. the 32 bytes from
    // the block's source (the block less the pixel shift); a read ends the drain-next state, so
    // the next copy-mode write fills again. NT 4.0's tga.dll saves the screen under its
    // minimize/restore animation frames this way (a fill, 8 register reads, the next block) and
    // restores it with simple writes: with 000-01C reading back what was written the saved
    // pixels were zeros and the restores painted black (2026-11-04)
    set_mode(0x07); set_rop(3); set_pxm(0xFFFFFFFF); set_pm(0xFFFFFFFF);
    for (int i = 0; i < 40; i++) {
        int sh = (int)(rng() % 15) - 7;
        reg_wr(0x38, sh & 0xF);
        uint32_t a = 0x40000 + (rng() % 0x8000 & ~7u) + (i % 2 ? 4 : 0);
        fb_wr(a, 0xFFFFFFFF); wait_idle();
        uint32_t src = (sh < 0 ? (a & ~7u) - 24 : (a & ~3u)) - sh;
        for (int j = 0; j < 8; j++) {
            uint32_t v = reg_rd(j * 4), e = 0;
            for (int b = 0; b < 4; b++) e |= (uint32_t)ref[(src + 4 * j + b) & (VSZ - 1)] << (8 * b);
            CHECK(v == e, "copy buffer dword %d after a fill at %06x sh %d: %08x want %08x", j, a, sh, v, e);
        }
        CHECK(!(reg_rd(0x30) >> 20 & 1), "the copy state after reading the buffer: %08x", reg_rd(0x30));
    }
    compare("copy buffer reads");
    // ... and loaded by software: even then odd GCBRs, then a copy-mode write drains it
    reg_wr(0x38, 0);
    for (int i = 0; i < 20; i++) {
        uint32_t d = 0x48000 + (rng() % 0x4000 & ~7u); uint8_t bytes[32];
        for (int j = 0; j < 8; j++) { uint32_t v = rng(); for (int b = 0; b < 4; b++) bytes[4 * j + b] = v >> (8 * b); reg_wr(j * 4, v); }
        CHECK(reg_rd(0x30) >> 20 & 1, "the copy state after loading the buffer: %08x", reg_rd(0x30));
        uint32_t md = i % 2 ? 0xFFFFFFFF : (uint32_t)rng();
        fb_wr(d, md);
        for (int k = 0; k < 32; k++) if (md >> k & 1) put(d + k, bytes[k], true);
        wait_idle();
    }
    compare("copy buffer loads");
    // copy mode with the pixel shift, as NT's vSSCopy8to8 does window edges:
    // destination byte (D & ~3) + k comes from source byte (S & ~3) - shift + k
    set_mode(0x07);
    for (int i = 0; i < 64; i++) {
        int sh = i & 7;
        reg_wr(0x38, sh);
        set_rop(i % 4 ? 3 : rng() % 16);
        uint32_t s = 0x62000 + (rng() % 0x6000 & ~3u), d = 0x72000 + (rng() % 0x6000 & ~3u);
        uint32_t md = i % 3 ? 0xFFFFFFFF : (uint32_t)rng();
        std::vector<uint8_t> src(ref.begin() + s - sh, ref.begin() + s - sh + 32);
        fb_wr(s, 0xFFFFFFFF); fb_wr(d, md);
        for (int k = 0; k < 32; k++) if (md >> k & 1) put(d + k, src[k], true);
        wait_idle();
    }
    reg_wr(0x38, 0); set_mode(0); set_rop(3);
    compare("copy mode with pixel shift");
    // NT's vSSCopy8to8 row: a copy-mode pair (left edge), COPY64s, then copy-mode pairs again
    // with no mode write in between
    set_mode(0x07);
    for (int row = 0; row < 16; row++) {
        int sh = row & 7;
        reg_wr(0x38, sh);
        uint32_t s = 0x64000 + row * 336, d = 0x74000 + row * 640;
        std::vector<uint8_t> src(ref.begin() + s - sh, ref.begin() + s - sh + 32 + 128 + 64);
        uint32_t ml = 0xFFFFFFFFu << (row & 15);
        fb_wr(s, 0xFFFFFFFF); fb_wr(d, ml);
        for (int k = 0; k < 32; k++) if (ml >> k & 1) put(d + k, src[k], true);
        for (int p = 0; p < 2; p++) { reg_wr(0x160 + 8 * p, s + 32 + 64 * p); reg_wr(0x164 + 8 * p, d + 32 + 64 * p); }
        for (int k = 0; k < 128; k++) put(d + 32 + k, src[32 + k], true);
        for (int t = 0; t < 2; t++) {
            uint32_t mr = t ? 0x3FFu : 0xFFFFFFFFu;
            fb_wr(s + 160 + 32 * t, 0xFFFFFFFF); fb_wr(d + 160 + 32 * t, mr);
            for (int k = 0; k < 32; k++) if (mr >> k & 1) put(d + 160 + 32 * t + k, src[160 + 32 * t + k], true);
        }
    }
    reg_wr(0x38, 0); wait_idle(); set_mode(0);
    compare("copy pairs around COPY64 (NT)");
    // right-to-left rows (a window moved right over itself): the pixel shift is negative (-8..-1,
    // written as 4-bit two's complement) and the blocks go down; half the rows overlap (d = s + 20)
    // NT's screen-to-screen rows (tga.dll vSSCopy8to8) in both directions, sources overlapping
    // their destinations. Left to right (shift 0..7): a copy-mode pair at the left edge, COPY64s,
    // a pair at the right edge; a block at A covers A.. upwards. Right to left (shift -8..-1): the
    // same from the right, and a block is addressed by its last quadword (COPY64 [A-56, A+7],
    // copy mode [A-24, A+7], mask bit (x - A) & 31). Source bytes are read from the block less the
    // shift; those beyond the block's own come from the previous block's read (the shifter).
    {
        struct Blk { uint32_t ns = 0, len = 0; std::vector<uint8_t> snap; } prev;
        auto op = [&](bool bwd, bool c64, uint32_t sa, uint32_t da, uint32_t mask, int sh) {
            uint32_t len = c64 ? 64 : 32;
            uint32_t ns = bwd ? (sa & ~7u) - (len - 8) : (c64 ? sa : sa & ~3u);
            uint32_t ds = bwd ? (da & ~7u) - (len - 8) : (c64 ? da : da & ~3u);
            std::vector<uint8_t> snap(ref.begin() + ns, ref.begin() + ns + len), out(len);
            for (uint32_t k = 0; k < len; k++) {
                uint32_t a = ns - sh + k;
                if (a >= ns && a < ns + len) out[k] = snap[a - ns];
                else if (prev.len && a >= prev.ns && a < prev.ns + prev.len) out[k] = prev.snap[a - prev.ns];
                else out[k] = ref[a];
            }
            if (c64) {
                reg_wr(0x160, sa); reg_wr(0x164, da);
                for (uint32_t k = 0; k < len; k++) put(ds + k, out[k], true);
            } else {
                fb_wr(sa, 0xFFFFFFFF); fb_wr(da, mask);
                for (uint32_t k = 0; k < len; k++) {
                    // right to left: the mask's lanes in reverse quadword order, <7:0> [A, A+8),
                    // <15:8> [A-8, A), <23:16> [A-16, A-8), <31:24> [A-24, A-16) (NT 4.0's edge masks)
                    uint32_t o = (k + 8 - (da & 7)) & 31;               // the in-order bit
                    uint32_t bit = !bwd ? k : o < 8 ? o : o < 16 ? o + 16 : o < 24 ? o : o - 16;
                    if (mask >> bit & 1) put(ds + k, out[k], true);
                }
            }
            prev.ns = ns; prev.len = len; prev.snap = snap;
        };
        for (int dir = 0; dir < 2; dir++) {
            bool bwd = dir == 1;
            set_mode(0x07);
            for (int row = 0; row < 48; row++) {
                int sh = bwd ? -1 - (int)(rng() % 8) : (int)(rng() % 8);
                reg_wr(0x38, (uint32_t)sh & 0xF);
                int nb = 1 + rng() % 4;                       // COPY64 blocks between the pairs
                // destination row; the source overlaps it (a window moved by a few pixels) in odd rows
                uint32_t d0 = 0x6A000 + dir * 0x10000 + row * 800 + 8 * (rng() % 8);
                int delta = row & 1 ? (int)(8 * (1 + rng() % 4)) : 800 * 27 + 8 * (int)(rng() % 4);
                uint32_t s0 = d0 - (bwd ? delta : -delta);
                uint32_t ml = 0xFFFFFFFFu << (rng() % 32), mr = 0xFFFFFFFFu >> (rng() % 32);
                if (!bwd) {
                    op(false, false, s0, d0, ml, sh);
                    for (int b = 0; b < nb; b++) op(false, true, s0 + 32 + 64 * b, d0 + 32 + 64 * b, 0, sh);
                    op(false, false, s0 + 32 + 64 * nb, d0 + 32 + 64 * nb, mr, sh);
                } else {
                    uint32_t dr = d0 + 32 + 64 * nb, sr = s0 + 32 + 64 * nb;   // right pair first
                    op(true, false, sr, dr, ml, sh);
                    for (int b = 0; b < nb; b++) op(true, true, sr - 32 - 64 * b, dr - 32 - 64 * b, 0, sh);
                    op(true, false, sr - 64 * nb - 32, dr - 64 * nb - 32, mr, sh);
                }
            }
            reg_wr(0x38, 0); wait_idle(); set_mode(0);
            compare(bwd ? "NT rows right to left" : "NT rows left to right");
        }
    }
    // ------------------------------------------------ 5b. the continue register outside the line modes
    // XFree86's tga driver (tga_accel.c) draws on the 21030 with register writes only: the address
    // register 03C, then the continue register 04C with what a frame buffer write at that address
    // would carry. Solid and pattern fills (03C = y * width + x, 04C = width - 1), colour expansion
    // (03C, 04C = 32 stipple bits) and screen copies (038 shift, 03C source, 04C mask, 03C
    // destination, 04C mask), the copies with the driver's own TGACopyLineForwards / Backwards.
    {
        for (int i = 0; i < 48; i++) {
            int mode = i % 3 == 0 ? 0x2D : i % 3 == 1 ? 0x21 : 0x25;
            set_fg(rng()); set_bg(rng()); set_bc(rng(), rng());
            set_data(i < 6 ? 0xFFFFFFFF : (uint32_t)rng());
            set_rop(i & 1 ? 3 : rng() % 16);
            set_pm(i % 8 == 7 ? (uint32_t)rng() : 0xFFFFFFFF);
            set_mode(mode);
            for (int row = 0; row < 3; row++) {
                uint32_t p0 = 0x100000 + rng() % 0x20000; int n = 1 + rng() % (i < 24 ? 64 : 1280);
                reg_wr(0x3C, p0); reg_wr(0x4C, n - 1); ref_fill(p0, n, mode);
            }
            wait_idle();
        }
        set_mode(0); set_rop(3); set_pm(0xFFFFFFFF);
        compare("fills through the continue register");
        for (int i = 0; i < 48; i++) {
            int mode = i % 3 == 0 ? 0x01 : i % 3 == 1 ? 0x05 : 0x0D;
            set_fg(rng()); set_bg(rng()); set_bc(rng(), rng());
            set_rop(i % 5 ? 3 : rng() % 16);
            uint32_t o = 0x124000 + (rng() % 0x8000 & ~3u);
            set_mode(mode);
            for (int l = 0; l < 4; l++) {
                uint32_t m = rng();
                reg_wr(0x3C, o + 32 * l); reg_wr(0x4C, m); ref_stip(o + 32 * l, m, mode);
            }
            wait_idle();
        }
        set_mode(0); set_rop(3);
        for (int i = 0; i < 16; i++) {
            uint32_t o = 0x12E000 + (rng() % 0x1000 & ~3u), w = rng();
            reg_wr(0x3C, o); reg_wr(0x4C, w); ref_simple(o, w, 0xF);
        }
        wait_idle();
        compare("stipples and simple writes through the continue register");

        // a copy pair: destination byte D + k comes from source byte S - shift + k; source bytes
        // below the block's own come from the previous block's read where that holds them
        struct { uint32_t ns = 0; bool v = false; uint8_t snap[32]; } pv;
        auto pair = [&](uint32_t sa, uint32_t ms, uint32_t da, uint32_t md, int sh) {
            reg_wr(0x38, sh);
            reg_wr(0x3C, sa); reg_wr(0x4C, ms); reg_wr(0x3C, da); reg_wr(0x4C, md);
            uint32_t ns = sa & ~3u, ds = da & ~3u; uint8_t snap[32], out[32];
            for (int k = 0; k < 32; k++) snap[k] = ref[ns + k];
            for (int k = 0; k < 32; k++) {
                uint32_t a = ns - sh + k;
                out[k] = a >= ns ? snap[a - ns] : (pv.v && a >= pv.ns && a < pv.ns + 32) ? pv.snap[a - pv.ns] : ref[a];
            }
            for (int k = 0; k < 32; k++) if (md >> k & 1) put(ds + k, out[k], true);
            pv.ns = ns; pv.v = true; memcpy(pv.snap, snap, 32);
        };
        auto fwd = [&](uint32_t sa, uint32_t da, int w) {
            int read = 0;
            while (read < w) {
                uint32_t ms = ~0u, md = (w - read) >= 32 ? ~0u : ~0u >> (32 - (w - read));
                int sal = sa & 7; sa -= sal; ms <<= sal;
                int dal = da & 7; da -= dal; md <<= dal;
                int ps;
                if (dal >= sal) ps = dal - sal;
                else { ps = 8 - (sal - dal); da -= 8; md <<= 8; }
                pair(sa, ms, da, md, ps);
                sa += 32 - ps; da += 32;
                read += 32; read -= dal;
                if (dal < sal) read -= 8;
            }
        };
        auto bwd = [&](uint32_t a1, uint32_t a2, int w) {
            uint32_t sa = a1 + w - 32, da = a2 + w - 32; int read = 0;
            while (read < w) {
                uint32_t ms = ~0u, md = (w - read) >= 32 ? ~0u : ~0u << (32 - (w - read));
                int sal = sa & 7, dal = da & 7, ps;
                if (read == 0 && dal && sal > dal) {
                    uint32_t ts = a1 + (w - sal), td = a2 + (w - dal - 8);
                    uint32_t tdm = (0xFFu >> (8 - dal)) << 8;
                    pair(ts, ~0u, td, tdm, (8 - sal) + dal);
                    sa += 8 - sal; ms >>= 8 - sal; ms >>= dal; md >>= dal;
                } else if (read == 0 && sal != dal) sa += 8 - sal;
                else if (sal) { sa += 8 - sal; ms >>= 8 - sal; }
                if (dal) { da += 8 - dal; md >>= 8 - dal; }
                if (dal >= sal) ps = dal - sal;
                else { ps = (8 - sal) + dal; if (dal) { sa += 8; ms >>= 8; } }
                pair(sa, ms, da, md, ps);
                if (dal > sal) { sa -= 24; da -= 32 - ps; read += read == 0 ? 24 + sal : 24; }
                else if (dal == sal) { sa -= 32; da -= 32; read += (read == 0 && dal) ? 32 - (8 - dal) : 32; }
                else { sa -= 24; da -= 32 - ps; read += dal ? 16 + sal : 32 - ps; }
            }
        };
        // rows of a 1024-wide screen; the result has to be the row moved and nothing else
        // touched (the reference is the pair model above, the check is against a plain move)
        const uint32_t W = 1024, base = 0x140000, rows = 48;
        set_mode(0x07); set_rop(3); set_pm(0xFFFFFFFF);
        long xbad = 0;
        for (int i = 0; i < 240; i++) {
            int w = 1 + rng() % (i < 80 ? 40 : 300);
            int x1 = 40 + rng() % (W - 80 - w), y1 = 1 + rng() % (rows - 2), x2, y2;
            if (i % 3 == 0) { y2 = y1; x2 = x1 + 1 + rng() % 24; if (x2 + w > (int)W - 40) x2 = x1 - 1 - rng() % 24; }
            else if (i % 3 == 1) { y2 = y1; x2 = x1 - 1 - (int)(rng() % 24); }
            else { y2 = 1 + rng() % (rows - 2); x2 = 40 + rng() % (W - 80 - w); if (y2 == y1) y2 = y1 == 1 ? 2 : y1 - 1; }
            std::vector<uint8_t> want(ref.begin() + base, ref.begin() + base + W * rows);
            std::vector<uint8_t> row(want.begin() + y1 * W + x1, want.begin() + y1 * W + x1 + w);
            for (int k = 0; k < w; k++) want[y2 * W + x2 + k] = row[k];
            bool back = x2 > x1 && x1 + w > x2;
            pv.v = false;
            if (back) bwd(base + y1 * W + x1, base + y2 * W + x2, w); else fwd(base + y1 * W + x1, base + y2 * W + x2, w);
            // (the driver's own slip: backwards, narrower than 32, destination alignment not 0 and
            // below the source's, it shifts the destination mask down where it should cut its top,
            // and writes that many pixels left of the destination: not a plain move on any 21030)
            int sal_ = (x1 + w) & 7, dal_ = (x2 + w) & 7;
            bool slip = back && w < 32 && dal_ && sal_ > dal_;
            long bad = 0;
            if (!slip) for (uint32_t k = 0; k < W * rows; k++) if (ref[base + k] != want[k]) bad++;
            if (bad && xbad++ < 8) printf("  XFree86 copy %d %s: (%d,%d) -> (%d,%d) w %d: %ld bytes are not the moved row\n",
                                         i, back ? "backwards" : "forwards", x1, y1, x2, y2, w, bad);
            wait_idle();
        }
        CHECK(xbad == 0, "XFree86 copies: %ld rows not moved as a plain copy would", xbad);
        reg_wr(0x38, 0); set_mode(0);
        compare("copies through the continue register (XFree86)");
    }
    printf("tb_tga: copies done\n");

    // ------------------------------------------------ 6. DMA: SRM's scroll of one 1028-byte line
    for (int i = 0; i < 4; i++) {
        uint32_t src = 0x81000 + 1028 * (17 + i), dst = 0x81000 + 1028 * i;
        reg_wr(0x38, 0); reg_wr(0x80, 0xFFFFFFFF); src -= 8;
        uint32_t end = src + 1028, bc = 1028;
        do {
            uint32_t rbase = HBASE, rc = bc;
            if (src & 7) { rbase = HBASE + 4; rc = bc - 4; }
            reg_wr(0x98, HBASE); set_mode(0x1F);
            fb_wr(src, (bc / 8) << 16 | 0xFFFF);
            reg_wr(0x1FC, 0); wait_idle();
            for (uint32_t j = 0; j < bc / 8 * 8; j++) {
                uint8_t want = ref[((src & ~7u) + 8 + j) & (VSZ - 1)];
                if (host[j] != want) { CHECK(false, "DMA write: host %x = %02x, want %02x", j, host[j], want); break; }
            }
            reg_wr(0x98, rbase); set_mode(0x17);
            fb_wr(dst, (rc / 4) << 16 | 0xFFFF);
            for (uint32_t k = 0; k <= rc / 4; k++)
                for (int b = 0; b < 4; b++) put((dst & ~3u) + 4 * k + b, host[rbase - HBASE + 4 * k + b], true);
            reg_wr(0x1FC, 0); wait_idle();
            src += rc; dst += rc;
        } while (src < end);
        set_rop(3); set_mode(0); reg_wr(0x38, 0);
    }
    compare("DMA scroll");
    // DMA read edge masks
    for (int i = 0; i < 8; i++) {
        uint32_t d = 0x90000 + (rng() % 0x1000 & ~3u); int n = rng() % 6; uint32_t m = rng() & 0xFFFF;
        for (int k = 0; k < 64; k++) host[k] = rng();
        reg_wr(0x98, HBASE); set_mode(0x17); fb_wr(d, n << 16 | m);
        int R = n + 1;
        for (int k = 0; k < R; k++) {
            int mk = (k == R - 1) ? (m >> 8 & 15) : k == 0 ? (m & 15) : (k == 1 && R >= 3) ? (m >> 4 & 15) : 15;
            for (int b = 0; b < 4; b++) if (mk >> b & 1) put(d + 4 * k + b, host[4 * k + b], true);
        }
        wait_idle();
    }
    set_mode(0); compare("DMA read masks");
    printf("tb_tga: DMA done (%ld DMA cycles)\n", dma_n);

    // ------------------------------------------------ 7. Bt485
    auto bt_wr = [](int rs, int v) { reg_wr(0xC0, rs << 1); reg_wr(0x1F0, ((rs << 1) << 8) | v); };
    auto bt_rd = [](int rs) { reg_wr(0xC0, rs << 1 | 1); return (int)(reg_rd(0x1F0) >> 16 & 0xFF); };
    bt_wr(6, 0xA2); bt_wr(0, 1); bt_wr(10, 0x14); bt_wr(8, 0x40); bt_wr(9, 0x35); bt_wr(2, 0xFF);
    CHECK(bt_rd(6) == 0xA2 && bt_rd(8) == 0x40 && bt_rd(9) == 0x35 && bt_rd(2) == 0xFF, "Bt485 command registers");
    bt_wr(0, 1); CHECK(bt_rd(10) == 0x14, "Bt485 CR3 %02x", bt_rd(10));
    uint32_t pal[256];
    bt_wr(0, 0);
    for (int i = 0; i < 256; i++) {
        pal[i] = rng() & 0xFFFFFF;
        reg_wr(0xC0, 2);
        for (int c = 2; c >= 0; c--) reg_wr(0x1F0, 0x200 | (pal[i] >> (8 * c) & 0xFF));
    }
    bt_wr(3, 0);
    for (int i = 0; i < 256; i++) {
        int rr = bt_rd(1), gg = bt_rd(1), bb = bt_rd(1);
        CHECK((uint32_t)(rr << 16 | gg << 8 | bb) == pal[i], "palette %d reads %02x%02x%02x, wrote %06x", i, rr, gg, bb, pal[i]);
    }
    // the cursor as SRM sets it: an underline at rows 14-15, colour 3 white
    bt_wr(0, 1); bt_wr(10, 0x14); bt_wr(0, 0);
    uint8_t cram[1024];
    for (int i = 0; i < 1024; i++) {
        int row = (i & 511) / 8, byte = i & 7;
        cram[i] = (byte == 0 && (row == 14 || row == 15)) ? 0xFF : (byte == 1 && row == 3 ? 0xA5 : 0);
        if (i >= 512 && row == 3) cram[i] = 0x0F;
        bt_wr(11, cram[i]);
    }
    uint32_t cc[4] = {0, 0x112233, 0x445566, 0xFFFFFF};
    bt_wr(4, 1); for (int c = 1; c < 4; c++) for (int k = 2; k >= 0; k--) bt_wr(5, cc[c] >> (8 * k) & 0xFF);
    bt_wr(7, 1); for (int c = 1; c < 4; c++) { int rr = bt_rd(5), gg = bt_rd(5), bb = bt_rd(5);
        CHECK((uint32_t)(rr << 16 | gg << 8 | bb) == cc[c], "cursor colour %d", c); }
    int cxp = 9 * 10 + 64, cyp = 16 * 5 + 64;
    bt_wr(12, cxp & 0xFF); bt_wr(13, cxp >> 8); bt_wr(14, cyp & 0xFF); bt_wr(15, cyp >> 8);
    bt_wr(0, 0); CHECK(bt_rd(12) == (cxp & 0xFF), "cursor X");
    printf("tb_tga: Bt485 done\n");

    // ------------------------------------------------ 8. a frame: SRM's 1024x768 (switch 8), VVBR 1
    for (uint32_t a = 0x1000; a < 0x1000 + 1028 * 768; a++) {
        uint32_t x = (a - 0x1000) % 1028, y = (a - 0x1000) / 1028;
        poke(a, (x / 8 + y / 8 * 3) & 0xFF ^ (x == y ? 0xFF : 0));
    }
    CHECK(!t->showing_tga, "selector shows the TGA before video is on");
    reg_wr(0x64, 0x86441B01); reg_wr(0x68, 0x06893B00); reg_wr(0x6C, 1); reg_wr(0x70, 1);
    reg_wr(0x7C, 0x00010001);
    long k = 0;
    int f0 = frames;
    while (t->inta_n && k++ < 3000000) cycle();
    CHECK(!t->inta_n, "no end-of-frame interrupt");
    CHECK(reg_rd(0x7C) == 0x00010001, "SISR %08x", reg_rd(0x7C));
    reg_wr(0x7C, 0x00000001); ticks(4);
    CHECK(t->inta_n, "interrupt not cleared");
    // two frames to settle, then capture one
    while (frames < f0 + 3) cycle();
    capture = true; int f1 = frames;
    while (frames < f1 + 1) cycle();
    capture = false;
    CHECK(t->showing_tga, "selector does not show the TGA");
    CHECK(last_w == 1028 && last_h == 768, "frame %dx%d", last_w, last_h);
    {
        long bad = 0;
        for (int y = 0; y < 768; y++) for (int x = 0; x < 1028; x++) {
            uint32_t want = pal[ref[0x1000 + y * 1028 + x]];
            int cx = x - (cxp - 64), cy = y - (cyp - 64);
            if (cx >= 0 && cx < 64 && cy >= 0 && cy < 64) {
                int v = (cram[cy * 8 + cx / 8] >> (7 - cx % 8) & 1) | (cram[512 + cy * 8 + cx / 8] >> (7 - cx % 8) & 1) << 1;
                if (v) want = cc[v];
            }
            if (frame[y * FW + x] != want && bad++ < 5)
                printf("  pixel %d,%d = %06x, expected %06x\n", x, y, frame[y * FW + x], want);
        }
        CHECK(bad == 0, "frame: %ld pixels differ", bad);
    }
    if (ppm) {
        FILE *f = fopen(ppm, "wb");
        if (f) { fprintf(f, "P6\n1028 768\n255\n");
            for (int y = 0; y < 768; y++) for (int x = 0; x < 1028; x++) {
                uint32_t p = frame[y * FW + x]; fputc(p >> 16, f); fputc(p >> 8 & 0xFF, f); fputc(p & 0xFF, f); }
            fclose(f); printf("tb_tga: frame written to %s\n", ppm); }
    }
    // the Display option back to the terminal
    t->gfx = 0; f1 = frames; while (frames < f1 + 1) cycle(); ticks(20000);
    CHECK(!t->showing_tga && t->r == 0x12, "selector does not return to the terminal");
    printf("tb_tga: frame done\n");

    // ------------------------------------------------ 9. flash through the arbiter, the engine and display busy
    {
        std::vector<uint8_t> img(4096);
        for (auto &v : img) v = rng();
        t->dl_index = 0;
        for (int i = 0; i < 4096; i++) {
            while (t->dl_wait) cycle();
            t->dl_wr = 1; t->dl_addr = i; t->dl_data = img[i]; cycle(); t->dl_wr = 0; cycle();
        }
        while (t->dl_wait) cycle();
        t->gfx = 1;
        set_bc(0x5A5A5A5A, 0x5A5A5A5A); set_data(0xFFFFFFFF); set_mode(0x2D);
        for (uint32_t o = 0x100000; o < 0x100000 + 512; o += 32) { fb_wr(o, 2047); ref_fill(o, 2048, 0x2D); }
        long fb_bad = 0;
        auto frd = [&](uint32_t a) {
            t->f_req = 1; t->f_we = 0; t->f_addr = a; long n = 0;
            do { cycle(); } while (!t->f_ack && ++n < 100000);
            t->f_req = 0; uint8_t v = t->f_rdata; cycle(); return v;
        };
        for (int i = 0; i < 4096; i += 37) if (frd(i) != img[i]) fb_bad++;
        t->f_req = 1; t->f_we = 1; t->f_addr = 100; t->f_wdata = 0xC3; { long n = 0; do { cycle(); } while (!t->f_ack && ++n < 100000); }
        t->f_req = 0; cycle(); img[100] = 0xC3;
        if (frd(100) != 0xC3) fb_bad++;
        CHECK(fb_bad == 0, "flash through the arbiter: %ld bad bytes", fb_bad);
        // the LAN mailbox, lowest priority, while the fill still runs
        for (int i = 0; i < 64; i++) {
            bool w = i < 32; int a = (i * 97) % 8192; uint64_t v = rng();
            t->nb_req = 1; t->nb_we = w; t->nb_addr = w ? a : (((i - 32) * 97) % 8192); t->nb_wdata = v;
            long n = 0; do { cycle(); } while (!t->nb_ack && ++n < 100000);
            CHECK(t->nb_ack, "mailbox: no ack");
            if (!w) CHECK(t->nb_rdata == nbm[((i - 32) * 97) % 8192], "mailbox read %d", i);
            t->nb_req = 0; cycle();
        }
        wait_idle(); set_mode(0);
        compare("fill during flash reads");
        for (int i = 0; i < 4096; i++) if ((dw(DBASE + i / 8) >> (8 * (i & 7)) & 0xFF) != img[i]) { CHECK(false, "flash byte %d in DDR3", i); break; }
    }

    printf("tb_tga: %ld cycles, %ld DDR3 reads, %ld writes, %d frames\n", cyc, ddr_reads, ddr_writes, frames);
    printf("tb_tga: %s (%ld failures)\n", fails ? "FAIL" : "PASS", fails);
    delete t;
    return fails ? 1 : 0;
}
