// Unit bench for rtl/cpu/ev4_ialu.v: replays tests/cpu/unit_vectors.py ialu.
#include "Vev4_ialu.h"
#include <cstdio>
#include <cinttypes>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s VECTORS\n", argv[0]); return 1; }
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }
    Vev4_ialu u;
    unsigned op, fn, wr, ovf; uint64_t a, b, r;
    long n = 0, bad = 0;
    while (fscanf(f, "%x %x %" SCNx64 " %" SCNx64 " %" SCNx64 " %u %u", &op, &fn, &a, &b, &r, &wr, &ovf) == 7) {
        u.op = op; u.func = fn; u.a = a; u.b = b;
        u.eval();
        n++;
        if (u.illegal || u.res != r || u.wr != wr || u.ovf != ovf) {
            if (bad++ < 20)
                fprintf(stderr, "op %02x/%02x a %016" PRIx64 " b %016" PRIx64 ": res %016" PRIx64
                        " wr %u ovf %u ill %u, expected %016" PRIx64 " wr %u ovf %u\n",
                        op, fn, a, b, (uint64_t)u.res, u.wr, u.ovf, u.illegal, r, wr, ovf);
        }
    }
    printf("tb_ialu: %ld vectors, %ld mismatches\n", n, bad);
    return bad ? 1 : 0;
}
