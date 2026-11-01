// Unit bench for rtl/cpu/ev4_fpu.v: replays tests/fpu/gen_fpu.py vectors
// (IR FA FB DYN RESULT FPCR EXC TRAP, hex) and compares result, FPCR bits,
// EXC_SUM bits, trap and the returned tag. Non-divide operations are issued
// back to back (with random gaps) whenever busy is low; results must come
// out in order. Reports per operation, with the latency seen.
//
//   Vev4_fpu FILE|-  [--gap PCT] [--kill PERMILLE] [--seed N] [--show N]
#include "Vev4_fpu.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cinttypes>
#include <deque>
#include <map>
#include <string>

struct Vec { uint32_t ir; uint64_t a, b; unsigned dyn; uint64_t res; unsigned fpcr, exc, trap; };
struct Pend { Vec v; unsigned tag; uint64_t t0; };
struct Stat { long n = 0, bad = 0; long lmin = 1 << 30, lmax = 0; };

static std::string opname(uint32_t ir) {
    unsigned opc = ir >> 26, fn = (ir >> 5) & 0x7FF, f = fn & 0x3F;
    static const char *ar[4] = {"ADD", "SUB", "MUL", "DIV"};
    char b[32];
    if (opc == 0x16) {
        if (f < 4) { snprintf(b, sizeof b, "%sS", ar[f]); return b; }
        if (f >= 0x20 && f < 0x24) { snprintf(b, sizeof b, "%sT", ar[f - 0x20]); return b; }
        switch (f) {
        case 0x24: return "CMPTUN"; case 0x25: return "CMPTEQ"; case 0x26: return "CMPTLT";
        case 0x27: return "CMPTLE"; case 0x2F: return "CVTTQ"; case 0x3C: return "CVTQS";
        case 0x3E: return "CVTQT";
        case 0x2C: return ((fn >> 9) & 1) && !((fn >> 8) & 1) ? "CVTST" : "CVTTS";
        }
    } else {
        if (f < 4) { snprintf(b, sizeof b, "%sF", ar[f]); return b; }
        if (f >= 0x20 && f < 0x24) { snprintf(b, sizeof b, "%sG", ar[f - 0x20]); return b; }
        switch (f) {
        case 0x25: return "CMPGEQ"; case 0x26: return "CMPGLT"; case 0x27: return "CMPGLE";
        case 0x2C: return "CVTGF"; case 0x2D: return "CVTGD"; case 0x1E: return "CVTDG";
        case 0x2F: return "CVTGQ"; case 0x3C: return "CVTQF"; case 0x3E: return "CVTQG";
        }
    }
    snprintf(b, sizeof b, "%02x.%03x", opc, fn);
    return b;
}

static uint64_t rng = 88172645463325252ull;
static unsigned rnd(unsigned n) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (unsigned)(rng % n); }

int main(int argc, char **argv) {
    const char *fn = nullptr;
    unsigned gap = 20, killpm = 0, show = 30;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--gap") && i + 1 < argc) gap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--kill") && i + 1 < argc) killpm = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) rng ^= strtoull(argv[++i], 0, 0) * 0x9E3779B97F4A7C15ull;
        else if (!strcmp(argv[i], "--show") && i + 1 < argc) show = atoi(argv[++i]);
        else fn = argv[i];
    }
    if (!fn) { fprintf(stderr, "usage: %s VECTORS|- [--gap PCT] [--kill PERMILLE] [--seed N]\n", argv[0]); return 1; }
    FILE *f = strcmp(fn, "-") ? fopen(fn, "r") : stdin;
    if (!f) { perror(fn); return 1; }

    Vev4_fpu u;
    uint64_t cyc = 0;
    auto tick = [&]() { u.clk = 0; u.eval(); u.clk = 1; u.eval(); cyc++; };
    u.rst = 1; u.start = 0; u.kill = 0; tick(); tick(); u.rst = 0;

    std::deque<Pend> q;
    std::map<std::string, Stat> st;
    long n = 0, bad = 0, killed = 0, stray = 0;
    unsigned tagc = 0;
    Vec nv; bool have = false, eof = false;
    auto next = [&]() {
        unsigned ir;
        if (fscanf(f, "%x %" SCNx64 " %" SCNx64 " %x %" SCNx64 " %x %x %x", &ir, &nv.a, &nv.b, &nv.dyn,
                   &nv.res, &nv.fpcr, &nv.exc, &nv.trap) == 8) { nv.ir = ir; have = true; }
        else { have = false; eof = true; }
    };
    next();
    uint64_t idle = 0;
    while (!eof || have || !q.empty()) {
        // outputs of the last edge
        if (u.done) {
            if (q.empty()) { if (stray++ < 5) fprintf(stderr, "done with nothing in flight (cycle %" PRIu64 ")\n", cyc); }
            else {
                Pend p = q.front(); q.pop_front();
                Stat &s = st[opname(p.v.ir)];
                long lat = (long)(cyc - p.t0);
                s.n++; n++;
                if (lat < s.lmin) s.lmin = lat;
                if (lat > s.lmax) s.lmax = lat;
                bool ok = u.result == p.v.res && u.fpcr_set == p.v.fpcr && u.exc_sum == p.v.exc &&
                          u.trap == p.v.trap && u.done_tag == p.tag;
                if (!ok) {
                    s.bad++;
                    if (bad++ < (long)show)
                        fprintf(stderr, "%-6s %08x fa %016" PRIx64 " fb %016" PRIx64 " dyn %u: got %016" PRIx64
                                " fpcr %02x exc %02x trap %u tag %u, want %016" PRIx64 " fpcr %02x exc %02x trap %u tag %u\n",
                                opname(p.v.ir).c_str(), p.v.ir, p.v.a, p.v.b, p.v.dyn, (uint64_t)u.result, u.fpcr_set,
                                u.exc_sum, u.trap, u.done_tag, p.v.res, p.v.fpcr, p.v.exc, p.v.trap, p.tag);
                }
            }
        }
        // this cycle's inputs
        u.start = 0; u.kill = 0;
        if (killpm && rnd(1000) < killpm) {
            u.kill = 1; killed += q.size(); q.clear();
        } else if (have && !u.busy && rnd(100) >= gap) {
            u.start = 1; u.ir = nv.ir; u.fa = nv.a; u.fb = nv.b; u.fpcr_dyn = nv.dyn;
            u.tag = tagc & 63;
            q.push_back({nv, tagc & 63, cyc}); tagc++;
            next();
        }
        tick();
        if (q.empty() && !have) { if (++idle > 100) break; } else idle = 0;
    }
    printf("%-8s %9s %7s %8s\n", "op", "vectors", "bad", "latency");
    for (auto &kv : st)
        printf("%-8s %9ld %7ld %4ld-%-3ld\n", kv.first.c_str(), kv.second.n, kv.second.bad, kv.second.lmin, kv.second.lmax);
    printf("tb_fpu: %ld vectors, %ld mismatches, %ld killed, %ld stray, %" PRIu64 " cycles\n", n, bad, killed, stray, cyc);
    return (bad || stray) ? 1 : 0;
}
