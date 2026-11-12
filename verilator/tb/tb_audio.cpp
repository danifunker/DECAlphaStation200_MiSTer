// Unit bench of rtl/audio (the sound card and the mix): as200_audio on the
// 82378's xio bus (verilator/tb/tb_audio_top.v), driven through the SIO's
// PCI target the way tb_sio.cpp does it, so the real 8237 moves the samples.
//
//   the WSS ID and command register; the AD1848's INIT, index and indirect
//   registers as Linux's ad1848_detect probes them (I0/I1 patterns, I12 read
//   only and 0Ah, I16-I31 aliasing, no MODE2), MCE gating of I8, the
//   autocalibration; playback by DMA channel 1 (16-bit stereo, 48 kHz) with
//   the frames checked as they come out, the counter's interrupt on IRQ9
//   through the 8259s, INT cleared by R2; capture by DMA channel 0 (silence
//   into memory); the OPL's status (an OPL2), its timer 1, a tone; the mix
//   (CD alone through the mute mask, the speaker's level, saturation both
//   ways).
//
//   make -C verilator tb_audio
#include "Vtb_audio_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>

static Vtb_audio_top *t;
static uint64_t cyc;
static int fails, checks;
static std::vector<uint8_t> mem(1 << 20);

static void tick() {
    static bool dpend;
    t->dm_ack = 0;
    if (t->dm_req && !dpend) dpend = true;
    else if (t->dm_req && dpend) {
        uint32_t a = t->dm_addr & 0xFFFFC & (mem.size() - 1), q;
        if (t->dm_we)
            for (int b = 0; b < 4; b++) if (t->dm_be >> b & 1) mem[a + b] = t->dm_wdata >> (8 * b);
        memcpy(&q, &mem[a], 4);
        t->dm_rdata = q; t->dm_ack = 1; dpend = false;
    }
    t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++;
}
static void wait(uint64_t n) { while (n--) tick(); }

#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint32_t pci(int cmd, uint32_t addr, int be, bool we, uint32_t wd) {
    t->pt_req = 1; t->pt_cmd = cmd; t->pt_dev = 0; t->pt_addr = addr; t->pt_be = be; t->pt_we = we;
    t->pt_wdata = wd; t->pt_sub = cmd == 1;
    t->clk = 0; t->eval();
    uint32_t r = 0xFFFFFFFF;
    if (t->pt_claim) {
        for (int n = 0;; n++) {
            tick();
            if (t->pt_ack) { r = t->pt_rdata; break; }
            if (n > 64) { printf("FAIL: no pt_ack\n"); fails++; break; }
        }
    }
    t->pt_req = 0; tick();
    return r;
}
static uint8_t inb(int p) { return pci(1, p & 0xFFFC, 1 << (p & 3), false, 0) >> (8 * (p & 3)); }
static void outb(int p, uint8_t v) { pci(1, p & 0xFFFC, 1 << (p & 3), true, (uint32_t)v << (8 * (p & 3))); }
static uint8_t iack() { return pci(3, 0, 15, false, 0) & 0xFF; }

