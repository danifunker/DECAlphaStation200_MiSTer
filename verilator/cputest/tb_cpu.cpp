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
//
// BOARD=1: the memory answers with the MiSTer's latencies (rtl/apecs/apecs.v + rtl/mister/
// sdram_ctl.v at 100 MHz, counted from the cycle mem_req rises): a quadword write is
// acknowledged after 12 cycles, a read's first quadword after 13 and a line's next three 4
// cycles apart (refresh is left out). The plain model answers after 2.
// CPU_PERF (make perf, a --public-flat-rw build): a cycle breakdown at the end, each cycle
// without a retirement blamed on the oldest thing holding the pipeline.
// CPU_TOP selects the core: Vev4_seq (sequential reference) or Vev4_core (pipelined)
#ifndef CPU_TOP
#define CPU_TOP Vev4_seq
#endif
#define STR2(x) #x
#define STR(x) STR2(x)
#include STR(CPU_TOP.h)
#include "verilated.h"
#ifdef CPU_PERF
#include "Vev4_core___024root.h"
#define SIG(n) (c->rootp->ev4_core__DOT__##n)
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cinttypes>
#include <vector>
#include <string>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);      // $test$plusargs in the RTL (+fpudbg ...)
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
        else if (argv[i][0] == '+') continue;        // a Verilator plusarg ($test$plusargs)
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
    c->sl_rcv = 1;
    c->dinv = 0; c->dinv_idx = 0;
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
    const bool memlog = getenv("MEMLOG") != nullptr, fastline = getenv("FASTLINE") != nullptr;
    // MEMDELAY=N: each memory request waits 0..N extra cycles (random, MEMSEED); the board's
    // SDRAM is slower and varies with refresh
    const int memdelay = getenv("MEMDELAY") ? atoi(getenv("MEMDELAY")) : 0;
    uint32_t rs = getenv("MEMSEED") ? (uint32_t)atoi(getenv("MEMSEED")) : 1u;
    auto rng = [&rs]() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; };
    int mdelay = 0;
    const bool board = getenv("BOARD") != nullptr;
#ifdef CPU_PERF
    enum { P_RETIRE, P_SWEEP, P_DFILL, P_DFILL_WB, P_WBFULL, P_DSETTLE, P_MUL, P_FPU, P_HAZ, P_SER, P_IFILL, P_BUBBLE, P_N };
    static const char *pname[P_N] = { "retiring", "cache sweeps", "D-cache fill", "D-fill waits for write buffer",
        "store waits for write buffer", "settle after D-fill", "multiplier", "FPU", "operand hazard (load-use etc.)",
        "serialized instruction", "I-cache fill", "bubbles (redirects, other)" };
    uint64_t pc_[P_N] = {0}, n_xredir = 0, n_wredir = 0, n_wr = 0, n_dfill = 0, n_ifill = 0, n_unc = 0;
