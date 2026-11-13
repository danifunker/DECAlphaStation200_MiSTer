// rtl/apecs/bcache.v alone (64 lines: -GLB=6), between a requester that behaves as the 21071
// model's DRAM port does (the request and its address hold until the last answer, the request
// drops the cycle after it) and a memory that behaves as rtl/mister/sdram_ctl.v does (a write
// is copied and acknowledged when taken, a read after a random time, a line's quadwords at random
// distances; a new request only after the request has dropped). Random line reads, single reads,
// partial and whole-line writes over a few tags:
//  - every quadword read is the reference memory's,
//  - each request makes exactly the memory reads a model of the write-back cache predicts (its
//    tags and dirty bits): a read of a missing line, nothing for a hit; the memory writes (a
//    partial write that misses, a dirty victim's line, which the victim buffer may send later)
//    add up to the model's at every flush,
//  - a flush (line reads of an unused tag at every index) puts every dirty line back: after it
//    the memory equals the reference; one runs before each reset and at the end,
//  - a reset empties the cache, en = 0 passes everything through.
#include "Vbcache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <array>

typedef std::array<uint8_t, 32> Line;
static Line fresh(uint32_t ln) {            // a line never written: a function of its number
    Line l; uint32_t x = ln * 2654435761u + 12345;
    for (int i = 0; i < 32; i++) { x = x * 1664525u + 1013904223u; l[i] = x >> 24; }
    return l;
}
struct Mem {
    std::map<uint32_t, Line> m;
    Line &at(uint32_t ln) { auto it = m.find(ln); if (it == m.end()) it = m.emplace(ln, fresh(ln)).first; return it->second; }
};
static uint32_t rnd() { static uint32_t s = 0x1234567; s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vbcache *t = new Vbcache;
    const int LB = 6, LINES = 1 << LB;
    const uint32_t FT = 0x3A5;              // the flush's tag: no random request uses it
    Mem ref, mem;
    uint32_t model[LINES]; bool mv[LINES], md[LINES];
    int fails = 0; uint64_t checks = 0, hits = 0, misses = 0, ops = 0, vics = 0, whits = 0, flushes = 0;
    auto bad = [&](const char *what, uint64_t cyc, uint32_t ln) {
        if (fails++ < 20) printf("FAIL at cycle %llu, line %x: %s\n", (unsigned long long)cyc, ln, what);
    };
    // requester
    bool r_req = false, r_we = false, r_line = false; uint32_t r_addr = 0, r_be = 0; uint8_t r_wd[32] = {};
    int r_beats = 0, r_gap = 4; bool r_exp_hit = false;
    int x_mw = 0, x_mr = 0, n_mw = 0, n_mr = 0;     // memory writes and reads: expected, seen
    uint64_t tot_xmw = 0, tot_mw = 0;               // memory writes since the start: the model's, seen
    int quiet_n = 0;                                // cycles with nothing going on
    // memory
    bool m_busy = false, m_acked = false, m_line = false; uint32_t m_addr = 0; int m_wait = 0, m_beat = 0;
    bool s_ack = false; uint64_t s_rdata = 0;
    int phase = 0; uint64_t rst_until = 0;
    int flush = -1;                         // >= 0: the next flush index
    bool flush_for_reset = false;

    t->clk = 0; t->rst = 1; t->en = 1; t->d_req = 0; t->s_ack = 0;
    for (int k = 0; k < LINES; k++) mv[k] = md[k] = false;
    auto compare_all = [&](uint64_t cyc) {
        for (auto &e : ref.m) { checks++; if (mem.at(e.first) != e.second) bad("the memory differs from the reference after a flush", cyc, e.first); }
        checks++;
        if (tot_mw != tot_xmw) {
            char s[120]; snprintf(s, sizeof s, "%llu memory writes, the model says %llu", (unsigned long long)tot_mw, (unsigned long long)tot_xmw);
            bad(s, cyc, 0);
        }
    };
    const uint64_t N = 3000000;
    bool final_flush = false, done = false;
    for (uint64_t cyc = 0; cyc < N + 50000 && !done; cyc++) {
        if (cyc == 4) t->rst = 0;
        quiet_n = (!r_req && !m_busy && !t->s_req) ? quiet_n + 1 : 0;
        bool quiet = quiet_n > 8;                   // the victim buffer has gone back by then
        // a flush, then a reset in the middle, then en = 0 for a while, then on again
        if (flush < 0 && !flush_for_reset && phase < 3 && quiet && r_gap > 0 && !rst_until &&
            ((phase == 0 && cyc > N / 3) || (phase == 1 && cyc > N / 2) || (phase == 2 && cyc > 2 * N / 3))) {
            if (t->en) { flush = 0; flush_for_reset = true; }
            else { phase++; t->rst = 1; rst_until = cyc + 3; t->en = 1; for (int k = 0; k < LINES; k++) mv[k] = md[k] = false; r_gap = LINES + 20; }
        }
        if (flush_for_reset && flush < 0 && quiet) {
            compare_all(cyc); flushes++;
            flush_for_reset = false; phase++; t->rst = 1; rst_until = cyc + 3; t->en = phase != 2;
            for (int k = 0; k < LINES; k++) mv[k] = md[k] = false;
            r_gap = LINES + 20;
        }
        if (cyc >= N && !final_flush && quiet && flush < 0 && !flush_for_reset && !rst_until) {
            final_flush = true;
            if (t->en) flush = 0;
        }
        if (final_flush && flush < 0 && quiet && !rst_until) { compare_all(cyc); flushes++; done = true; }
        if (rst_until && cyc == rst_until) { t->rst = 0; rst_until = 0; }
        t->eval();
        bool d_ack = t->d_ack, sreq = t->s_req; uint64_t d_rdata = t->d_rdata;

        // ---- the requester's registers
        bool n_req = r_req;
        if (r_req) {
            if (d_ack) {
                uint32_t ln = r_addr >> 2;
                if (!r_we) {
                    int q = r_line ? r_beats : (r_addr & 3);
                    uint64_t want; memcpy(&want, &ref.at(ln)[8 * q], 8);
                    checks++;
                    if (d_rdata != want) bad("read data", cyc, ln);
                }
                r_beats++;
                if (!r_line || r_we || r_beats == 4) {
                    n_req = false; r_gap = rnd() % 4 == 0 ? rnd() % 12 : 0; ops++;
                    checks++;
                    if (n_mr != x_mr || n_mw > x_mw + 1) {
                        char s[160]; snprintf(s, sizeof s, "memory traffic %d writes %d reads, the model says %d %d (%s%s)",
                                              n_mw, n_mr, x_mw, x_mr, r_we ? "write" : r_line ? "line read" : "read", r_exp_hit ? ", hit" : "");
                        bad(s, cyc, ln);
                    }
                    tot_xmw += x_mw;
                    if (!r_we && t->en) (r_exp_hit ? hits : misses)++;
                }
            }
        } else if (!t->rst && !rst_until && (flush >= 0 || (cyc < N && !flush_for_reset))) {
            if (r_gap > 0) r_gap--;
            else {
                static const uint32_t tags[6] = {0, 1, 2, 3, 0xFFFF, 0x8001};
                uint32_t ln;
                int k;
                if (flush >= 0) {
                    ln = (FT << LB) | flush; k = 0;                  // a line read
                    if (++flush == LINES) flush = -1;
                } else {
                    ln = ((tags[rnd() % (rnd() % 4 ? 2 : 6)] << LB) | (rnd() % (rnd() % 3 ? 8 : LINES))) & 0x3FFFFF;
                    k = rnd() % 100;
                }
                int ix = ln & (LINES - 1);
                bool present = mv[ix] && model[ix] == ln, vdirty = mv[ix] && md[ix] && !present;
                n_req = true; r_beats = 0; r_exp_hit = present; n_mw = n_mr = 0;
                r_we = k >= 60; r_line = k < 45;
                r_addr = (ln << 2) | (r_line ? 0 : rnd() & 3);
                if (r_we) {
                    r_line = false;
                    int kind = rnd() % 4;
                    r_be = kind == 0 ? 0xFFFFFFFFu : kind == 1 ? 0xFFu << (8 * (rnd() & 3)) :
                           kind == 2 ? 0xFu << (4 * (rnd() & 7)) : (rnd() | (1u << (rnd() & 31)));
                    for (int i = 0; i < 32; i++) r_wd[i] = rnd();
                    Line &l = ref.at(ln);
                    for (int i = 0; i < 32; i++) if (r_be >> i & 1) l[i] = r_wd[i];
                    if (!t->en) { x_mw = 1; x_mr = 0; }
                    else if (present) { x_mw = 0; x_mr = 0; md[ix] = true; whits++; }
                    else if (r_be == 0xFFFFFFFFu) { x_mw = vdirty; x_mr = 0; mv[ix] = true; md[ix] = true; model[ix] = ln; vics += vdirty; }
                    else { x_mw = 1; x_mr = 0; }
                } else {
                    if (!t->en) { x_mw = 0; x_mr = 1; }
                    else if (present) { x_mw = 0; x_mr = 0; }
                    else if (r_line) { x_mw = vdirty; x_mr = 1; mv[ix] = true; md[ix] = false; model[ix] = ln; vics += vdirty; }
                    else { x_mw = 0; x_mr = 1; }
                }
            }
        }
        // ---- the memory's registers
        bool n_ack = false; uint64_t n_rdata = s_rdata;
        if (!sreq) m_acked = false;
        if (!m_busy) {
            if (sreq && !m_acked && !s_ack) {
                bool we = t->s_we; m_line = t->s_line && !we; m_addr = t->s_addr;
                if (we) {
                    n_mw++; tot_mw++;
                    Line &l = mem.at(m_addr >> 2);
                    for (int i = 0; i < 32; i++) if (t->s_be >> i & 1) l[i] = (uint8_t)(t->s_wdata[i >> 2] >> (8 * (i & 3)));
                    n_ack = true; m_acked = true;
                } else { n_mr++; m_busy = true; m_beat = 0; m_wait = rnd() % 9; }
            }
        } else if (m_wait > 0) m_wait--;
        else {
            int q = m_line ? m_beat : (m_addr & 3);
            memcpy(&n_rdata, &mem.at(m_addr >> 2)[8 * q], 8);
            n_ack = true; m_beat++; m_wait = rnd() % 5;
            if (!m_line || m_beat == 4) { m_busy = false; m_acked = true; }
        }

        t->clk = 1; t->eval(); t->clk = 0;
        r_req = n_req; s_ack = n_ack; s_rdata = n_rdata;
        t->d_req = r_req; t->d_we = r_we; t->d_line = r_line; t->d_addr = r_addr; t->d_be = r_be;
        for (int i = 0; i < 8; i++) memcpy(&t->d_wdata[i], &r_wd[4 * i], 4);
        t->s_ack = s_ack; t->s_rdata = s_rdata;
    }
    if (r_req) { printf("FAIL: a request never ended\n"); fails++; }
    if (!done) { printf("FAIL: the final flush did not finish\n"); fails++; }
    if (hits < 30000 || misses < 30000 || vics < 10000 || whits < 10000 || flushes != 3) {
        printf("FAIL: too few hits, misses, victims, write hits or flushes\n"); fails++;
    }
    printf("tb_bcache: %llu requests, %llu read hits, %llu read misses, %llu write hits, %llu dirty victims, %llu flushes, %llu checks, %d failures\n",
           (unsigned long long)ops, (unsigned long long)hits, (unsigned long long)misses, (unsigned long long)whits,
           (unsigned long long)vics, (unsigned long long)flushes, (unsigned long long)checks, fails);
    delete t;
    return fails ? 1 : 0;
}
