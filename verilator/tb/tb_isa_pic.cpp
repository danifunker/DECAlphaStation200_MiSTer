// Unit bench of rtl/sio/isa_pic.v (the 82378's 8259A pair) on its own ports: the cascade's
// corner cases that the OSes hit (docs/gaps.md, 8259 row; Tru64's "stray interrupt vector 0x8f0"
// when X starts, after which every slave interrupt was dead):
//   - a slave request acknowledged through the cascade (vector, ISR bits, EOI);
//   - a slave request that goes away before the acknowledge (a level line whose driver clears the
//     condition): a real master drops its latched IR2 and answers the INTA with its default IRQ7,
//     setting no ISR bit; the slave's IRQ15 vector with master ISR2 set is the bug;
//   - a slave IMR write while a slave request is being delivered: INT must not dip, and an
//     acknowledge right after the write must never return IRQ15 with master ISR2 set;
//   - the master's own default IRQ7 for a request that vanished.
//
//   make -C verilator tb_isa_pic
#include "Visa_pic.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Visa_pic *t;
static int fails, checks;

#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
static void wait(int n) { while (n--) tick(); }
static void outb(int port, uint8_t v) { t->io_addr = port; t->io_din = v; t->io_wr = 1; tick(); t->io_wr = 0; t->io_addr = 0; }
static uint8_t inb(int port) { t->io_addr = port; t->io_rd = 1; t->eval(); uint8_t v = t->io_dout; tick(); t->io_rd = 0; t->io_addr = 0; return v; }
static uint8_t iack() { t->iack = 1; t->eval(); uint8_t v = t->iack_vec; tick(); t->iack = 0; return v; }
static uint8_t isr(int base) { outb(base, 0x0B); uint8_t v = inb(base); outb(base, 0x0A); return v; }   // OCW3 read ISR, then back to IRR
static void irq(int n, int on) { if (on) t->irq |= 1u << n; else t->irq &= ~(1u << n); }

static void init() {
    t->rst = 1; wait(3); t->rst = 0; wait(2);
    outb(0x20, 0x11); outb(0x21, 0x00); outb(0x21, 0x04); outb(0x21, 0x01);   // master: vectors 00-07, slave on IR2
    outb(0xA0, 0x11); outb(0xA1, 0x08); outb(0xA1, 0x02); outb(0xA1, 0x01);   // slave: vectors 08-0F
    outb(0x4D0, 0x00); outb(0x4D1, 0x0A);                                      // IRQ9 and IRQ11 level (PCI PIRQs)
    outb(0x21, 0x00); outb(0xA1, 0x00);                                        // all unmasked
    wait(8);
    CHECK(!t->intr, "idle after init");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Visa_pic;
    t->irq = 0; t->io_rd = 0; t->io_wr = 0; t->iack = 0;

    printf("-- A: a slave request through the cascade\n");
    init();
    irq(11, 1); wait(10);
    CHECK(t->intr, "INT for IRQ11");
    uint8_t v = iack();
    CHECK(v == 0x0B, "vector for IRQ11: %02X", v);
    CHECK(isr(0xA0) == 0x08, "slave ISR3 in service");
    CHECK(isr(0x20) == 0x04, "master ISR2 in service");
    irq(11, 0); outb(0xA0, 0x20); outb(0x20, 0x20); wait(8);
    CHECK(!t->intr, "idle after the EOIs");
    CHECK(isr(0xA0) == 0 && isr(0x20) == 0, "ISRs clear after the EOIs");

    printf("-- B: a slave request that goes away before the acknowledge\n");
    init();
    irq(9, 1); wait(10);
    CHECK(t->intr, "INT for IRQ9");
    irq(9, 0); wait(8);                                   // the driver cleared the condition before the INTA
    v = iack();
    CHECK(v == 0x07, "a vanished slave request: the master's default IRQ7, got %02X", v);
    CHECK(isr(0x20) == 0, "no master ISR bit for a default IRQ7 (got %02X)", isr(0x20));
    CHECK(isr(0xA0) == 0, "no slave ISR bit either (got %02X)", isr(0xA0));
    irq(11, 1); wait(10);
    CHECK(t->intr, "INT for IRQ11 after the stray");
    v = iack();
    CHECK(v == 0x0B, "IRQ11 still delivered after the stray: %02X", v);
    irq(11, 0); outb(0xA0, 0x20); outb(0x20, 0x20); wait(8);

    printf("-- C: a slave IMR write while a slave request is being delivered\n");
    init();
    irq(11, 1); wait(10);
    CHECK(t->intr, "INT for IRQ11");
    outb(0xA1, 0x00);                                     // a mask write that changes nothing
    for (int i = 0; i < 6; i++) { CHECK(t->intr, "INT dips %d clocks after a slave IMR write", i); tick(); }
    irq(11, 0); init();
    irq(11, 1); wait(10);
    outb(0xA1, 0x00); tick();                             // the acknowledge one clock after the write
    v = iack();
    CHECK(v != 0x0F, "IRQ15 returned for a pending IRQ11 right after a slave IMR write");
    if (v == 0x07) CHECK(isr(0x20) == 0, "default IRQ7 with a master ISR bit set (%02X)", isr(0x20));
    else { CHECK(v == 0x0B, "vector right after a slave IMR write: %02X", v); CHECK(isr(0xA0) == 0x08 && isr(0x20) == 0x04, "ISRs for IRQ11"); }
    irq(11, 0); outb(0xA0, 0x20); outb(0x20, 0x20); wait(8);
    irq(11, 1); wait(10);
    CHECK(t->intr && iack() == 0x0B, "IRQ11 still delivered afterwards");
    irq(11, 0); outb(0xA0, 0x20); outb(0x20, 0x20); wait(8);

    printf("-- D: the master's own default IRQ7\n");
    init();
    irq(4, 1); wait(10);
    CHECK(t->intr, "INT for IRQ4 (edge)");
    irq(4, 0); wait(8);
    v = iack();
    CHECK(v == 0x07, "a vanished master request: default IRQ7, got %02X", v);
    CHECK(isr(0x20) == 0, "no ISR bit for the default IRQ7 (got %02X)", isr(0x20));
    wait(8);
    CHECK(!t->intr, "idle afterwards");

    printf("%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", checks, fails);
    delete t;
    return fails ? 1 : 0;
}