#endif
    // IRQRATE=N (pipelined core): irq_h[0] rises at random, about once every N cycles while
    // low (IRQSEED); a write to PA 0x700000 (rt/t0_pal.h T0_IRQ's handler) drops it
    const int irqrate = getenv("IRQRATE") ? atoi(getenv("IRQRATE")) : 0;
    uint32_t is = getenv("IRQSEED") ? (uint32_t)atoi(getenv("IRQSEED")) : 7u;
    auto irng = [&is]() { is ^= is << 13; is ^= is >> 17; is ^= is << 5; return is; };
    bool irq = false;
    uint64_t nirq = 0;
    while (cyc < maxcyc) {
#ifdef CPU_PIPE
        if (irqrate && !irq && irng() % (uint32_t)irqrate == 0) { irq = true; nirq++; }
        c->irq_h = irq ? 1 : 0;
#endif
        // memory: answer a request on the cycle after it appears
        c->mem_ack = 0;
        if (board && !c->mem_req) pend = false;
        if (c->mem_req && !pend) { pend = true; mdelay = board ? (c->mem_we ? 10 : 11) : memdelay ? (int)(rng() % (memdelay + 1)) : 0; }
        else if (c->mem_req && pend && mdelay > 0) mdelay--;
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
            if (memlog) fprintf(stderr, "mem %s%s %#" PRIx64 " at %" PRIu64 "\n", c->mem_we ? "W" : "R", c->mem_line ? " line" : "", a, cyc);
            if (c->mem_we) {
                uint64_t w = c->mem_wdata, m = 0;
                for (int b = 0; b < 8; b++) if (c->mem_be >> b & 1) m |= 0xFFull << (8 * b);
                q = (q & ~m) | (w & m);
                memcpy(&mem[a], &q, 8);
                if (a == 0x700000) irq = false;
                if (a == tohost) {
                    uint64_t r1, r2; memcpy(&r1, &mem[a + 8], 8); memcpy(&r2, &mem[a + 16], 8);
                    printf("TOHOST %#" PRIx64 " (+8 %#" PRIx64 ", +16 %#" PRIx64 ") after %" PRIu64 " instructions, %" PRIu64 " cycles\n",
                           q, r1, r2, retired, cyc);
                    rc = q == 1 ? 0 : 1;
                }
            }
            c->mem_rdata = q;
            c->mem_ack = 1;
            pend = c->mem_line && !c->mem_we && fastline;   // line beats back to back (FASTLINE), as the SDRAM gives them
            if (board && c->mem_line && !c->mem_we) { pend = true; mdelay = 3; }
#ifdef CPU_PERF
            if (c->mem_we) n_wr++;
            else if (!c->mem_line) n_unc++;
            else if (SIG(bbeat) == 0) { if (SIG(bown) == 1) n_dfill++; else n_ifill++; }
#endif
            if (rc != 3) break;     // alphaemu's trace also ends before the TOHOST store
        }
#ifdef CPU_PERF
        {
            int k = SIG(isweep) || SIG(dsweep) || SIG(ld_active) ? P_SWEEP :
                    SIG(m2_need_bus) ? (SIG(wb_v) && SIG(bown) != 1 ? P_DFILL_WB : P_DFILL) :
                    SIG(m2_need_wb) ? P_WBFULL : SIG(dsettle) ? P_DSETTLE :
                    SIG(x_mul_wait) ? P_MUL : SIG(x_fpu_wait) ? P_FPU :
                    SIG(d_v) && SIG(haz) ? P_HAZ : SIG(d_v) && SIG(ser_wait) ? P_SER :
                    SIG(fstate) != 0 ? P_IFILL : P_BUBBLE;
            if (SIG(x_redir)) n_xredir++;
            if (SIG(w_redir)) n_wredir++;
            tick(); cyc++;
            pc_[c->dbg_retire ? P_RETIRE : k]++;
            goto retired;
        }
#endif
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
#ifdef CPU_PERF
    printf("%" PRIu64 " cycles, %" PRIu64 " retired: %.3f cycles per instruction\n", cyc, retired, (double)cyc / (retired ? retired : 1));
    for (int i = 0; i < P_N; i++) if (pc_[i]) printf("  %-34s %10" PRIu64 "  %5.1f%%\n", pname[i], pc_[i], 100.0 * pc_[i] / cyc);
    printf("  X redirects %" PRIu64 ", W redirects %" PRIu64 ", writes %" PRIu64 ", D-fills %" PRIu64 ", I-fills %" PRIu64 ", uncached reads %" PRIu64 "\n",
           n_xredir, n_wredir, n_wr, n_dfill, n_ifill, n_unc);
#endif
    if (irqrate) printf("%" PRIu64 " interrupts raised\n", nirq);
    if (rc == 3) { printf("no TOHOST after %" PRIu64 " cycles (pc %#" PRIx64 ")\n", cyc, (uint64_t)c->dbg_pc); rc = 1; }
    if (tf) fclose(tf);
    delete c;
    (void)n;
    return rc;
}
