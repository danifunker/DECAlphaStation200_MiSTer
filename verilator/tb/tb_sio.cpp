// Unit bench of rtl/sio/sio82378.v (the 82378 SIO and its ISA devices),
// driven through the PCI target bus the way rtl/apecs/apecs.v drives it
// (docs/design/pci.md 2): configuration reads and writes of device 7, ISA
// port accesses (byte lane = port[1:0], as the CPU's sparse I/O space makes
// them), the interrupt acknowledge. Where DROM V1.7's POST tests touch a
// device, the bench replays the DROM's own access sequence
// (docs/design/sio.md 3) before testing more of the device.
//
//   make -C verilator tb_sio
#include "Vsio82378.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>

static Vsio82378 *t;
static uint64_t cyc;
static int fails, checks;
static std::vector<uint8_t> mem(1 << 20);   // PCI memory for the DMA master

static void tick() {
    // the DMA master port: answer the cycle after a request (like apecs)
    static bool dpend;
    t->dm_ack = 0;
    if (t->dm_req && !dpend) dpend = true;
    else if (t->dm_req && dpend) {
        uint32_t a = t->dm_addr & 0xFFFFC & (mem.size() - 1), q;
        memcpy(&q, &mem[a], 4);
        if (t->dm_we) {
            for (int b = 0; b < 4; b++) if (t->dm_be >> b & 1) mem[a + b] = t->dm_wdata >> (8 * b);
            memcpy(&q, &mem[a], 4);
        }
        t->dm_rdata = q; t->dm_ack = 1; dpend = false;
    }
    t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++;
}
static void wait(uint64_t n) { while (n--) tick(); }

#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// one PCI target transaction; returns the read data (all ones on a master abort)
static uint32_t pci(int cmd, int dev, uint32_t addr, int be, bool we, uint32_t wd, bool *claimed = nullptr) {
    t->pt_req = 1; t->pt_cmd = cmd; t->pt_dev = dev; t->pt_addr = addr; t->pt_be = be; t->pt_we = we;
    t->pt_wdata = wd; t->pt_sub = cmd == 1;          // nothing else on this bus claims I/O
    t->clk = 0; t->eval();
    bool c = t->pt_claim;
    if (claimed) *claimed = c;
    uint32_t r = 0xFFFFFFFF;
    if (c) {
        int n = 0;
        for (;;) {
            tick();
            if (t->pt_ack) { r = t->pt_rdata; break; }
            if (++n > 64) { printf("FAIL: no pt_ack (cmd %d addr %x)\n", cmd, addr); fails++; break; }
        }
    }
    t->pt_req = 0; tick();
    return r;
}
static uint32_t cfg_rd(int reg, int be = 15, int dev = 7) { return pci(0, dev, reg & 0x7FC, be, false, 0); }
static void cfg_wr(int reg, int be, uint32_t v) { pci(0, 7, reg & 0x7FC, be, true, v); }
// an ISA byte at port p: lane p & 3, as sparse I/O makes it
static uint8_t inb(int p) { return pci(1, 0, p & 0xFFFC, 1 << (p & 3), false, 0) >> (8 * (p & 3)); }
static void outb(int p, uint8_t v) { pci(1, 0, p & 0xFFFC, 1 << (p & 3), true, (uint32_t)v << (8 * (p & 3))); }
static uint8_t iack() { return pci(3, 0, 0, 15, false, 0) & 0xFF; }

