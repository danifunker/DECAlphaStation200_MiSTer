// Bench of the floppy controller (rtl/sio/isa_fdc.v, isa_fdc_img.v;
// docs/design/floppy.md) inside the SIO (rtl/sio/sio82378.v): the ports at
// 3F0h-3F7h through the PCI target bus, IRQ 6 through the 8259 pair and the
// interrupt acknowledge, DMA channel 2 through the SIO's 8237 and its PCI
// master port (a memory model here), and drive A:'s image through a model of
// hps_io's block device (slot 3) with the Main's latency. The images are made
// here (patterned sectors). FD_SPEED=100: the drive runs 100 times faster
// than a real one (a microsecond of its time is a clock).
//
//   make -C verilator tb_fdc
//
// It replays the sequences of DEC's SRM floppy driver (dv_driver.c: the
// density probe from 2.88 MB down, SPECIFY/PERPENDICULAR/CONFIGURE, the DMA
// set-up, track-sized reads) and DROM V1.7's floppy loader (one SENSE
// INTERRUPT after the reset, RECALIBRATE, SEEK, single-sector reads, IRR
// polling), then tests each command, DMA and non-DMA transfers, media change,
// write protect and the error terminations.
#include "Vsio82378.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <initializer_list>

static Vsio82378 *t;
static uint64_t cyc;
static int fails, checks;
static std::vector<uint8_t> mem(1 << 20);   // PCI memory for the DMA master
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ---------------------------------------------------------------- drive A:'s image (hps_io slot 3)
static std::vector<uint8_t> img;
static int hp_st, hp_lat, hp_i, hp_n, hp_sub;
static uint32_t hp_lba;
static bool hp_wr;
static int n_loads, n_writes;
static const int MAIN_LAT = 3000;           // the Main's turnaround, clocks
static uint8_t pat(uint32_t lba, int i) { return (uint8_t)(lba * 7 + i * 13 + (lba >> 5) + (i >> 8) * 0x5A); }
static void hps_step() {
    t->fd_buff_wr = 0;
    switch (hp_st) {
    case 0:
        if (t->fd_rd || t->fd_wr) {
            hp_wr = t->fd_wr; hp_lba = t->fd_lba; hp_n = (t->fd_blk_cnt + 1) * 512; hp_i = 0; hp_sub = 0;
            hp_lat = MAIN_LAT; hp_st = 1;
            if (hp_wr) n_writes++; else n_loads++;
        }
        break;
    case 1: if (--hp_lat == 0) { t->fd_ack = 1; hp_st = 2; } break;
    case 2: {
        size_t at = (size_t)hp_lba * 512 + hp_i;
        if (!hp_wr) {
            if (hp_sub == 0) { t->fd_buff_addr = hp_i; t->fd_buff_dout = at < img.size() ? img[at] : 0; t->fd_buff_wr = 1; }
            if (++hp_sub == 2) { hp_sub = 0; if (++hp_i == hp_n) hp_st = 3; }
        } else {
            if (hp_sub == 0) t->fd_buff_addr = hp_i;
            if (++hp_sub == 3) { if (at < img.size()) img[at] = t->fd_buff_din; hp_sub = 0; if (++hp_i == hp_n) hp_st = 3; }
        }
        break;
    }
    case 3: t->fd_ack = 0; hp_st = 0; break;
    }
}

static void tick() {
    static bool dpend;
    t->dm_ack = 0;
    if (t->dm_req && !dpend) dpend = true;
    else if (t->dm_req && dpend) {
        uint32_t a = t->dm_addr & 0xFFFFC & (mem.size() - 1), q;
        if (t->dm_we) for (int b = 0; b < 4; b++) if (t->dm_be >> b & 1) mem[a + b] = t->dm_wdata >> (8 * b);
        memcpy(&q, &mem[a], 4);
        t->dm_rdata = q; t->dm_ack = 1; dpend = false;
    }
    hps_step();
    t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++;
}
static void wait(uint64_t n) { while (n--) tick(); }

static void mount(size_t bytes, bool ro, int seed = 0) {
    img.assign(bytes, 0);
    for (size_t i = 0; i < bytes; i++) img[i] = pat(i / 512 + seed, i % 512);
    t->fd_size = bytes; t->fd_readonly = ro; t->fd_mounted = 1; tick(); t->fd_mounted = 0;
    wait(200);
}

