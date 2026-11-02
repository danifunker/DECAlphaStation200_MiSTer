// Unit bench for rtl/mister/sdram_ctl.v with verilator/tb/sdram_model.v:
// random quadword writes (random byte enables) and reads over 128 MB,
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
        uint64_t d = r(); uint8_t be = w ? (uint8_t)(r() | 1) : 0xFF;
        t.req = 1; t.we = w; t.line = 0; t.addr = q; t.be = be; t.wdata = d;
        int k = 0;
        do { tick(); k++; } while (!t.ack && k < 200);
        t.req = 0; tick();
        cycles += k;
        if (!t.ack && k >= 200) { printf("tb_sdram: no ack at %d\n", i); return 1; }
        uint64_t &m = ref[q];
        if (w) {
            for (int b = 0; b < 8; b++) if (be >> b & 1) m = (m & ~(0xFFull << 8*b)) | (d & (0xFFull << 8*b));
        } else {
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
