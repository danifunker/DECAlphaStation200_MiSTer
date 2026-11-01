"""Golden model of the 21064 (EV4) FP operate instructions, opcodes 0x15 (VAX)
and 0x16 (IEEE), in register format (docs/design/cpu.md 8, docs/design/fpu.md).

Written from the architecture, not from the RTL: every operation forms the
exact value (a dyadic m * 2**x, plus a sticky bit for a quotient) and rounds
it to the destination format with the ARM's definitions (4.7.5):

- overflow when the value rounded with an unbounded exponent exceeds MAX;
- underflow when the value rounded to the destination format's grid
  including the denormal steps is below MIN (ARM 4.7.5: e.g. "maps true
  results < MIN - 1/2 LSB to an underflow" for round to nearest). A result
  that rounds up to MIN is MIN, inexact, and no underflow.

On top of that the EV4 rules (HRM 2.6-2.7, cpu.md 8.4): every non-finite
IEEE operand (NaN, Inf, denormal) and every VAX reserved operand or dirty zero
is INV; IEEE 0/0 is INV, x/0 DZE (VAX 0/0 is DZE); underflow writes true zero
(64 zero bits); INV, DZE, OVF always trap; the 21064's divider never sets
FPCR[INE] and DIVx/SUI always traps INE; input exceptions take priority.
The FPU writes 0 where the architecture says UNPREDICTABLE (INV, DZE, OVF).

model(ir, fa, fb, dyn) -> (result, fpcr6, exc7, trap) or None (not legal):
  fpcr6 = FPCR[57:52]: bit 0 INV, 1 DZE, 2 OVF, 3 UNF, 4 INE, 5 IOV
  exc7  = EXC_SUM[8:2]: bit 0 SWC, 1 INV, 2 DZE, 3 FOV, 4 UNF, 5 INE, 6 IOV
"""

M64 = (1 << 64) - 1
RNE, RZ, RM, RP, RNA = range(5)
# p (significand bits with the hidden one), Emin, Emax for 1.f * 2**E
FMT = {'T': (53, -1022, 1023), 'S': (24, -126, 127),
       'G': (53, -1024, 1022), 'F': (24, -128, 126), 'D': (56, -128, 126)}


def pack(fmt, s, E, n):
    """n: p-bit significand (hidden one included), value n * 2**(E-p+1)."""
    p = FMT[fmt][0]
    f = n - (1 << (p - 1))
    if fmt == 'T':
        return s << 63 | (E + 1023) << 52 | f
    if fmt == 'S':
        return s << 63 | (E + 1023) << 52 | f << 29
    if fmt == 'G':
        return s << 63 | (E + 1025) << 52 | f
    if fmt == 'F':
        return s << 63 | (E + 1025) << 52 | f << 29
    return s << 63 | (E + 129) << 55 | f          # D


def rnd_shift(m, x, st, sc, mode, s):
    """Round (m * 2**x + sticky) / 2**sc to an integer. Returns (n, inexact)."""
    sh = sc - x
    if sh <= 0:
        assert not st
        return m << -sh, False
    n = m >> sh
    rem = m & ((1 << sh) - 1)
    half = 1 << (sh - 1)
    if rem == 0 and not st:
        return n, False
    if mode == RZ:
        up = False
    elif mode == RM:
        up = s
    elif mode == RP:
        up = not s
    elif mode == RNA:
        up = rem >= half
    else:
        up = rem > half or (rem == half and (st or (n & 1)))
    return n + up, True


def round_fmt(s, m, x, st, fmt, mode, zsign):
    """(-1)**s * (m * 2**x + sticky) to fmt. Returns (bits, ovf, unf, ine)."""
    if m == 0 and not st:
        return (zsign << 63), False, False, False
    p, emin, emax = FMT[fmt]
    E = m.bit_length() - 1 + x
    if E >= emin:
        n, ine = rnd_shift(m, x, st, E - p + 1, mode, s)
        if n == 1 << p:
            n >>= 1
            E += 1
        if E > emax:
            return 0, True, False, True
        return pack(fmt, s, E, n), False, False, ine
    n, ine = rnd_shift(m, x, st, emin - p + 1, mode, s)   # the denormal grid
    if n == 1 << (p - 1):
        return pack(fmt, s, emin, n), False, False, True
    return 0, False, True, True


# operand decode: ('v', s, m, x) a finite value (m = 0 for zero), or ('bad',)
def dec_ieee(r):
    s, e, f = r >> 63, (r >> 52) & 0x7FF, r & ((1 << 52) - 1)
    if e == 0x7FF or (e == 0 and f):
        return ('bad',)
    if e == 0:
        return ('v', s, 0, 0)
    return ('v', s, (1 << 52) | f, e - 1023 - 52)


def dec_g(r):                                   # G, and F in register format
    s, e, f = r >> 63, (r >> 52) & 0x7FF, r & ((1 << 52) - 1)
    if e == 0:
        return ('v', 0, 0, 0) if (s == 0 and f == 0) else ('bad',)
    return ('v', s, (1 << 52) | f, e - 1025 - 52)


def dec_d(r):
    s, e, f = r >> 63, (r >> 55) & 0xFF, r & ((1 << 55) - 1)
    if e == 0:
        return ('v', 0, 0, 0) if (s == 0 and f == 0) else ('bad',)
    return ('v', s, (1 << 55) | f, e - 129 - 55)