// ---------------------------------------------------------------- the PCI target bus (as apecs drives it)
static uint32_t pci(int cmd, int dev, uint32_t addr, int be, bool we, uint32_t wd) {
    t->pt_req = 1; t->pt_cmd = cmd; t->pt_dev = dev; t->pt_addr = addr; t->pt_be = be; t->pt_we = we;
    t->pt_wdata = wd; t->pt_sub = cmd == 1;
    t->clk = 0; t->eval();
    uint32_t r = 0xFFFFFFFF;
    if (t->pt_claim) {
        int n = 0;
        for (;;) { tick(); if (t->pt_ack) { r = t->pt_rdata; break; } if (++n > 64) { printf("FAIL: no pt_ack\n"); fails++; break; } }
    }
    t->pt_req = 0; tick();
    return r;
}
static uint8_t inb(int p) { wait(2); return pci(1, 0, p & 0xFFFC, 1 << (p & 3), false, 0) >> (8 * (p & 3)); }
static void outb(int p, uint8_t v) { wait(2); pci(1, 0, p & 0xFFFC, 1 << (p & 3), true, (uint32_t)v << (8 * (p & 3))); }
static uint8_t iack() { return pci(3, 0, 0, 15, false, 0) & 0xFF; }

// ---------------------------------------------------------------- the FDC, as a driver does it
static uint8_t res[16]; static int nres;
static bool cmd(std::initializer_list<int> b) {
    for (int v : b) {
        int n = 0;
        while ((inb(0x3F4) & 0xC0) != 0x80) if (++n > 100000) { printf("FAIL: no RQM for command byte %02x (MSR %02x)\n", v, inb(0x3F4)); fails++; return false; }
        outb(0x3F5, v);
    }
    return true;
}
static int result() {   // the result phase, until RQM && !DIO
    nres = 0;
    for (int n = 0; n < 2000000; n++) {
        uint8_t m = inb(0x3F4);
        if ((m & 0xC0) == 0xC0) { uint8_t v = inb(0x3F5); if (nres < 16) res[nres] = v; nres++; n = 0; }
        else if ((m & 0xC0) == 0x80 && !(m & 0x10)) return nres;
        else wait(20);
    }
    printf("FAIL: result phase hung\n"); fails++;
    return nres;
}
static bool wait_int(uint64_t max = 4000000) {   // IRQ 6 through the 8259, acknowledged and EOIed
    for (uint64_t n = 0; n < max; n++) {
        if (t->intr) { uint8_t v = iack(); outb(0x20, 0x20); return v == 6; }
        tick();
    }
    return false;
}
static void sense(uint8_t &st0, uint8_t &pcn) { cmd({0x08}); result(); st0 = res[0]; pcn = nres > 1 ? res[1] : 0xEE; }
static void dma2(uint32_t addr, int count, bool to_mem) {
    outb(0x0A, 0x06); outb(0x0C, 0);
    outb(0x0B, to_mem ? 0x46 : 0x4A);                 // single, increment, write to memory / read from memory, channel 2
    outb(0x04, addr & 0xFF); outb(0x04, addr >> 8 & 0xFF);
    outb(0x81, addr >> 16 & 0xFF); outb(0x481, addr >> 24 & 0xFF);
    outb(0x0C, 0);
    outb(0x05, (count - 1) & 0xFF); outb(0x05, (count - 1) >> 8 & 0xFF);
    outb(0x0A, 0x02);
}
static void fdc_reset() {
    outb(0x3F2, 0x08); outb(0x3F2, 0x0C);
    CHECK(wait_int(), "reset interrupt");
    uint8_t s, p;
    for (int d = 0; d < 4; d++) { sense(s, p); CHECK(s == (0xC0 | d), "post-reset sense %d: %02x", d, s); }
}
static bool same(uint32_t m, uint32_t lba, int nsec) {
    for (int i = 0; i < nsec * 512; i++) if (mem[m + i] != img[(size_t)lba * 512 + i]) {
        printf("  mismatch at +%d: mem %02x img %02x\n", i, mem[m + i], img[(size_t)lba * 512 + i]); return false; }
    return true;
}
static bool rw(int op, int d, int c, int h, int r, int eot, int dma_addr, int dma_bytes, bool to_mem) {
    if (dma_bytes) dma2(dma_addr, dma_bytes, to_mem);
    cmd({op, (h << 2) | d, c, h, r, 2, eot, 0x1B, 0xFF});
    bool ok = wait_int(20000000);
    CHECK(ok, "the command's interrupt");
    result();
    return ok;
}
static void res7(const char *what, int st0, int st1, int st2, int c, int h, int r) {
    CHECK(nres == 7 && res[0] == st0 && res[1] == st1 && res[2] == st2 && res[3] == c && res[4] == h && res[5] == r && res[6] == 2,
          "%s: result (%d) %02x %02x %02x %02x %02x %02x %02x, want %02x %02x %02x %02x %02x %02x 02", what, nres,
          res[0], res[1], res[2], res[3], res[4], res[5], res[6], st0, st1, st2, c, h, r);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vsio82378;
    t->pirq_n = 15; t->com1_rxd = 1; t->com2_rxd = 1; t->com1_ri_n = 1; t->com2_ri_n = 1;
    t->rst = 1; wait(8); t->rst = 0; wait(4);
    // the 8259s: master vectors 00-07, only IRQ 6 unmasked; edge-triggered
    outb(0x20, 0x11); outb(0x21, 0x00); outb(0x21, 0x04); outb(0x21, 0x01);
    outb(0xA0, 0x11); outb(0xA1, 0x08); outb(0xA1, 0x02); outb(0xA1, 0x01);
    outb(0x21, 0xBF); outb(0xA1, 0xFF);
    uint8_t s0, pc;

    // ------------------------------------------------------------ out of reset, no medium
    printf("-- reset, registers, no medium\n");
    CHECK(inb(0x3F4) == 0x00, "MSR in reset %02x", inb(0x3F4));
    CHECK(inb(0x3F2) == 0x00, "DOR %02x", inb(0x3F2));
    CHECK(inb(0x3F7) & 0x80, "DIR: disk change at power-on");
    fdc_reset();
    CHECK(inb(0x3F4) == 0x80, "MSR idle %02x", inb(0x3F4));
    cmd({0x08}); result(); CHECK(nres == 1 && res[0] == 0x80, "SENSE INTERRUPT with nothing pending: %02x (%d)", res[0], nres);
    cmd({0x10}); result(); CHECK(nres == 1 && res[0] == 0x90, "VERSION %02x", res[0]);
    cmd({0x18}); result(); CHECK(nres == 1 && res[0] == 0x80, "invalid (PART ID) %02x", res[0]);
    cmd({0x03, 0xCF, 0x02});                            // SPECIFY: SRT C (4 ms), HUT F, HLT 1, DMA
    CHECK((inb(0x3F4) & 0xF0) == 0x80, "SPECIFY: no result phase");
    cmd({0x13, 0x00, 0x0B, 0x00});                      // CONFIGURE as SRM: FIFO on, threshold 12, polling on, no implied seek
    cmd({0x12, 0x84});                                  // PERPENDICULAR as SRM
    cmd({0x0E}); result();
    CHECK(nres == 10 && res[4] == 0xCF && res[5] == 0x02 && res[7] == 0x04 && res[8] == 0x0B && res[9] == 0x00,
          "DUMPREG (%d) %02x %02x %02x %02x %02x %02x", nres, res[4], res[5], res[6], res[7], res[8], res[9]);
    cmd({0x94}); result(); CHECK(nres == 1 && res[0] == 0x10, "LOCK %02x", res[0]);
    fdc_reset();
    cmd({0x0E}); result(); CHECK(res[8] == 0x0B && res[7] == 0x84, "CONFIGURE kept under LOCK: %02x %02x", res[8], res[7]);
    cmd({0x14}); result(); CHECK(nres == 1 && res[0] == 0x00, "UNLOCK %02x", res[0]);
    fdc_reset();
    cmd({0x0E}); result(); CHECK(res[8] == 0x20, "CONFIGURE reset without LOCK: %02x", res[8]);
    cmd({0x04, 0x00}); result(); CHECK(nres == 1 && res[0] == 0x78, "SENSE DRIVE STATUS, no medium: %02x", res[0]);
    cmd({0x04, 0x01}); result(); CHECK(nres == 1 && (res[0] & 0x43) == 0x01, "SENSE DRIVE STATUS, drive 1: %02x", res[0]);
    outb(0x3F7, 0x00);                                  // 500 kbps
    rw(0xE6, 0, 0, 0, 1, 18, 0x10000, 512, true);
    res7("READ, no medium", 0x40, 0x01, 0x00, 0, 0, 1);
    CHECK(inb(0x3F7) & 0x80, "DIR: still changed with no medium");

    // ------------------------------------------------------------ a 1.44 MB image
    printf("-- 1.44 MB image: recalibrate, seek, media change, READ ID\n");
    mount(1474560, false);
    outb(0x3F2, 0x1C);                                  // motor A on
    cmd({0x04, 0x00}); result(); CHECK(res[0] == 0x38, "SENSE DRIVE STATUS, medium in: %02x", res[0]);
    CHECK(inb(0x3F7) & 0x80, "DIR: changed after the mount");
    cmd({0x07, 0x00}); CHECK(wait_int(), "recalibrate interrupt");
    sense(s0, pc); CHECK(s0 == 0x20 && pc == 0, "recalibrate %02x %02x", s0, pc);
    CHECK(inb(0x3F7) & 0x80, "DIR: no step at track 0, still changed");
    uint64_t c0 = cyc;
    cmd({0x0F, 0x00, 10});
    { int busy = 0; for (int n = 0; n < 50; n++) if (inb(0x3F4) & 0x01) busy++; CHECK(busy > 40, "D0B while seeking"); }
    CHECK(wait_int(), "seek interrupt");
    uint64_t ds = cyc - c0;
    sense(s0, pc); CHECK(s0 == 0x20 && pc == 10, "seek %02x %02x", s0, pc);
    CHECK(ds > 9 * 4000 && ds < 11 * 4000 + 20000, "seek of 10 steps at 4 ms: %llu clocks", (unsigned long long)ds);
    CHECK(!(inb(0x3F7) & 0x80), "DIR: change cleared by the steps");
    cmd({0xCF, 0x00, 5}); CHECK(wait_int(), "relative seek in"); sense(s0, pc); CHECK(s0 == 0x20 && pc == 15, "relative in %02x %02x", s0, pc);
    cmd({0x8F, 0x04, 3}); CHECK(wait_int(), "relative seek out"); sense(s0, pc); CHECK(s0 == 0x24 && pc == 12, "relative out %02x %02x", s0, pc);
    cmd({0x4A, 0x00}); CHECK(wait_int(), "READ ID interrupt"); result();
    CHECK(nres == 7 && res[0] == 0x00 && res[1] == 0 && res[3] == 12 && res[4] == 0 && res[5] >= 1 && res[5] <= 18 && res[6] == 2,
          "READ ID %02x %02x %02x C%d H%d R%d N%d", res[0], res[1], res[2], res[3], res[4], res[5], res[6]);
    cmd({0x4A, 0x04}); CHECK(wait_int(), "READ ID head 1"); result(); CHECK(res[0] == 0x04 && res[4] == 1, "READ ID head 1: %02x H%d", res[0], res[4]);
    cmd({0x04, 0x00}); result(); CHECK(res[0] == 0x28, "SENSE DRIVE STATUS off track 0: %02x", res[0]);

    // ------------------------------------------------------------ DMA reads
    printf("-- DMA reads\n");
    memset(mem.data(), 0, mem.size());
    c0 = cyc;
    rw(0xE6, 0, 12, 0, 1, 18, 0x20000, 18 * 512, true);
    res7("READ a track (TC at EOT; MT: on to head 1)", 0x00, 0x00, 0x00, 12, 1, 1);
    CHECK(same(0x20000, 12 * 36, 18), "the track's data");
    printf("   a track: %llu clocks (one revolution is 200000)\n", (unsigned long long)(cyc - c0));
    CHECK(cyc - c0 > 18 * 8192 && cyc - c0 < 3 * 200000 + 100000, "a track's read time %llu", (unsigned long long)(cyc - c0));
    CHECK(inb(0x08) & 0x04, "DMA TC status");
    // a single sector: not instant
    c0 = cyc;
    rw(0x66, 0, 12, 0, 7, 18, 0x30000, 512, true);
    res7("READ one sector", 0x00, 0x00, 0x00, 12, 0, 8);
    CHECK(same(0x30000, 12 * 36 + 6, 1), "sector 7");
    CHECK(cyc - c0 > 8192, "a sector takes its data time: %llu", (unsigned long long)(cyc - c0));
    // multi-track: head 0 sectors 17, 18, head 1 sectors 1, 2 (TC after four)
    rw(0xE6, 0, 12, 0, 17, 18, 0x40000, 4 * 512, true);
    res7("READ multi-track", 0x04, 0x00, 0x00, 12, 1, 3);
    CHECK(same(0x40000, 12 * 36 + 16, 4), "multi-track data");
    // TC in the middle of a sector: the rest is not transferred
    memset(&mem[0x50000], 0xAA, 1024);
    rw(0x66, 0, 12, 1, 3, 18, 0x50000, 700, true);
    res7("READ, TC within sector 4", 0x04, 0x00, 0x00, 12, 1, 5);
    CHECK(same(0x50000, 12 * 36 + 18 + 2, 1) && mem[0x50000 + 699] == img[(12 * 36 + 20) * 512 + 699] && mem[0x50000 + 700] == 0xAA,
          "partial transfer");
    // no TC by EOT: end of cylinder
    rw(0x66, 0, 12, 0, 17, 18, 0x60000, 4 * 512, true);
    res7("READ to EOT without TC", 0x40, 0x80, 0x00, 13, 0, 1);

    // ------------------------------------------------------------ errors
    printf("-- errors\n");
    c0 = cyc;
    rw(0x66, 0, 12, 0, 19, 19, 0x60000, 512, true);
    res7("sector 19 of 18", 0x40, 0x04, 0x00, 12, 0, 19);
    CHECK(cyc - c0 > 200000 && cyc - c0 < 3 * 200000 + 50000, "two index pulses: %llu", (unsigned long long)(cyc - c0));
    rw(0x66, 0, 11, 0, 1, 18, 0x60000, 512, true);
    res7("wrong cylinder", 0x40, 0x04, 0x10, 11, 0, 1);
    dma2(0x60000, 512, true); cmd({0x66, 0x00, 12, 1, 1, 2, 18, 0x1B, 0xFF}); CHECK(wait_int(20000000), "interrupt"); result();
    res7("ID head 1 under head 0", 0x40, 0x04, 0x00, 12, 1, 1);
    outb(0x3F7, 0x03);
    rw(0x66, 0, 12, 0, 1, 18, 0x60000, 512, true);
    res7("1 Mbps on a 1.44 MB disk", 0x40, 0x01, 0x00, 12, 0, 1);
    outb(0x3F4, 0x02);                                   // DSR: 250 kbps
    cmd({0x4A, 0x00}); CHECK(wait_int(), "interrupt"); result(); CHECK(res[0] == 0x40 && res[1] == 0x01, "READ ID at 250 kbps: %02x %02x", res[0], res[1]);
    outb(0x3F7, 0x00);
    rw(0x26, 0, 12, 0, 1, 18, 0x60000, 512, true);       // FM
    res7("FM on an MFM disk", 0x40, 0x01, 0x00, 12, 0, 1);
    rw(0x66, 1, 0, 0, 1, 18, 0x60000, 512, true);
    res7("drive 1 (none)", 0x41, 0x01, 0x00, 0, 0, 1);
    cmd({0x07, 0x01}); CHECK(wait_int(), "recalibrate drive 1"); sense(s0, pc); CHECK(s0 == 0x71, "drive 1: no track 0 (EC) %02x", s0);

    // ------------------------------------------------------------ implied seek, writes
    printf("-- implied seek, DMA writes, write protect\n");
    cmd({0x13, 0x00, 0x4B, 0x00});                      // EIS
    rw(0x66, 0, 40, 1, 5, 18, 0x60000, 512, true);
    res7("READ with implied seek", 0x24, 0x00, 0x00, 40, 1, 6);
    CHECK(same(0x60000, 40 * 36 + 18 + 4, 1), "implied seek's sector");
    cmd({0x0E}); result(); CHECK(res[0] == 40, "PCN after the implied seek %d", res[0]);
    for (int i = 0; i < 3 * 512; i++) mem[0x70000 + i] = (uint8_t)(i * 3 + 0x11);
    int w0 = n_writes;
    rw(0xC5, 0, 40, 1, 5, 18, 0x70000, 3 * 512, false);
    res7("WRITE 3 sectors", 0x04, 0x00, 0x00, 40, 1, 8);
    wait(20000);
    CHECK(n_writes > w0, "written back to the image (%d requests)", n_writes - w0);
    { bool ok = true; for (int i = 0; i < 3 * 512; i++) if (img[(40 * 36 + 18 + 4) * 512 + i] != (uint8_t)(i * 3 + 0x11)) ok = false;
      CHECK(ok, "the image holds the written sectors"); }
    memset(&mem[0x80000], 0, 3 * 512);
    rw(0xC6, 0, 40, 1, 5, 18, 0x80000, 3 * 512, true);
    res7("READ back", 0x04, 0x00, 0x00, 40, 1, 8);
    CHECK(!memcmp(&mem[0x80000], &mem[0x70000], 3 * 512), "read back what was written");
    // TC within a written sector: zeros to its end
    for (int i = 0; i < 512; i++) mem[0x71000 + i] = 0x77;
    rw(0x45, 0, 40, 1, 9, 18, 0x71000, 100, false);
    res7("WRITE 100 bytes", 0x04, 0x00, 0x00, 40, 1, 10);
    wait(20000);
    CHECK(img[(40 * 36 + 18 + 8) * 512 + 99] == 0x77 && img[(40 * 36 + 18 + 8) * 512 + 100] == 0x00 && img[(40 * 36 + 18 + 8) * 512 + 511] == 0x00,
          "the rest of a short write is zeros");
    // WRITE DELETED as WRITE; READ DELETED finds a regular sector: CM, ends after it
    rw(0x49, 0, 40, 1, 9, 18, 0x70000, 512, false);
    res7("WRITE DELETED", 0x04, 0x00, 0x00, 40, 1, 10);
    rw(0x4C, 0, 40, 1, 9, 18, 0x81000, 2 * 512, true);
    res7("READ DELETED (a regular data mark)", 0x04, 0x00, 0x40, 40, 1, 10);
    // VERIFY (no DMA), to EOT and by count (EC)
    rw(0x56, 0, 40, 1, 15, 18, 0, 0, true);
    res7("VERIFY to EOT", 0x04, 0x00, 0x00, 41, 1, 1);
    cmd({0x56, 0x84, 40, 1, 2, 2, 18, 0x1B, 3}); CHECK(wait_int(20000000), "interrupt"); result();
    res7("VERIFY 3 sectors (EC)", 0x04, 0x00, 0x00, 40, 1, 5);
    // SCAN EQUAL against what was written
    rw(0x51, 0, 40, 1, 5, 18, 0x70000, 512, false);
    res7("SCAN EQUAL (hit)", 0x04, 0x00, 0x08, 40, 1, 6);
    // write-protected image
    { std::vector<uint8_t> keep = img;
      t->fd_size = img.size(); t->fd_readonly = 1; t->fd_mounted = 1; tick(); t->fd_mounted = 0; wait(200); img = keep; }
    cmd({0x04, 0x00}); result(); CHECK(res[0] & 0x40, "SENSE DRIVE STATUS: write-protected %02x", res[0]);
    rw(0x45, 0, 40, 1, 1, 18, 0x70000, 512, false);
    res7("WRITE, protected", 0x44, 0x02, 0x00, 40, 1, 1);
    CHECK(inb(0x3F7) & 0x80, "DIR: the remount is a media change");
    t->fd_readonly = 0; t->fd_mounted = 1; tick(); t->fd_mounted = 0; wait(200);

    // ------------------------------------------------------------ non-DMA (PIO with interrupts)
    printf("-- non-DMA transfers\n");
    cmd({0x03, 0xCF, 0x03});                            // SPECIFY ND
    outb(0x0A, 0x06);
    cmd({0x66, 0x00, 40, 0, 3, 2, 3, 0x1B, 0xFF});
    {
        int got = 0, ints = 0; bool okd = true; uint64_t lim = cyc + 4000000;
        while (got < 512 && cyc < lim) {
            uint8_t m = inb(0x3F4);
            if ((m & 0xE0) == 0xE0) {
                if (t->intr) ints++;
                uint8_t v = inb(0x3F5);
                if (v != img[(40 * 36 + 2) * 512 + got]) okd = false;
                got++;
            } else wait(5);
        }
        CHECK(got == 512 && okd, "PIO read: %d bytes, %s", got, okd ? "right" : "wrong");
        CHECK(ints > 256, "INT with the bytes (%d of 512 MSR polls saw it)", ints);
        // the PIC: the per-byte interrupts were not acknowledged; drop them
        while (t->intr) { iack(); outb(0x20, 0x20); wait(10); }
        int n = 0; while (!(inb(0x3F4) & 0x40) && n < 100000) { wait(10); n++; }
        result();
        res7("PIO READ (no TC: end of cylinder)", 0x40, 0x80, 0x00, 41, 0, 1);
    }
    cmd({0x45, 0x00, 40, 0, 3, 2, 3, 0x1B, 0xFF});
    {
        int put = 0; uint64_t lim = cyc + 4000000;
        while (put < 512 && cyc < lim) {
            uint8_t m = inb(0x3F4);
            if ((m & 0xE0) == 0xA0) { outb(0x3F5, (uint8_t)(put ^ 0xC3)); put++; }
            else wait(5);
        }
        CHECK(put == 512, "PIO write: %d bytes", put);
        while (t->intr) { iack(); outb(0x20, 0x20); wait(10); }
        int n = 0; while (!(inb(0x3F4) & 0x40) && n < 100000) { wait(10); n++; }
        result();
        res7("PIO WRITE", 0x40, 0x80, 0x00, 41, 0, 1);
        wait(20000);
        bool ok = true; for (int i = 0; i < 512; i++) if (img[(40 * 36 + 2) * 512 + i] != (uint8_t)(i ^ 0xC3)) ok = false;
        CHECK(ok, "PIO write in the image");
    }
    cmd({0x03, 0xCF, 0x02});

    // ------------------------------------------------------------ FORMAT
    printf("-- FORMAT TRACK\n");
    for (int s = 0; s < 18; s++) { mem[0x90000 + 4 * s] = 50; mem[0x90001 + 4 * s] = 1; mem[0x90002 + 4 * s] = s + 1; mem[0x90003 + 4 * s] = 2; }
    cmd({0x0F, 0x04, 50}); CHECK(wait_int(), "interrupt"); sense(s0, pc);
    dma2(0x90000, 72, false);
    c0 = cyc;
    cmd({0x4D, 0x04, 2, 18, 0x54, 0xE5}); CHECK(wait_int(20000000), "format interrupt"); result();
    res7("FORMAT", 0x04, 0x00, 0x00, 50, 1, 18);
    CHECK(cyc - c0 > 200000, "a format takes a revolution: %llu", (unsigned long long)(cyc - c0));
    wait(40000);
    { bool ok = true; for (int i = 0; i < 18 * 512; i++) if (img[(50 * 36 + 18) * 512 + i] != 0xE5) ok = false;
      CHECK(ok, "formatted track filled with E5"); CHECK(img[(50 * 36 + 17) * 512] != 0xE5 && img[(50 * 36 + 36) * 512] != 0xE5, "neighbours untouched"); }

    // ------------------------------------------------------------ other media
    printf("-- 720 KB and 2.88 MB images\n");
    mount(737280, false, 3);
    CHECK(inb(0x3F7) & 0x80, "DIR: changed by the mount");
    cmd({0x0F, 0x00, 5}); CHECK(wait_int(), "interrupt"); sense(s0, pc);
    CHECK(!(inb(0x3F7) & 0x80), "DIR: cleared by a seek");
    rw(0x66, 0, 5, 0, 1, 9, 0x60000, 512, true);
    res7("720 KB at 500 kbps", 0x40, 0x01, 0x00, 5, 0, 1);
    outb(0x3F7, 0x02);
    rw(0x66, 0, 5, 1, 1, 9, 0xA0000, 9 * 512, true);
    res7("720 KB track at 250 kbps", 0x04, 0x00, 0x00, 6, 1, 1);
    CHECK(same(0xA0000, 5 * 18 + 9, 9), "720 KB data");
    cmd({0x4A, 0x00}); CHECK(wait_int(), "interrupt"); result(); CHECK(res[0] == 0 && res[5] >= 1 && res[5] <= 9, "READ ID, 9 sectors: R%d", res[5]);
    mount(2949120, false, 5);
    outb(0x3F7, 0x03);
    cmd({0x0F, 0x00, 70}); CHECK(wait_int(), "interrupt"); sense(s0, pc);
    rw(0x66, 0, 70, 0, 16, 36, 0xB0000, 6 * 512, true);   // across the cache's half (sectors 16-21)
    res7("2.88 MB at 1 Mbps", 0x00, 0x00, 0x00, 70, 0, 22);
    CHECK(same(0xB0000, 70 * 72 + 15, 6), "2.88 MB data");
    outb(0x3F7, 0x00);

    // ------------------------------------------------------------ SRM's dv_driver.c: open (density probe) and a read
    printf("-- SRM's floppy driver: the density probe and track reads\n");
    mount(1474560, false, 9);
    {
        // floppy_devtab: ED {36, srt 9, hut E, rate 3, hlt_dma 3A, DSR 07}, HD {18, C, F, 0, 02, 0C}, DD {9, E, 4, 2, 02, 0E}
        struct { int spt, srt, hut, rate, hlt, dsr; } tab[3] = {{36, 9, 0xE, 3, 0x3A, 7}, {18, 0xC, 0xF, 0, 2, 0xC}, {9, 0xE, 4, 2, 2, 0xE}};
        int found = -1;
        for (int i = 0; i < 3 && found < 0; i++) {
            outb(0x3F2, 0x08); outb(0x3F2, 0x0C); CHECK(wait_int(), "enable_controller interrupt");   // (no SENSE INTERRUPT: SRM's)
            outb(0x3F4, tab[i].dsr); outb(0x3F7, tab[i].rate);
            cmd({0x03, tab[i].srt << 4 | tab[i].hut, tab[i].hlt});
            cmd({0x12, 0x84});
            outb(0x3F2, 0x1C);
            for (int k = 0; k < 2; k++) {
                cmd({0x07, 0}); CHECK(wait_int(), "SRM's recalibrate interrupt (density %d)", i);
                sense(s0, pc); if (!(s0 & 0xC0) && pc == 0) break;
            }
            CHECK((s0 & 0xF0) == 0x20, "recalibrate after the reset: %02x", s0);
            for (int retry = 0; retry < 3; retry++) {
                cmd({0x13, 0x00, 0x0B, 0x00});
                outb(0x08, 0); outb(0xD0, 0); outb(0xD6, 0xC0); outb(0x0B, 0x06); outb(0x40B, 0x02);    // jensen_dma_control
                outb(0x0C, 0); outb(0x04, 0x00); outb(0x04, 0x00); outb(0x81, 0x0C); outb(0x481, 0x00);
                outb(0x0C, 0); outb(0x05, 0xFF); outb(0x05, 0x01); outb(0xD4, 0); outb(0x0A, 0x02);
                cmd({0x66, 0x00, 0, 0, 1, 2, tab[i].spt, 0x1B, 0xFF});
                CHECK(wait_int(20000000), "interrupt"); result();
                if (nres == 7 && !(res[0] & 0xC0) && !res[1] && !res[2]) { found = i; break; }
            }
        }
        CHECK(found == 1, "SRM's probe finds HD (%d)", found);
        CHECK(same(0xC0000, 0, 1), "boot block");
        // a read of the rest of track 0 head 0 and a track crossing, as ide_common_io splits them
        memset(&mem[0xC0000], 0, 0x8000);
        uint32_t lbn = 1, left = 40; uint32_t m = 0xC0000; int cur_cyl = 0;
        while (left) {
            int cyl = lbn / 36, head = lbn % 36 / 18, sec = lbn % 18, n = 18 - sec; if ((uint32_t)n > left) n = left;
            if (cyl != cur_cyl) { cmd({0x0F, head << 2, cyl}); CHECK(wait_int(), "interrupt"); sense(s0, pc); cur_cyl = cyl; }
            cmd({0x13, 0x00, 0x0B, 0x00});
            dma2(m, n * 512, true);
            cmd({0x66, head << 2, cyl, head, sec + 1, 2, 18, 0x1B, 0xFF}); CHECK(wait_int(20000000), "interrupt"); result();
            CHECK(!(res[0] & 0xC0) && !res[1] && !res[2], "SRM read lbn %u x %d: %02x %02x %02x", lbn, n, res[0], res[1], res[2]);
            lbn += n; left -= n; m += n * 512;
        }
        CHECK(same(0xC0000, 1, 40), "SRM's 40 blocks");
    }

    // ------------------------------------------------------------ DROM V1.7's floppy loader (0x43510)
    printf("-- DROM V1.7's floppy loader: one SENSE INTERRUPT after the reset, IRR polling\n");
    {
        outb(0x3F4, 0x80); wait(100); outb(0x3F2, 0x0C);                    // DSR reset, DOR
        int n = 0; while (!(inb(0x3F4) & 0x80) && n < 1000) n++;
        outb(0x3F7, 0x00);
        auto irr6 = [&](int lim) { for (int k = 0; k < lim; k++) { outb(0x20, 0x0A); if (inb(0x20) & 0x40) return true; } return false; };
        outb(0x21, 0xFF);                                                  // masked, as the DROM has it
        CHECK(irr6(100000), "IRR 6 after the reset");
        cmd({0x08}); result(); CHECK(res[0] == 0xC0, "the one SENSE INTERRUPT: %02x", res[0]);
        CHECK(!irr6(10), "IRR 6 drops with the line");
        cmd({0x03, 0xCF, 0x02});
        outb(0x3F2, 0x1C);
        cmd({0x07, 0x00}); CHECK(irr6(1000000), "IRR 6 after RECALIBRATE");
        cmd({0x08}); result(); CHECK(res[0] == 0x20 && res[1] == 0, "RECALIBRATE's sense (not a reset status): %02x %02x", res[0], res[1]);
        cmd({0x0F, 0x00, 1}); CHECK(!irr6(3), "no IRR 6 at once"); CHECK(irr6(1000000), "IRR 6 after SEEK");
        cmd({0x08}); result(); CHECK(res[0] == 0x20 && res[1] == 1, "SEEK's sense %02x %02x", res[0], res[1]);
        outb(0xD0, 0); outb(0x08, 0); outb(0xD6, 0xC0); outb(0x0B, 0x46); outb(0x40B, 2); outb(0x0C, 0);
        outb(0x04, 0x00); outb(0x04, 0x00); outb(0x81, 0x0D); outb(0x481, 0x00); outb(0x0C, 0);
        outb(0x05, 0xFF); outb(0x05, 0x01); outb(0x405, 0); outb(0xD4, 0); outb(0x0A, 2);
        cmd({0x66, 0x00, 1, 0, 3, 2, 18, 0x1B, 0xFF});
        CHECK(!irr6(3), "no IRR 6 at once"); CHECK(irr6(2000000), "IRR 6 after READ");
        result(); res7("DROM's READ", 0x00, 0x00, 0x00, 1, 0, 4);
        CHECK(same(0xD0000, 36 + 2, 1), "DROM's sector");
        outb(0x21, 0xBF);
    }

    printf("%s: %d checks, %d failures (%llu cycles; %d loads, %d write-backs)\n", fails ? "FAIL" : "PASS", checks, fails,
           (unsigned long long)cyc, n_loads, n_writes);
    t->final();
    delete t;
    return fails ? 1 : 0;
}