static void rtc_wr(int i, uint8_t v) { outb(0x70, i); outb(0x71, v); }
static uint8_t rtc_rd(int i) { outb(0x70, i); return inb(0x71); }
static int kbc_wait_ibf() { int n = 0; while (inb(0x64) & 2) if (++n > 1000) return -1; return 0; }
static int kbc_read(int timeout = 200000) {
    for (int n = 0; n < timeout; n++) { if (inb(0x64) & 1) return inb(0x60); wait(20); }
    return -1;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vsio82378;
    t->pirq_n = 15; t->com1_rxd = 1; t->com2_rxd = 1; t->com1_ri_n = 1; t->com2_ri_n = 1;
    t->rst = 1; wait(8); t->rst = 0; wait(2);

    // ------------------------------------------------------------ configuration space
    printf("-- configuration space (DROM 82378 test)\n");
    // DROM V1.7 0x428bc: a byte read of register 0 at 1.E007.0000, the low 16 bits compared
    uint32_t id = cfg_rd(0, 1);
    CHECK((id & 0xFFFF) == 0x8086, "vendor %08x", id);
    CHECK(id == 0x04848086, "id %08x", id);
    CHECK(cfg_rd(8) == 0x00000043, "revision/class %08x", cfg_rd(8));
    CHECK(cfg_rd(4) == 0x02000007, "command/status %08x", cfg_rd(4));
    CHECK(cfg_rd(0x40) == 0x00040020, "40-43 %08x", cfg_rd(0x40));
    CHECK(cfg_rd(0x44) == 0x000F1000, "44-47 %08x", cfg_rd(0x44));
    CHECK(cfg_rd(0x48) == 0x0F100001, "48-4B %08x", cfg_rd(0x48));
    CHECK(cfg_rd(0x4C) == 0x4F074056, "4C-4F %08x", cfg_rd(0x4C));
    CHECK(cfg_rd(0x60) == 0x80808080, "PIRQ route %08x", cfg_rd(0x60));
    CHECK(cfg_rd(0xA0) == 0x00000008, "A0 %08x", cfg_rd(0xA0));
    // DROM V1.7 0x428e0-0x42978: register 45h (byte lane 1 of 44h): save, AAh, 55h, restore
    {
        uint32_t save = cfg_rd(0x44, 2);
        cfg_wr(0x44, 2, 0xAA << 8); uint32_t r1 = cfg_rd(0x44, 2);
        cfg_wr(0x44, 2, 0x55 << 8); uint32_t r2 = cfg_rd(0x44, 2);
        cfg_wr(0x44, 2, save);
        CHECK(((r1 >> 8) & 0xFF) == 0xAA && ((r2 >> 8) & 0xFF) == 0x55, "45h: %08x %08x", r1, r2);
        CHECK(cfg_rd(0x44) == 0x000F1000, "45h restored %08x", cfg_rd(0x44));
    }
    // read-only and reserved bits
    cfg_wr(0, 15, 0); CHECK(cfg_rd(0) == 0x04848086, "ID writable");
    cfg_wr(0x60, 15, 0xFFFFFFFF); CHECK(cfg_rd(0x60) == 0x8F8F8F8F, "PIRQ mask %08x", cfg_rd(0x60));
    cfg_wr(0x60, 15, 0x80808080);
    // other devices and functions are not ours
    bool cl;
    pci(0, 6, 0, 15, false, 0, &cl); CHECK(!cl, "claimed device 6");
    pci(0, 7, 0x100, 15, false, 0, &cl); CHECK(!cl, "claimed function 1");
    pci(2, 0, 0xA0000, 15, false, 0, &cl); CHECK(!cl, "claimed memory");

    // ------------------------------------------------------------ ISA decode
    printf("-- ISA decode\n");
    CHECK(inb(0x530) == 0xFF, "unclaimed port %02x", inb(0x530));
    // a longword I/O access is four ISA byte cycles: the S/G descriptor pointer of channel 0
    pci(1, 0, 0x420, 15, true, 0x12345678);
    CHECK(pci(1, 0, 0x420, 15, false, 0) == 0x12345678, "dword I/O %08x", pci(1, 0, 0x420, 15, false, 0));
    CHECK(inb(0x422) == 0x34, "S/G pointer byte 2");
    // xio: an outside device
    t->xio_claim = 0; t->xio_rdata = 0x5A;
    CHECK(inb(0x388) == 0xFF, "xio not claimed");

    // ------------------------------------------------------------ 8259s
    printf("-- 8259 pair, PIRQ routing, interrupt acknowledge\n");
    outb(0x20, 0x11); outb(0x21, 0x00); outb(0x21, 0x04); outb(0x21, 0x01);   // master: vectors 00-07
    outb(0xA0, 0x11); outb(0xA1, 0x08); outb(0xA1, 0x02); outb(0xA1, 0x01);   // slave: 08-0F
    outb(0x21, 0xFB); outb(0xA1, 0xFF);
    wait(2);
    CHECK(!t->intr, "intr with all masked");
    CHECK(inb(0x21) == 0xFB && inb(0xA1) == 0xFF, "OCW1 read back %02x %02x", inb(0x21), inb(0xA1));
    CHECK(iack() == 0x07, "spurious vector");
    // a PCI interrupt: PIRQ3 (the 53C810) routed to IRQ11, level (ELCR 4D1 bit 3)
    cfg_wr(0x60, 8, 0x0B000000);
    outb(0x4D1, 0x08);
    CHECK(inb(0x4D1) == 0x08, "ELCR %02x", inb(0x4D1));
    outb(0xA1, 0xF7);
    t->pirq_n = 0x7; wait(4);
    CHECK(t->intr, "no intr for PIRQ3 -> IRQ11");
    outb(0xA0, 0x0A); CHECK(inb(0xA0) == 0x08, "slave IRR %02x", inb(0xA0));
    CHECK(iack() == 0x0B, "vector for IRQ11");
    outb(0xA0, 0x0B); CHECK(inb(0xA0) == 0x08, "slave ISR %02x", inb(0xA0));
    wait(2);
    CHECK(!t->intr, "intr while IRQ11 in service");
    t->pirq_n = 0xF;
    outb(0xA0, 0x20); outb(0x20, 0x20);                     // EOIs
    wait(4);
    CHECK(!t->intr, "intr after release");
    // an unrouted PIRQ does nothing
    cfg_wr(0x60, 8, 0x80000000);
    t->pirq_n = 0x7; wait(4); CHECK(!t->intr, "intr from an unrouted PIRQ"); t->pirq_n = 0xF;
    // an edge-triggered ISA line from outside (xio_irq 5)
    outb(0x21, 0xDB);
    t->xio_irq = 1 << 5; wait(4);
    CHECK(t->intr, "no intr for IRQ5");
    CHECK(iack() == 0x05, "vector for IRQ5");
    t->xio_irq = 0; outb(0x20, 0x20); wait(2);
    CHECK(!t->intr, "IRQ5 again");
    // poll mode
    t->xio_irq = 1 << 5; wait(4);
    outb(0x20, 0x0C); CHECK(inb(0x20) == 0x85, "poll %02x", inb(0x20));
    t->xio_irq = 0; outb(0x20, 0x20);
    // with IAE clear the SIO does not answer the acknowledge
    cfg_wr(0x40, 1, 0x00); pci(3, 0, 0, 15, false, 0, &cl); CHECK(!cl, "IACK with IAE clear");
    cfg_wr(0x40, 1, 0x20);
    outb(0x21, 0xFF);

    // ------------------------------------------------------------ 8254 and port 61
    printf("-- 8254 counter 2, port 61 (the DROM's beep), counter 0 (its calibration)\n");
    // DROM V1.7 0x44158 / 0x44204: port 61 = 03, 43 = B6, 42 = 80, 42 = 02
    outb(0x61, 0x03); outb(0x43, 0xB6); outb(0x42, 0x80); outb(0x42, 0x02);
    {
        // the half period is 320 ticks of 1.19 MHz: 26.8k cycles at 100 MHz; count edges for 3 ms
        int toggles = 0, last = inb(0x61) & 0x20, spk_t = 0, spk_last = t->spk;
        uint64_t c0 = cyc;
        while (cyc - c0 < 300000) {
            wait(50);
            int v = inb(0x61) & 0x20;
            if (v != last) toggles++;
            last = v;
            if (t->spk != spk_last) spk_t++;
            spk_last = t->spk;
        }
        CHECK(toggles >= 10 && toggles <= 12, "OUT2 toggles %d", toggles);
        CHECK(spk_t >= 10 && spk_t <= 12, "speaker toggles %d", spk_t);
        outb(0x43, 0x80); int lo = inb(0x42), hi = inb(0x42);
        int c = hi << 8 | lo;
        CHECK(c <= 0x280 && !(c & 1), "counter 2 latched %04x", c);
        CHECK((inb(0x61) & 0x0F) == 0x03, "port 61 %02x", inb(0x61));
        outb(0x61, 0x00);
    }
    // read-back command: status of counter 2 (mode 3, LSB/MSB)
    outb(0x43, 0xE8); CHECK((inb(0x42) & 0x3F) == 0x36, "read-back status");
    // DROM V1.7 0x400bc: 43 = 26 (counter 0, MSB only, mode 3), 40 = FF (count FF00h); it
    // times its MSB reaching 0, every half period: 7F80h ticks of 1.19 MHz, 2.74M cycles
    outb(0x43, 0x26); outb(0x40, 0xFF);
    {
        uint64_t z[4]; int nz = 0;
        for (int n = 0; n < 200000 && nz < 4; n++) {
            while (inb(0x40) == 0) ;
            while (inb(0x40) != 0) ;
            z[nz++] = cyc;
        }
        CHECK(nz == 4, "counter 0 never read 0");
        if (nz == 4) {
            double per = (z[3] - z[1]) / 2.0, want = 0x7F80 * 100e6 / 1193182.0;
            CHECK(per > want * 0.98 && per < want * 1.02, "counter 0 half period %.0f cycles, want %.0f", per, want);
        }
    }

    // ------------------------------------------------------------ TOY
    printf("-- BQ4285 TOY (DROM 3287 and interrupts tests)\n");
    // DROM V1.7 0x42a80: CMOS byte 50h: save, AAh, 55h, restore (index rewritten each time)
    {
        outb(0x70, 0x50); uint8_t save = inb(0x71);
        outb(0x70, 0x50); outb(0x71, 0xAA); outb(0x70, 0x50); uint8_t r1 = inb(0x71);
        outb(0x70, 0x50); outb(0x71, 0x55); outb(0x70, 0x50); uint8_t r2 = inb(0x71);
        outb(0x70, 0x50); outb(0x71, save);
        CHECK(r1 == 0xAA && r2 == 0x55, "CMOS 50h %02x %02x", r1, r2);
    }
    CHECK(rtc_rd(0x0D) == 0x80, "register D");
    CHECK(rtc_rd(0x0A) == 0x26, "register A %02x", rtc_rd(0x0A));
    // the MiSTer's time: 2026-11-01 13:45:30, a Sunday (BCD)
    {
        uint64_t v = 0x30ull | 0x45ull << 8 | 0x13ull << 16 | 0x01ull << 24 | 0x11ull << 32 | 0x26ull << 40 | 0x00ull << 48;
        t->rtc[0] = (uint32_t)v; t->rtc[1] = (uint32_t)(v >> 32); t->rtc[2] = 1;    // bit 64 toggles
        wait(10);
        CHECK(rtc_rd(0) == 0x30 && rtc_rd(2) == 0x45 && rtc_rd(4) == 0x13, "time %02x:%02x:%02x", rtc_rd(4), rtc_rd(2), rtc_rd(0));
        CHECK(rtc_rd(7) == 0x01 && rtc_rd(8) == 0x11 && rtc_rd(9) == 0x26 && rtc_rd(6) == 1, "date %02x-%02x-%02x dow %d",
              rtc_rd(9), rtc_rd(8), rtc_rd(7), rtc_rd(6));
        // binary, 12-hour: 1 PM
        rtc_wr(0x0B, 0x06); CHECK(rtc_rd(4) == 0x0D && rtc_rd(9) == 26, "binary %02x %d", rtc_rd(4), rtc_rd(9));
        rtc_wr(0x0B, 0x00); CHECK(rtc_rd(4) == 0x81, "12-hour %02x", rtc_rd(4));
        rtc_wr(0x0B, 0x02);
        // the OSD's year override takes on the next update
        t->year_ovr_en = 1; t->year_ovr = 99; t->rtc[2] = 0; wait(10);
        CHECK(rtc_rd(9) == 0x99, "year override %02x", rtc_rd(9));
        t->year_ovr_en = 0;
    }
    // DROM V1.7 0x43030-0x43158 (Interrupts test): B |= PIE, A = 26h (1024 Hz), poll C
    // bit 6; IRQ4 (toy_irq) must be set; A = 06h (divider off), C read until PF clear, PIE
    // cleared: IRQ4 must stay clear; A = 26h again
    {
        uint8_t b = rtc_rd(0x0B) & 0x7F;
        rtc_wr(0x0B, b | 0x40);
        rtc_wr(0x0A, 0x26);
        int n = 0; while (!(rtc_rd(0x0C) & 0x40) && n < 100000) n++;
        CHECK(n < 100000, "no periodic flag");
        wait(200000);                                   // 2 ms: two more periods
        CHECK(t->toy_irq, "toy_irq (CPU IRQ4) not set");
        rtc_wr(0x0A, 0x06);
        n = 0; while ((rtc_rd(0x0C) & 0x40) && n < 100000) n++;
        rtc_wr(0x0B, rtc_rd(0x0B) & 0x3F);
        wait(200000);
        CHECK(!t->toy_irq, "toy_irq not cleared");
        rtc_wr(0x0A, 0x26);
        // the periodic rate: 1024 Hz = 97.7k cycles a period
        rtc_wr(0x0B, 0x42); rtc_rd(0x0C);
        while (!t->toy_irq) tick();
        uint64_t c0 = cyc; rtc_rd(0x0C);
        while (!t->toy_irq) tick();
        double per = (double)(cyc - c0);
        CHECK(per > 97000 && per < 98500, "periodic interval %.0f cycles", per);
        CHECK(rtc_rd(0x0C) == 0xC0, "register C");
        CHECK(!t->toy_irq, "C read did not clear IRQF");
        rtc_wr(0x0B, 0x02);
        CHECK(!t->intr, "the TOY must not reach the 8259");
    }
    // the update-ended flag once a second (RTC_FAST=1 in the bench: every 15.6 ms)
    {
        rtc_wr(0x0B, 0x02); rtc_rd(0x0C);
        uint8_t s0 = rtc_rd(0);
        int n = 0; while (!(rtc_rd(0x0C) & 0x10) && n < 2000000) { wait(50); n++; }
        uint8_t s1 = rtc_rd(0);
        CHECK(n < 2000000 && s1 != s0, "the second did not tick (%02x %02x)", s0, s1);
    }

    // ------------------------------------------------------------ 8242
    printf("-- 8242 keyboard controller (DROM 8242 test)\n");
    // DROM V1.7 0x42c98: wait for IBF clear at 64, write AAh to 64, wait, IBF clear, read 60 = 55h
    CHECK(kbc_wait_ibf() == 0, "IBF stuck");
    outb(0x64, 0xAA);
    wait(1000);
    CHECK(kbc_wait_ibf() == 0, "IBF stuck after AA");
    CHECK(inb(0x60) == 0x55, "self test");
    CHECK(inb(0x64) & 0x04, "system flag after the self test");
    outb(0x64, 0xAB); CHECK(kbc_read() == 0x00, "interface test");
    outb(0x64, 0x20); int cb = kbc_read(); CHECK(cb == 0x04, "command byte %02x", cb);
    // the keyboard: reset (FA AA), scan set 3 as SRM selects it, a key
    outb(0x60, 0xFF); CHECK(kbc_read() == 0xFA && kbc_read() == 0xAA, "keyboard reset");
    outb(0x60, 0xF0); CHECK(kbc_read() == 0xFA, "F0 ack"); outb(0x60, 0x03); CHECK(kbc_read() == 0xFA, "set 3 ack");
    outb(0x60, 0xF0); kbc_read(); outb(0x60, 0x00); CHECK(kbc_read() == 0xFA && kbc_read() == 0x03, "scan set query");
    outb(0x64, 0x60); outb(0x60, 0x03);                 // interrupts on, no translation
    outb(0x21, 0xFD);                                   // IRQ1 unmasked
    t->ps2_key = 1 << 10 | 1 << 9 | 0x76; wait(10);     // Esc pressed (set 2 76h)
    {
        int n = 0; while (!t->intr && n++ < 100000) tick();
        CHECK(t->intr, "no IRQ1 for a key");
        CHECK(iack() == 0x01, "keyboard vector");
        CHECK(inb(0x60) == 0x08, "Esc in set 3");
        outb(0x20, 0x20);
    }
    t->ps2_key = 0 << 10 | 0x76; wait(10);              // released: F0 08
    CHECK(kbc_read() == 0xF0 && kbc_read() == 0x08, "Esc release in set 3");
    outb(0x21, 0xFF);
    // the mouse through D4
    outb(0x64, 0xD4); outb(0x60, 0xF2); CHECK(kbc_read() == 0xFA && kbc_read() == 0x00, "mouse identify");
    // the reset line
    outb(0x64, 0xFE); wait(2); CHECK(t->kbrst, "kbrst"); wait(1000); CHECK(!t->kbrst, "kbrst stuck");

    // ------------------------------------------------------------ PC87332
    printf("-- PC87332 (DROM 87332 test: COM1's scratch register)\n");
    // DROM V1.7 0x42e48: 3FF = 00, FF, AA, 55, each read back
    {
        const uint8_t pat[4] = {0x00, 0xFF, 0xAA, 0x55};
        for (int i = 0; i < 4; i++) { outb(0x3FF, pat[i]); CHECK(inb(0x3FF) == pat[i], "COM1 SCR %02x", pat[i]); }
    }
    outb(0x398, 8); CHECK((inb(0x399) & 0xF0) == 0x10, "SID %02x", inb(0x399));
    CHECK(inb(0x398) == 8, "index read back");
    outb(0x398, 0); CHECK(inb(0x399) == 0x0F, "FER %02x", inb(0x399));
    outb(0x398, 1); CHECK(inb(0x399) == 0x10, "FAR %02x", inb(0x399));
    outb(0x2FF, 0x5A); CHECK(inb(0x2FF) == 0x5A, "COM2 SCR");
    // the parallel port at 378
    outb(0x378, 0xD5); CHECK(inb(0x378) == 0xD5 && inb(0x379) == 0xDF, "LPT %02x %02x", inb(0x378), inb(0x379));
    // UART 2 moved to COM4 (2E8), the parallel port off
    outb(0x398, 1); outb(0x399, 0x30); outb(0x399, 0x30);
    outb(0x2EF, 0x77); CHECK(inb(0x2EF) == 0x77 && inb(0x2FF) == 0xFF, "COM2 at 2E8 %02x", inb(0x2EF));
    outb(0x398, 0); outb(0x399, 0x0E); outb(0x399, 0x0E);
    CHECK(inb(0x378) == 0xFF, "LPT disabled");
    outb(0x398, 0); outb(0x399, 0x0F); outb(0x398, 1); outb(0x399, 0x10);
    // COM1's interrupt through OUT2
    outb(0x21, 0xEF);
    outb(0x3F9, 0x02); wait(4);                         // THRE interrupt
    CHECK(!t->intr, "COM1 interrupt without OUT2");
    outb(0x3FC, 0x08); wait(4);
    CHECK(t->intr && iack() == 0x04, "COM1 interrupt (IRQ4)");
    outb(0x3F9, 0x00); outb(0x3FC, 0x00); outb(0x20, 0x20); outb(0x21, 0xFF);

    // ------------------------------------------------------------ FDC stub
    printf("-- FDC stub\n");
    outb(0x21, 0xBF);
    outb(0x3F2, 0x00); outb(0x3F2, 0x0C); wait(4);
    CHECK(t->intr && iack() == 0x06, "FDC reset interrupt");
    for (int d = 0; d < 4; d++) {
        CHECK((inb(0x3F4) & 0xC0) == 0x80, "MSR before SENSE INTERRUPT %02x", inb(0x3F4));
        outb(0x3F5, 0x08);
        CHECK((inb(0x3F4) & 0xC0) == 0xC0, "MSR result phase");
        uint8_t st0 = inb(0x3F5), pcn = inb(0x3F5);
        CHECK(st0 == (0xC0 | d) && pcn == 0, "post-reset sense %d: %02x %02x", d, st0, pcn);
    }
    outb(0x20, 0x20);
    outb(0x3F5, 0x10); CHECK(inb(0x3F5) == 0x90, "VERSION");
    outb(0x3F5, 0x03); outb(0x3F5, 0xDF); outb(0x3F5, 0x02); CHECK((inb(0x3F4) & 0xD0) == 0x80, "SPECIFY done");
    outb(0x3F5, 0x07); outb(0x3F5, 0x00); wait(4);      // RECALIBRATE drive 0
    CHECK(t->intr && iack() == 0x06, "recalibrate interrupt");
    outb(0x3F5, 0x08); { uint8_t s = inb(0x3F5), p = inb(0x3F5); CHECK(s == 0x20 && p == 0, "seek end %02x %02x", s, p); }
    outb(0x20, 0x20);
    // READ DATA with no medium: abnormal termination, missing address mark
    { const uint8_t c[9] = {0xE6, 0x00, 0, 0, 1, 2, 18, 0x1B, 0xFF}; for (int i = 0; i < 9; i++) outb(0x3F5, c[i]); }
    wait(4);
    CHECK(t->intr, "read interrupt");
    { uint8_t r[7]; for (int i = 0; i < 7; i++) r[i] = inb(0x3F5);
      CHECK(r[0] == 0x40 && r[1] == 0x01 && r[2] == 0x00, "read result %02x %02x %02x", r[0], r[1], r[2]); }
    CHECK((inb(0x3F4) & 0xC0) == 0x80, "MSR after the result");
    CHECK(inb(0x3F7) & 0x80, "DIR disk changed");
    iack(); outb(0x20, 0x20); outb(0x21, 0xFF);

    // ------------------------------------------------------------ NMI
    printf("-- NMI (port 61, port 70 bit 7)\n");
    outb(0x70, 0x80);
    t->serr = 1; wait(2); t->serr = 0; wait(2);
    CHECK(!t->nmi && (inb(0x61) & 0x80), "SERR status without NMI enable %02x", inb(0x61));
    outb(0x70, 0x00); wait(2);
    CHECK(t->nmi, "NMI from SERR");
    outb(0x61, 0x04); wait(2); outb(0x61, 0x00);
    CHECK(!t->nmi && !(inb(0x61) & 0x80), "SERR cleared");

    // ------------------------------------------------------------ DMA
    printf("-- ISA DMA (channel 2, write to memory, over the PCI master port)\n");
    outb(0x0A, 0x06);                                   // mask channel 2
    outb(0x0C, 0x00);                                   // byte pointer
    outb(0x04, 0x56); outb(0x04, 0x34);                 // address 3456
    outb(0x05, 0x02); outb(0x05, 0x00);                 // count 2: three bytes
    outb(0x81, 0x01);                                   // page 01: PCI 0x013456
    outb(0x0B, 0x46);                                   // single, increment, write (to memory), channel 2
    outb(0x0A, 0x02);                                   // unmask
    {
        int got = 0, tcs = 0;
        t->xio_dreq = 1 << 2;
        for (int n = 0; n < 2000 && got < 3; n++) {
            t->xio_dev_data = 0xA0 + got;
            tick();
            if (t->xio_dack) { got++; if (t->xio_tc) tcs++; }
        }
        t->xio_dreq = 0; wait(10);
        CHECK(got == 3 && tcs == 1, "dacks %d tc %d", got, tcs);
        CHECK(mem[0x13456] == 0xA0 && mem[0x13457] == 0xA1 && mem[0x13458] == 0xA2, "memory %02x %02x %02x",
              mem[0x13456], mem[0x13457], mem[0x13458]);
        CHECK(inb(0x08) & 0x04, "TC status");
        CHECK(inb(0x0F) & 0x04, "masked after TC");
    }

    printf("%s: %d checks, %d failures (%llu cycles)\n", fails ? "FAIL" : "PASS", checks, fails, (unsigned long long)cyc);
    t->final();
    delete t;
    return fails ? 1 : 0;
}