def legal(ir):
    opc, fn = ir >> 26, (ir >> 5) & 0x7FF
    op, src, rnd, trp = fn & 15, (fn >> 4) & 3, (fn >> 6) & 3, fn >> 8
    it4 = trp in (0, 1, 5, 7)
    vt4 = trp in (0, 1, 4, 5)
    if opc == 0x16:
        if op <= 3 and src in (0, 2):
            return it4
        if 4 <= op <= 7 and src == 2:
            return trp in (0, 5) and rnd == 2
        if op == 0xC and src == 2:
            return it4 or (trp in (2, 6) and rnd == 2)
        if op in (0xC, 0xE) and src == 3:
            return trp in (0, 7)
        if op == 0xF and src == 2:
            return it4
        return False
    if opc == 0x15:
        if rnd & 1:
            return False
        if op <= 3 and src in (0, 2):
            return vt4
        if op in (5, 6, 7) and src == 2:
            return trp in (0, 4) and rnd == 2
        if op in (0xC, 0xD) and src == 2:
            return vt4
        if op == 0xE and src == 1:
            return vt4
        if op in (0xC, 0xE) and src == 3:
            return trp == 0
        if op == 0xF and src == 2:
            return vt4
    return False


def model(ir, fa, fb, dyn):
    if not legal(ir):
        return None
    vax = (ir >> 26) == 0x15
    fn = (ir >> 5) & 0x7FF
    op, src, rnd = fn & 15, (fn >> 4) & 3, (fn >> 6) & 3
    en_u, en_i, q_s = fn >> 8 & 1, (fn >> 9 & 1) and not vax, fn >> 10 & 1
    if vax:
        mode = RNA if rnd == 2 else RZ
    else:
        mode = [RZ, RM, RNE, RP][dyn if rnd == 3 else rnd]

    def fin(res, fp, ex):
        trap = ex != 0
        return res & M64, fp, (ex << 1) | (q_s if trap else 0), int(trap)

    def out(r, is_div=False):
        bits, ovf, unf, ine = r
        fp = (ovf << 2) | (unf << 3) | ((ine and not is_div) << 4)
        ex = (ovf << 2) | ((unf and en_u) << 3) | ((en_i and (is_div or ine)) << 4)
        return fin(0 if (ovf or unf) else bits, fp, ex)

    INV, DZE = (1, 0), (2, 1)

    def inexc(which):
        return fin(0, which[0], which[0])

    dec = dec_g if vax else dec_ieee
    # ---- integer source
    if src == 3:
        q = fb - (1 << 64) if fb >> 63 else fb
        fmt = ('F' if op == 0xC else 'G') if vax else ('S' if op == 0xC else 'T')
        return out(round_fmt(int(q < 0), abs(q), 0, False, fmt, mode, 0))
    # ---- conversions from floating
    if op >= 0xC:
        b = dec_d(fb) if (vax and src == 1) else dec(fb)
        if b[0] == 'bad':
            return inexc(INV)
        _, s, m, x = b
        if op == 0xF:                                   # CVTTQ, CVTGQ
            n, ine = rnd_shift(m, x, False, 0, mode, s)
            v = -n if s else n
            iov = not (-(1 << 63) <= v < (1 << 63))
            fp = (iov << 5) | ((ine or iov) << 4)
            ex = ((iov and en_u) << 5) | ((en_i and (ine or iov)) << 4)
            return fin(v, fp, ex)
        if vax:
            fmt = {0xC: 'F', 0xD: 'D', 0xE: 'G'}[op]
        else:
            fmt = 'T' if (fn >> 9 & 1 and not fn >> 8 & 1) else 'S'   # CVTST : CVTTS
        return out(round_fmt(s, m, x, False, fmt, mode, 0 if vax else s))
    # ---- two operands
    a, b = dec(fa), dec(fb)
    if a[0] == 'bad' or b[0] == 'bad':
        return inexc(INV)
    _, sa, ma, xa = a
    _, sb, mb, xb = b
    if 4 <= op <= 7:                                    # compares
        va = (-1) ** sa * ma * 2 ** (xa + 1100) if ma else 0   # exact integers
        vb = (-1) ** sb * mb * 2 ** (xb + 1100) if mb else 0
        t = {4: False, 5: va == vb, 6: va < vb, 7: va <= vb}[op]
        return fin(0x4000000000000000 if t else 0, 0, 0)
    fmt = ('F' if src == 0 else 'G') if vax else ('S' if src == 0 else 'T')
    if op == 3:                                         # divide
        if mb == 0:
            if ma == 0 and not vax:
                return inexc(INV)
            return inexc(DZE)
        s = sa ^ sb
        if ma == 0:
            return out(round_fmt(s, 0, 0, False, fmt, mode, 0 if vax else s), True)
        K = 64 + mb.bit_length() - ma.bit_length() + 4
        qq, rr = divmod(ma << K, mb)
        return out(round_fmt(s, qq, xa - xb - K, rr != 0, fmt, mode, 0), True)
    if op == 2:                                         # multiply
        s = sa ^ sb
        return out(round_fmt(s, ma * mb, xa + xb, False, fmt, mode, 0 if vax else s))
    # add, subtract
    if op == 1:
        sb ^= 1
    if ma == 0:
        xa = xb
    if mb == 0:
        xb = xa
    x = min(xa, xb)
    va = (ma << (xa - x)) * (-1 if sa else 1)
    vb = (mb << (xb - x)) * (-1 if sb else 1)
    v = va + vb
    if vax:
        zs = 0
    elif sa == sb:
        zs = sa
    else:
        zs = int(mode == RM)
    return out(round_fmt(int(v < 0), abs(v), x, False, fmt, mode, zs))
