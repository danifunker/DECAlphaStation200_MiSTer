// Unit bench for rtl/cpu/ev4_imul.v: replays tests/cpu/unit_vectors.py imul.
#include "Vev4_imul.h"
#include <cstdio>
#include <cinttypes>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s VECTORS\n", argv[0]); return 1; }
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }
    Vev4_imul u;
    auto tick = [&]() { u.clk = 0; u.eval(); u.clk = 1; u.eval(); };
    u.rst = 1; tick(); tick(); u.rst = 0;
    unsigned op, fn, wr, ovf; uint64_t a, b, r;
    long n = 0, bad = 0, cycles = 0;
    while (fscanf(f, "%x %x %" SCNx64 " %" SCNx64 " %" SCNx64 " %u %u", &op, &fn, &a, &b, &r, &wr, &ovf) == 7) {
        u.func = fn; u.a = a; u.b = b; u.start = 1;
        tick(); u.start = 0;
        int c = 1;
        while (!u.done && c < 100) { tick(); c++; }
        cycles += c; n++;
        if (!u.done || u.res != r || u.ovf != ovf) {
            if (bad++ < 20)
                fprintf(stderr, "13/%02x a %016" PRIx64 " b %016" PRIx64 ": res %016" PRIx64 " ovf %u done %u, expected %016" PRIx64 " ovf %u\n",
                        fn, a, b, (uint64_t)u.res, u.ovf, u.done, r, ovf);
        }
        tick();
    }
    printf("tb_imul: %ld vectors, %ld mismatches, %.1f cycles each\n", n, bad, n ? (double)cycles / n : 0.0);
    return bad ? 1 : 0;
}
