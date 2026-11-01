// Unit bench for rtl/cpu/ev4_fpu_dec.v: every function code of opcodes 15 and 16
// against tests/fpu/fpmodel.py's legal() (lines "IR LEGAL" on stdin).
#include "Vev4_fpu_dec.h"
#include <cstdio>

int main() {
    Vev4_fpu_dec u;
    unsigned ir, lg; long n = 0, bad = 0;
    while (scanf("%x %u", &ir, &lg) == 2) {
        u.ir = ir; u.eval(); n++;
        unsigned fn = (ir >> 5) & 0x7FF, op = fn & 15;
        bool fen = (ir >> 26) == 0x16 && ((fn >> 4) & 3) == 1;
        if (u.legal != lg || u.fen != fen || u.div != (op == 3) || u.rd_fa != (op < 8)) {
            if (bad++ < 20) fprintf(stderr, "%08x: legal %u fen %u div %u rd_fa %u, want legal %u fen %u\n",
                                    ir, u.legal, u.fen, u.div, u.rd_fa, lg, fen);
        }
    }
    printf("tb_fpu_dec: %ld codes, %ld mismatches\n", n, bad);
    return bad != 0;
}
