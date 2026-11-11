// Unit bench for rtl/mister/sdram_ctl.v with verilator/tb/sdram_model.v:
// random line writes (random byte enables) and quadword reads over 128 MB,
// checked against a C++ copy.
#include "Vtb_sdram_top.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <unordered_map>

int main() {
    Vtb_sdram_top t;
    auto tick = [&]() { t.clk = 0; t.eval(); t.clk = 1; t.eval(); };
    t.init = 1; tick(); t.init = 0;
    long c = 0;
    while (!t.ready && c < 30000) { tick(); c++; }
    if (!t.ready) { printf("tb_sdram: no ready\n"); return 1; }
    std::mt19937_64 r(1);
    std::unordered_map<uint32_t, uint64_t> ref;
    long n = 0, bad = 0, cycles = 0;
    for (int i = 0; i < 20000; i++) {
        uint32_t q = (r() % 512) + ((r() % 4) << 21) + (r() & 1 ? (1u << 23) : 0);   // spread over rows, banks, ranks
        bool w = (r() % 3) != 0;
        // a write is a line with 32 byte enables: one quadword's (as a single store gives),
        // or any mix of the four
        uint64_t d[4] = { r(), r(), r(), r() };
        uint32_t be = 0xFF;
        if (w) { be = (r() & 1) ? (uint32_t)(uint8_t)(r() | 1) << 8 * (q & 3) : (uint32_t)r(); }
        t.req = 1; t.we = w; t.line = 0; t.addr = q; t.be = be;
        for (int j = 0; j < 4; j++) { t.wdata[2 * j] = (uint32_t)d[j]; t.wdata[2 * j + 1] = (uint32_t)(d[j] >> 32); }
        int k = 0;
        do { tick(); k++; } while (!t.ack && k < 200);
        t.req = 0; tick();
        cycles += k;
        if (!t.ack && k >= 200) { printf("tb_sdram: no ack at %d\n", i); return 1; }
        if (w) {
            for (int j = 0; j < 4; j++) {
                uint64_t &m = ref[(q & ~3u) + j];
                for (int b = 0; b < 8; b++) if (be >> (8 * j + b) & 1) m = (m & ~(0xFFull << 8*b)) | (d[j] & (0xFFull << 8*b));
            }
        } else {
            uint64_t m = ref.count(q) ? ref[q] : 0;
            n++;
            if (t.rdata != m && bad++ < 10) printf("q %06x: read %016llx, expected %016llx\n", q,
                (unsigned long long)t.rdata, (unsigned long long)m);
        }
    }
    // line reads: 4 quadwords from a line-aligned address, one ack each
    long lbad = 0;
    for (int i = 0; i < 2000; i++) {
        uint32_t q = ((r() % 512) & ~3u) + ((r() % 4) << 21) + (r() & 1 ? (1u << 23) : 0);
        t.req = 1; t.we = 0; t.line = 1; t.addr = q; t.be = 0xFF;
        int got = 0, k = 0;
        while (got < 4 && k++ < 400) {
            tick();
            if (t.ack) {
                uint64_t want = ref.count(q + got) ? ref[q + got] : 0;
                if (t.rdata != want && lbad++ < 5) printf("line q %06x beat %d: %016llx want %016llx\n", q, got,
                    (unsigned long long)t.rdata, (unsigned long long)want);
                got++;
            }
        }
        t.req = 0; t.line = 0; tick();
        if (got != 4) { printf("line: %d acks\n", got); lbad++; }
    }
    bad += lbad;
    printf("tb_sdram: line reads %ld mismatches\n", lbad);
    printf("tb_sdram: %ld reads checked, %ld mismatches, %.1f cycles a request\n", n, bad, (double)cycles / 20000);
    return bad ? 1 : 0;
}
