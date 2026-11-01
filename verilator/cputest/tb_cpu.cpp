// CPU test harness: rtl/cpu/ev4_seq.v with a flat memory, running a T0
// bare-metal image (tests/cpu, make pal) from PA 0.
//
//   Vev4_seq IMAGE.bin [--trace FILE] [--max N] [--mem MB] [--tohost PA]
//
// Stops when the CPU stores to TOHOST (default PA 0x800000): value 1 = pass
// (exit 0), anything else is reported and exits 1. --trace writes the retire
// trace in the alphaemu -T format for diffing against `alphaemu -P -T`.
#include "Vev4_seq.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cinttypes>
#include <vector>
#include <string>

int main(int argc, char **argv) {
    const char *img = nullptr, *trace = nullptr;
    uint64_t maxcyc = 200000000, tohost = 0x800000;
    size_t mb = 16;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--trace")) trace = argv[++i];
        else if (!strcmp(argv[i], "--max")) maxcyc = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--mem")) mb = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--tohost")) tohost = strtoull(argv[++i], 0, 0);
        else img = argv[i];
    }
    if (!img) { fprintf(stderr, "usage: %s IMAGE.bin [--trace FILE]\n", argv[0]); return 2; }
    std::vector<uint8_t> mem(mb << 20);
    FILE *f = fopen(img, "rb");
    if (!f) { perror(img); return 2; }
    size_t n = fread(mem.data(), 1, mem.size(), f);
    fclose(f);
    FILE *tf = trace ? fopen(trace, "w") : nullptr;

    Vev4_seq *c = new Vev4_seq;
    auto tick = [&]() { c->clk = 0; c->eval(); c->clk = 1; c->eval(); };
    c->rst = 1; tick(); tick(); c->rst = 0;
    uint64_t cyc = 0, retired = 0;
    int rc = 3;
    bool pend = false;
    while (cyc < maxcyc) {
        // memory: answer a request on the cycle after it appears
        c->mem_ack = 0;
        if (c->mem_req && !pend) pend = true;
        else if (c->mem_req && pend) {
            uint64_t a = (uint64_t)c->mem_addr << 3;
            if (a + 8 > mem.size()) {
                fprintf(stderr, "bus access beyond memory: %#" PRIx64 " at cycle %" PRIu64 "\n", a, cyc);
                rc = 1; break;
            }
            uint64_t q; memcpy(&q, &mem[a], 8);
            if (c->mem_we) {
                uint64_t w = c->mem_wdata, m = 0;
                for (int b = 0; b < 8; b++) if (c->mem_be >> b & 1) m |= 0xFFull << (8 * b);
                q = (q & ~m) | (w & m);
                memcpy(&mem[a], &q, 8);
                if (a == tohost) {
                    uint64_t r1, r2; memcpy(&r1, &mem[a + 8], 8); memcpy(&r2, &mem[a + 16], 8);
                    printf("TOHOST %#" PRIx64 " (+8 %#" PRIx64 ", +16 %#" PRIx64 ") after %" PRIu64 " instructions, %" PRIu64 " cycles\n",
                           q, r1, r2, retired, cyc);
                    rc = q == 1 ? 0 : 1;
                }
            }
            c->mem_rdata = q;
            c->mem_ack = 1;
            pend = false;
            if (rc != 3) break;     // alphaemu's trace also ends before the TOHOST store
        }
        tick();
        cyc++;
        if (c->dbg_retire) {
            retired++;
            if (tf) {
                fprintf(tf, "%016" PRIx64 " %08x", (uint64_t)c->dbg_pc, c->dbg_insn);
                if (c->dbg_rwr) fprintf(tf, " r%d=%016" PRIx64, c->dbg_rnum, (uint64_t)c->dbg_rval);
                if (c->dbg_mwr) fprintf(tf, " m%016" PRIx64 "=%016" PRIx64 "/%d", (uint64_t)c->dbg_maddr, (uint64_t)c->dbg_mval, c->dbg_msize);
                fputc('\n', tf);
            }
        }
        if (rc != 3) break;
    }
    if (rc == 3) { printf("no TOHOST after %" PRIu64 " cycles (pc %#" PRIx64 ")\n", cyc, (uint64_t)c->dbg_pc); rc = 1; }
    if (tf) fclose(tf);
    delete c;
    (void)n;
    return rc;
}
