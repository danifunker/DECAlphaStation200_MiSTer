// CPU test harness: rtl/cpu/ev4_seq.v or ev4_core.v (CPU_TOP) with a flat memory, running a T0
// bare-metal image (tests/cpu, make pal) from PA 0.
//
//   Vev4_seq|Vev4_core IMAGE.bin [--trace FILE] [--max N] [--mem MB] [--tohost PA]
//                       [--srom BITSTREAM] [--iosink]
//
// --srom (pipelined core only): icmode = 0, the I-cache is loaded from the
// SROM bitstream through the core's srom port before it starts at PC 0.
// --iosink: accesses outside the memory read all ones and drop writes
// instead of stopping the run (for code that touches chipset CSRs).
//
// Stops when the CPU stores to TOHOST (default PA 0x800000): value 1 = pass
// (exit 0), anything else is reported and exits 1. --trace writes the retire
// trace in the alphaemu -T format for diffing against `alphaemu -P -T`.
// CPU_TOP selects the core: Vev4_seq (sequential reference) or Vev4_core (pipelined)
#ifndef CPU_TOP
#define CPU_TOP Vev4_seq
#endif
#define STR2(x) #x
#define STR(x) STR2(x)
#include STR(CPU_TOP.h)
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cinttypes>
#include <vector>
#include <string>

int main(int argc, char **argv) {
    const char *img = nullptr, *trace = nullptr, *sromf = nullptr;
    bool iosink = false;
    uint64_t maxcyc = 200000000, tohost = 0x800000;
    size_t mb = 16;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--trace")) trace = argv[++i];
        else if (!strcmp(argv[i], "--max")) maxcyc = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--mem")) mb = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--tohost")) tohost = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--srom")) sromf = argv[++i];
        else if (!strcmp(argv[i], "--iosink")) iosink = true;
        else img = argv[i];
    }
    if (!img && !sromf) { fprintf(stderr, "usage: %s IMAGE.bin [--trace FILE]\n", argv[0]); return 2; }
    std::vector<uint8_t> mem(mb << 20), srom(8192, 0);
    size_t n = 0;
    if (img) {
        FILE *f = fopen(img, "rb");
        if (!f) { perror(img); return 2; }
        n = fread(mem.data(), 1, mem.size(), f);
        fclose(f);
    }
    if (sromf) {
        FILE *f = fopen(sromf, "rb");
        if (!f) { perror(sromf); return 2; }
        if (fread(srom.data(), 1, srom.size(), f) == 0) { fprintf(stderr, "empty SROM\n"); return 2; }
        fclose(f);
    }
    FILE *tf = trace ? fopen(trace, "w") : nullptr;

    CPU_TOP *c = new CPU_TOP;
#ifdef CPU_PIPE
    c->icmode = sromf ? 0 : 1;
    uint8_t sromq = 0;
    auto tick = [&]() { c->srom_data = sromq; c->clk = 0; c->eval(); c->clk = 1; c->eval();
                        sromq = srom[c->srom_addr & 8191]; };
#else
    auto tick = [&]() { c->clk = 0; c->eval(); c->clk = 1; c->eval(); };
#endif
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
                if (!iosink) {
                    fprintf(stderr, "bus access beyond memory: %#" PRIx64 " at cycle %" PRIu64 "\n", a, cyc);
                    rc = 1; break;
                }
                c->mem_rdata = ~0ull; c->mem_ack = 1; pend = false;
                tick(); cyc++;
                goto retired;
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
    retired:
        if (c->dbg_retire) {
            retired++;
            // the TOHOST store retires before the write buffer reaches memory:
            // alphaemu's trace ends before it, so this one stops here too
            if (tf && c->dbg_mwr && ((uint64_t)c->dbg_maddr & 0x3ffffffffull) == tohost) { fclose(tf); tf = nullptr; }
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
