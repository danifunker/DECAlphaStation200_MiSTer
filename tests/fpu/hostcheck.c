/* Cross-check of fpmodel.py's IEEE vectors against the host's IEEE 754
 * hardware (x86-64 SSE, with the rounding mode set through fenv), for every
 * vector whose operands are finite (no INV/DZE expected). The host rounds
 * subnormal results to the denormal grid, so "the rounded result is below
 * MIN" is exactly the ARM's underflow rule.
 *
 *   cc -O1 -frounding-math -o hostcheck hostcheck.c -lm
 *   python3 gen_fpu.py ... | ./hostcheck
 */
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <inttypes.h>

static double d_of(uint64_t r) { double d; memcpy(&d, &r, 8); return d; }
static uint64_t r_of(double d) { uint64_t r; memcpy(&r, &d, 8); return r; }
/* S in register format is the T encoding of the same value */
static uint64_t r_of_s(float f) { return r_of((double)f); }

int main(void) {
    unsigned ir, dyn, fpcr, exc, trap;
    uint64_t a, b, res;
    long n = 0, chk = 0, bad = 0;
    static const int fe[4] = {FE_TOWARDZERO, FE_DOWNWARD, FE_TONEAREST, FE_UPWARD};
    while (scanf("%x %" SCNx64 " %" SCNx64 " %x %" SCNx64 " %x %x %x", &ir, &a, &b, &dyn, &res, &fpcr, &exc, &trap) == 8) {
        n++;
        if ((ir >> 26) != 0x16 || (fpcr & 3)) continue;           /* IEEE, no input exception */
        unsigned fn = (ir >> 5) & 0x7FF, op = fn & 15, src = (fn >> 4) & 3, rnd = (fn >> 6) & 3;
        fesetround(fe[rnd == 3 ? dyn : rnd]);
        feclearexcept(FE_ALL_EXCEPT);
        volatile double x = d_of(a), y = d_of(b);
        uint64_t want = 0; int ovf = 0, unf = 0, ine = 0, iov = 0, isdiv = 0, cmp = 0;
        if (op <= 3 && src == 0) {                                 /* S */
            volatile float fx = (float)x, fy = (float)y, r;
            if (op == 0) r = fx + fy; else if (op == 1) r = fx - fy; else if (op == 2) r = fx * fy; else r = fx / fy;
            int ex = fetestexcept(FE_ALL_EXCEPT);
            ovf = !!(ex & FE_OVERFLOW); ine = !!(ex & FE_INEXACT); isdiv = op == 3;
            unf = !ovf && ((r != 0 && fabsf(r) < 0x1p-126f) || (r == 0 && ine));
            want = r_of_s(r);
        } else if (op <= 3) {                                      /* T */
            volatile double r;
            if (op == 0) r = x + y; else if (op == 1) r = x - y; else if (op == 2) r = x * y; else r = x / y;
            int ex = fetestexcept(FE_ALL_EXCEPT);
            ovf = !!(ex & FE_OVERFLOW); ine = !!(ex & FE_INEXACT); isdiv = op == 3;
            unf = !ovf && ((r != 0 && fabs(r) < 0x1p-1022) || (r == 0 && ine));
            want = r_of(r);
        } else if (op <= 7) {
            cmp = op == 5 ? x == y : op == 6 ? x < y : op == 7 ? x <= y : 0;
            want = cmp ? 0x4000000000000000ull : 0;
        } else if (op == 0xC && src == 2 && ((fn >> 9) & 1) && !((fn >> 8) & 1)) {   /* CVTST */
            if ((double)(float)y != y) continue;                   /* not an S value: UNPREDICTABLE */
            want = r_of((double)(float)y);
        } else if (op == 0xC && src == 2) {                        /* CVTTS */
            volatile float r = (float)y;
            int ex = fetestexcept(FE_ALL_EXCEPT);
            ovf = !!(ex & FE_OVERFLOW); ine = !!(ex & FE_INEXACT);
            unf = !ovf && ((r != 0 && fabsf(r) < 0x1p-126f) || (r == 0 && ine));
            want = r_of_s(r);
        } else if (src == 3) {                                     /* CVTQS, CVTQT */
            volatile int64_t q = (int64_t)b;
            if (op == 0xC) { volatile float r = (float)q; want = r_of_s(r); }
            else { volatile double r = (double)q; want = r_of(r); }
            ine = !!fetestexcept(FE_INEXACT);
        } else if (op == 0xF) {                                    /* CVTTQ */
            volatile double r = rint(y);
            ine = !!fetestexcept(FE_INEXACT);
            if (r >= 0x1p63 || r < -0x1p63) iov = 1;
            else want = (uint64_t)(int64_t)r;
        } else continue;
        chk++;
        int ok;
        if (iov) ok = (fpcr >> 5) & 1;
        else if (ovf) ok = (fpcr & 4) && res == 0;
        else if (unf) ok = (fpcr & 8) && res == 0;
        else ok = res == want && !(fpcr & 0x2C) && ((fpcr >> 4 & 1) == (unsigned)(ine && !isdiv));
        if (!ok && bad++ < 20)
            fprintf(stderr, "%08x %016" PRIx64 " %016" PRIx64 " dyn %u: model %016" PRIx64 " fpcr %02x, host %016" PRIx64
                    " ovf %d unf %d ine %d iov %d\n", ir, a, b, dyn, res, fpcr, want, ovf, unf, ine, iov);
    }
    printf("hostcheck: %ld vectors, %ld checked against the host, %ld disagree\n", n, chk, bad);
    return bad != 0;
}