static const int WSS = 0x530;
static void ad_w(int i, uint8_t v, bool mce = false) { outb(WSS + 4, (mce ? 0x40 : 0) | i); outb(WSS + 5, v); }
static uint8_t ad_r(int i, bool mce = false) { outb(WSS + 4, (mce ? 0x40 : 0) | i); return inb(WSS + 5); }
static void opl_w(int r, uint8_t v) { outb(0x388, r); outb(0x389, v); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_audio_top;
    t->rst = 1; wait(8); t->rst = 0; wait(2);

    // ------------------------------------------------------------ the WSS interface
    printf("-- WSS ID, AD1848 INIT and registers\n");
    CHECK((inb(WSS + 3) & 0x3F) == 0x04, "WSS version %02x", inb(WSS + 3));
    CHECK((inb(WSS + 3) & 0x80) == 0, "ChannelAvail set");
    // NT 4.0 sndsys.sys's interrupt scan: IRQSENS with each IRQSEL, bit 6 set = a free line
    for (int s = 1; s <= 4; s++) {
        outb(WSS + 0, 0x40 | s << 3);
        CHECK(inb(WSS + 3) & 0x40, "IRQSENS, IRQSEL %d: status %02x", s, inb(WSS + 3));
        CHECK((inb(WSS + 3) & 0x3F) == 0x04, "version under IRQSENS %02x", inb(WSS + 3));
    }
    outb(WSS + 0, 0x40);
    CHECK(!(inb(WSS + 3) & 0x40), "IRQSENS with no line selected");
    outb(WSS + 0, 0x10);
    CHECK(!(inb(WSS + 3) & 0x40), "bit 6 without IRQSENS and no interrupt");
    outb(WSS + 0, 0x00);
    CHECK(inb(WSS + 4) == 0x80, "INIT after reset: %02x", inb(WSS + 4));
    wait(2100);
    CHECK(inb(WSS + 4) == 0x40, "R0 after INIT %02x (MCE set)", inb(WSS + 4));
    CHECK(inb(0x52F) == 0xFF && inb(0x538) == 0xFF, "decode outside the card");
    // Linux ad1848_detect's probes
    ad_w(0, 0xAA); ad_w(1, 0x45);
    CHECK(ad_r(0) == 0xAA && ad_r(1) == 0x45, "I0/I1 %02x %02x", ad_r(0), ad_r(1));
    ad_w(0, 0x45); ad_w(1, 0xAA);
    CHECK(ad_r(0) == 0x45 && ad_r(1) == 0xAA, "I0/I1 swapped %02x %02x", ad_r(0), ad_r(1));
    ad_w(0, 0xFF); CHECK(ad_r(0) == 0xEF, "I0 bit 4 read only: %02x", ad_r(0));
    uint8_t i12 = ad_r(12);
    CHECK(i12 == 0x0A, "I12 %02x", i12);
    ad_w(12, ~i12 & 0x0F); CHECK(ad_r(12) == 0x0A, "I12 written");
    ad_w(12, 0x40); CHECK((ad_r(12) & 0xC0) == 0, "MODE2 stuck: an AD1848 has none");
    for (int i = 0; i < 16; i++) CHECK(ad_r(i) == ad_r(i + 16), "I%d != I%d", i, i + 16);
    CHECK(ad_r(6) == 0x80 && ad_r(7) == 0x80 && ad_r(9) == 0x08 && ad_r(2) == 0x88, "reset values");
    // I8 only under MCE; I9's PEN/CEN outside it
    outb(WSS + 4, 0x08); outb(WSS + 5, 0x5C);
    CHECK(ad_r(8) == 0x00, "I8 written without MCE: %02x", ad_r(8));
    ad_w(8, 0x5C, true);
    CHECK(ad_r(8, true) == 0x5C, "I8 under MCE %02x", ad_r(8, true));
    ad_w(9, 0xC0); CHECK(ad_r(9) == 0x08, "I9 PPIO/CPIO outside MCE: %02x", ad_r(9));
    // leaving MCE with ACAL: ACI (I11 bit 5) for a while
    outb(WSS + 4, 0x0B);
    CHECK(inb(WSS + 5) & 0x20, "ACI not set: %02x", inb(WSS + 5));
    wait(21000);
    CHECK(!(inb(WSS + 5) & 0x20), "ACI still set");
    CHECK(inb(WSS + 4) == 0x0B, "R0 %02x", inb(WSS + 4));

    // ------------------------------------------------------------ DMA playback
    printf("-- playback: DMA 1, 16-bit stereo 48 kHz, IRQ 9\n");
    // 8259s: vectors 00-0F, IRQ9 unmasked
    outb(0x20, 0x11); outb(0x21, 0x00); outb(0x21, 0x04); outb(0x21, 0x01);
    outb(0xA0, 0x11); outb(0xA1, 0x08); outb(0xA1, 0x02); outb(0xA1, 0x01);
    outb(0x21, 0xFB); outb(0xA1, 0xFD);
    const int N = 32, BUF = 0x12000;
    int16_t smp[N][2];
    for (int k = 0; k < N; k++) {
        smp[k][0] = 0x0400 * k + 0x123; smp[k][1] = -(0x0300 * k + 0x45);
        memcpy(&mem[BUF + 4 * k], smp[k], 4);
    }
    outb(WSS + 0, 0x12);                       // IRQ9, DMA 1
    outb(0x0A, 0x05); outb(0x0C, 0);           // mask channel 1, clear the flip-flop
    outb(0x0B, 0x59);                          // single, auto-initialise, read, channel 1
    outb(0x02, BUF & 0xFF); outb(0x02, (BUF >> 8) & 0xFF); outb(0x83, BUF >> 16);
    outb(0x03, (4 * N - 1) & 0xFF); outb(0x03, (4 * N - 1) >> 8);
    outb(0x0A, 0x01);
    ad_w(6, 0x00); ad_w(7, 0x00); ad_w(10, 0x02);
    ad_w(15, 7); ad_w(14, 0);                  // 8 frames an interrupt
    ad_w(9, 0x01);                             // PEN
    CHECK(t->dreq & 0x02, "no DREQ1 after PEN (dreq %02x)", t->dreq);
    int got = 0, bad = 0, irqs = 0;
    int16_t pl = t->wss_l, pr = t->wss_r;
    bool irq_prev = false;
    uint64_t t_end = cyc + 2100 * (N + 2);
    while (cyc < t_end) {
        tick();
        int16_t l = t->wss_l, r = t->wss_r;
        if (l != pl || r != pr) {
            if (got < N && (l != smp[got][0] || r != smp[got][1])) {
                if (bad++ < 4) printf("  frame %d: %d %d, want %d %d\n", got, l, r, smp[got][0], smp[got][1]);
            }
            got++; pl = l; pr = r;
        }
        bool irq = t->irq >> 9 & 1;
        if (irq && !irq_prev) {
            irqs++;
            if (irqs == 1) {
                CHECK(inb(WSS + 6) & 1, "INT not in R2");
                CHECK(inb(WSS + 3) & 0x40, "IrqSense clear");
                for (int n = 0; n < 20 && !t->intr; n++) tick();
                CHECK(t->intr, "no CPU interrupt from IRQ9");
                CHECK(iack() == 0x09, "vector");
                outb(0xA0, 0x20); outb(0x20, 0x20);
            }
            outb(WSS + 6, 0);                  // clear INT
            CHECK(!(inb(WSS + 6) & 1), "INT after R2 write");
        }
        irq_prev = t->irq >> 9 & 1;
    }
    CHECK(got >= N && bad == 0, "frames %d, wrong %d", got, bad);
    CHECK(irqs >= 4, "interrupts %d", irqs);
    // attenuation and mute
    ad_w(6, 0x04); ad_w(7, 0x80);
    wait(2 * 2100);
    {
        int16_t l = t->wss_l, r = t->wss_r;
        bool ok = false;
        for (int k = 0; k < N; k++) if (l == smp[k][0] / 2 || l == (smp[k][0] >> 1)) ok = true;
        CHECK(ok, "I6 6 dB: %d", l);
        CHECK(r == 0, "I7 mute: %d", r);
    }
    ad_w(9, 0x00);                             // PEN off
    wait(10);
    CHECK(t->dreq == 0 && t->wss_l == 0, "after PEN off: dreq %02x out %d", t->dreq, t->wss_l);
    outb(WSS + 6, 0);

    // ------------------------------------------------------------ capture
    printf("-- capture: DMA 0, silence\n");
    const int CB = 0x14000, CN = 64;
    for (int i = 0; i < CN + 16; i++) mem[CB + i] = 0x5A;
    outb(WSS + 0, 0x15);                       // IRQ9, play 0 / capture 0
    outb(0x0A, 0x04); outb(0x0C, 0);
    outb(0x0B, 0x44);                          // single, write, channel 0
    outb(0x00, CB & 0xFF); outb(0x00, (CB >> 8) & 0xFF); outb(0x87, CB >> 16);
    outb(0x01, CN - 1); outb(0x01, 0);
    outb(0x0A, 0x00);
    ad_w(8, 0x0C, true);                       // 8-bit unsigned mono 48 kHz
    outb(WSS + 4, 0x00);
    wait(21000);                               // the autocalibration
    ad_w(15, CN - 1); ad_w(14, 0);
    ad_w(9, 0x02);                             // CEN
    wait(2100 * (CN + 4));
    int cap_ok = 0;
    for (int i = 0; i < CN; i++) cap_ok += mem[CB + i] == 0x80;
    CHECK(cap_ok == CN, "captured %d of %d bytes as 80h", cap_ok, CN);
    CHECK(mem[CB + CN] == 0x5A, "capture past the count");
    CHECK(inb(WSS + 6) & 1, "no INT at the capture count's end");
    ad_w(9, 0x00); outb(WSS + 6, 0);

    // ------------------------------------------------------------ OPL
    printf("-- OPL (an OPL2)\n");
    uint8_t s0 = inb(0x388);
    CHECK((s0 & 0xE0) == 0 && (s0 & 0x06) == 0x06, "OPL status %02x", s0);
    opl_w(4, 0x60); opl_w(4, 0x80);
    wait(6000);
    CHECK((inb(0x388) & 0xE0) == 0, "flags after reset %02x", inb(0x388));
    opl_w(2, 0xFF); opl_w(4, 0x21);
    wait(20000);                               // the queue
    wait(10000);                               // timer 1: 80 us
    CHECK((inb(0x388) & 0xE0) == 0xC0, "timer 1 flag %02x", inb(0x388));
    opl_w(4, 0x60); opl_w(4, 0x80);
    static const uint8_t tone[][2] = {
        {0x01, 0x20}, {0x20, 0x01}, {0x40, 0x10}, {0x60, 0xF0}, {0x80, 0x77}, {0xA0, 0x98},
        {0x23, 0x01}, {0x43, 0x00}, {0x63, 0xF0}, {0x83, 0x77}, {0xC0, 0x01}, {0xB0, 0x31},
    };
    for (auto &w : tone) opl_w(w[0], w[1]);
    opl_w(0x05, 0x01);                         // bank 1 (38Ah) would be the OPL3's: dropped
    outb(0x38A, 0x05); outb(0x38B, 0x01);
    wait(40000);
    int16_t fmin = 0, fmax = 0, fprev = t->fm;
    int fstep = 0;
    FILE *fd = getenv("FM_DUMP") ? fopen(getenv("FM_DUMP"), "wb") : NULL;   // the tone at 48 kHz, for a spectrum
    for (int i = 0; i < (fd ? 12000000 : 400000); i++) {
        tick();
        int16_t v = t->fm;
        if (v < fmin) fmin = v;
        if (v > fmax) fmax = v;
        if (abs(v - fprev) > fstep) fstep = abs(v - fprev);
        fprev = v;
        if (fd && (i + 1LL) * 48 / 100000 != i * 48LL / 100000) fwrite(&v, 2, 1, fd);   // every 2083.3 clocks
    }
    if (fd) fclose(fd);
    CHECK(fmax - fmin > 1000, "FM tone range %d..%d", fmin, fmax);
    CHECK(fstep <= 4, "FM output moves in steps of %d (a line between the chip's samples)", fstep);
    printf("   FM tone %d..%d\n", fmin, fmax);
    opl_w(0xB0, 0x11);                         // key off

    // ------------------------------------------------------------ the mix
    printf("-- mix\n");
    t->mute = 0xB;                             // the CD alone
    t->cd_l = 12345; t->cd_r = (uint16_t)-2345; t->cd_stb = 1; tick(); t->cd_stb = 0;
    wait(2 * 2100);
    CHECK((int16_t)t->aud_l == 12345 && (int16_t)t->aud_r == -2345, "CD %d %d", (int16_t)t->aud_l, (int16_t)t->aud_r);
    t->mute = 0x7; t->spk_force = 1;           // the speaker alone, held high
    wait(3 * 2100);
    CHECK(abs((int16_t)t->aud_l - 8192) < 16, "speaker level %d", (int16_t)t->aud_l);
    t->spk_force = 0; wait(3 * 2100);
    CHECK(t->aud_l == 0, "speaker low %d", (int16_t)t->aud_l);
    // the speaker through the 8254: counter 2 at ~1 kHz, port 61 bits 0-1
    outb(0x43, 0xB6); outb(0x42, 0xA9); outb(0x42, 0x04);
    outb(0x61, inb(0x61) | 3);
    int16_t smin = 32767, smax = -32768;
    for (int i = 0; i < 300000; i++) {
        tick();
        int16_t v = t->aud_l;
        if (v < smin) smin = v;
        if (v > smax) smax = v;
    }
    CHECK(smin < 100 && smax > 8000, "8254 speaker %d..%d", smin, smax);
    outb(0x61, inb(0x61) & ~3);
    t->mute = 0;
    // the lone mixer: sums and saturation
    auto mx = [&](int a, int b, int c, int s) {
        t->mx_a_l = a; t->mx_a_r = -a; t->mx_b = b; t->mx_c_l = c; t->mx_c_r = -c; t->mx_spk = s;
        t->mx_c_stb = 1; tick(); t->mx_c_stb = 0;
        wait(3 * 2100);
    };
    mx(1000, 2000, 300, 0);
    CHECK((int16_t)t->mx_l == 3300 && (int16_t)t->mx_r == 700, "sum %d %d", (int16_t)t->mx_l, (int16_t)t->mx_r);
    mx(30000, 30000, 0, 0);
    CHECK(t->mx_l == 0x7FFF, "saturation + %d", (int16_t)t->mx_l);
    CHECK((int16_t)t->mx_r == 0, "-a+b %d", (int16_t)t->mx_r);
    mx(-30000, -30000, -30000, 1);
    CHECK(t->mx_l == 0x8000, "saturation - %d", (int16_t)t->mx_l);
    CHECK(t->mx_r == 0x7FFF, "saturation + (right) %d", (int16_t)t->mx_r);

    printf("%s: %d checks, %d failed (%llu cycles)\n", fails ? "FAIL" : "PASS", checks, fails, (unsigned long long)cyc);
    delete t;
    return fails ? 1 : 0;
}
