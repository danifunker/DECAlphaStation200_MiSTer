// Unit bench for the 21071 model's DMA translation (rtl/apecs/apecs.v):
// window 1 direct mapped with a non-zero translated base, window 2 scatter/
// gather through a map in DRAM, the S/G TLB and TBIA, an invalid entry.
#include "Vapecs.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static Vapecs *t;
static std::vector<uint8_t> dram(128u << 20, 0);
static int fails = 0;
static bool dpend = false;
static long dreads = 0;

static void tick() {
    t->d_ack = 0;
    if (t->d_req && !dpend) dpend = true;
    else if (t->d_req && dpend) {
        uint64_t a = (uint64_t)t->d_addr << 3, q;
        memcpy(&q, &dram[a], 8);
        if (t->d_we) {
            uint64_t m = 0;
            for (int b = 0; b < 8; b++) if (t->d_be >> b & 1) m |= 0xFFull << (8 * b);
            q = (q & ~m) | (t->d_wdata & m);
            memcpy(&dram[a], &q, 8);
        } else dreads++;
        t->d_rdata = q; t->d_ack = 1; dpend = false;
    }
    t->clk = 0; t->eval(); t->clk = 1; t->eval();
}

// a CPU longword write to a 21071-DA CSR (index = PA<11:5>)
static void da_write(int idx, uint32_t v) {
    uint64_t pa = 0x1A0000000ull + (idx << 5);
    t->c_req = 1; t->c_we = 1; t->c_addr = pa >> 3; t->c_be = 0x0F; t->c_wdata = v;
    for (int i = 0; i < 50 && !t->c_ack; i++) tick();
    t->c_req = 0; tick(); tick();
}

static uint32_t dma(bool we, uint32_t addr, uint32_t wdata) {
    t->dm_req = 1; t->dm_we = we; t->dm_addr = addr; t->dm_be = 0xF; t->dm_wdata = wdata;
    int i = 0;
    while (!t->dm_ack && i++ < 200) tick();
    uint32_t r = t->dm_rdata;
    t->dm_req = 0; tick();
    return r;
}

static void check(const char *what, uint64_t got, uint64_t want) {
    if (got != want) { printf("FAIL %s: got %llx, want %llx\n", what, (unsigned long long)got, (unsigned long long)want); fails++; }
}

int main() {
    t = new Vapecs;
    t->cfg_mem = 2;  // 128 MB in bank slot 0
    t->rst = 1; for (int i = 0; i < 5; i++) tick(); t->rst = 0; tick();
    // bank 0: 128 MB at 0 (CA config index 0x50 = 0x07: valid, 128 MB)
    {
        uint64_t pa = 0x180000000ull + (0x50 << 5);
        t->c_req = 1; t->c_we = 1; t->c_addr = pa >> 3; t->c_be = 0x0F; t->c_wdata = 0x07;
        for (int i = 0; i < 50 && !t->c_ack; i++) tick();
        t->c_req = 0; tick(); tick();
    }
    // window 1: direct, PCI 0x0080_0000 + 8 MB -> PA 0x0180_0000 (TBR<31:9> = PA<32:10>; 8 MB aligned)
    da_write(0x0A, 0x00700000);                 // PMR1: 8 MB
    da_write(0x06, 0x01800000 >> 1);            // TBR1: PA 0x1800000 (bits <32:10> at <31:9>)
    da_write(0x08, 0x00800000 | (1u << 19));    // PBR1: base 0x0080_0000, WENB
    dma(true, 0x00800010, 0xCAFEF00D);
    uint32_t v; memcpy(&v, &dram[0x1800010], 4);
    check("direct write lands at PA 0x1800010", v, 0xCAFEF00D);
    check("direct read", dma(false, 0x00800010, 0), 0xCAFEF00D);

    // window 2: scatter/gather, PCI 0x0100_0000 + 1 MB (128 pages), map at PA 0x0020_0000
    da_write(0x0B, 0x00000000);                 // PMR2: 1 MB
    da_write(0x07, 0x00200000 >> 1);            // TBR2: map base PA 0x200000
    da_write(0x09, 0x01000000 | (1u << 19) | (1u << 18));   // PBR2: base 0x0100_0000, WENB, SGEN
    // map: page 0 -> PA 0x0300_0000, page 5 -> PA 0x0123_4000 (8 KB aligned), page 6 invalid
    auto pte = [](uint64_t pa) { return ((pa >> 13) << 1) | 1; };
    uint64_t e0 = pte(0x03000000), e5 = pte(0x01234000), e6 = 0;
    memcpy(&dram[0x200000 + 0 * 8], &e0, 8);
    memcpy(&dram[0x200000 + 5 * 8], &e5, 8);
    memcpy(&dram[0x200000 + 6 * 8], &e6, 8);
    long r0 = dreads;
    dma(true, 0x01000020, 0x11111111);
    memcpy(&v, &dram[0x03000020], 4); check("S/G page 0 write", v, 0x11111111);
    check("S/G miss read one map entry", dreads - r0, 1);
    r0 = dreads;
    dma(true, 0x01000024, 0x22222222);
    check("S/G TLB hit: no map read", dreads - r0, 0);
    memcpy(&v, &dram[0x03000024], 4); check("S/G page 0 second write", v, 0x22222222);
    dma(true, 0x0100A1F0, 0x55555555);          // page 5, offset 0x1F0
    memcpy(&v, &dram[0x012341F0], 4); check("S/G page 5 write", v, 0x55555555);
    check("S/G page 5 read", dma(false, 0x0100A1F0, 0), 0x55555555);
    check("S/G invalid entry reads all ones", dma(false, 0x0100C000, 0), 0xFFFFFFFF);
    // TBIA clears the TLB: change page 0's entry, the next access must use it
    uint64_t e0b = pte(0x03100000);
    memcpy(&dram[0x200000], &e0b, 8);
    dma(true, 0x01000028, 0x33333333);
    memcpy(&v, &dram[0x03000028], 4); check("before TBIA the old entry is used", v, 0x33333333);
    da_write(0x20, 0);                           // TBIA
    dma(true, 0x0100002C, 0x44444444);
    memcpy(&v, &dram[0x0310002C], 4); check("after TBIA the new entry is used", v, 0x44444444);
    // outside both windows: master abort
    check("no window", dma(false, 0x40000000, 0), 0xFFFFFFFF);
    printf("tb_apecs: %d failures\n", fails);
    delete t;
    return fails ? 1 : 0;
}
