// rtl/apecs/bcache.v alone (64 lines: -GLB=6), between a requester that behaves as the 21071
// model's DRAM port does (the request and its address hold until the last answer, the request
// drops the cycle after it) and a memory that behaves as rtl/mister/sdram_ctl.v does (a write
// is acknowledged when taken, a read after a random time, a line's quadwords at random
// distances). Random line reads, single reads, partial and whole-line writes over a few tags:
//  - every quadword read is the reference memory's,
//  - a read goes to the memory exactly when the model of the cache says the line is not there,
//  - every write reaches the memory (compared at the end),
//  - a reset in the middle empties the cache, en = 0 passes everything through.
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
    Mem ref, mem;
    uint32_t model[LINES]; bool mv[LINES];
    int fails = 0; uint64_t checks = 0, hits = 0, misses = 0, ops = 0;
    auto bad = [&](const char *what, uint64_t cyc, uint32_t ln) {
        if (fails++ < 20) printf("FAIL at cycle %llu, line %x: %s\n", (unsigned long long)cyc, ln, what);
    };
    // requester
    bool r_req = false, r_we = false, r_line = false; uint32_t r_addr = 0, r_be = 0; uint8_t r_wd[32] = {};
    int r_beats = 0, r_gap = 4; bool r_sreq_seen = false, r_exp_hit = false;
    // memory
    bool m_busy = false, m_acked = false, m_we = false, m_line = false; uint32_t m_addr = 0; int m_wait = 0, m_beat = 0;
    bool s_ack = false; uint64_t s_rdata = 0;
    int phase = 0; uint64_t rst_until = 0;

    t->clk = 0; t->rst = 1; t->en = 1; t->d_req = 0; t->s_ack = 0;
    for (int k = 0; k < LINES; k++) mv[k] = false;
    const uint64_t N = 3000000;
    for (uint64_t cyc = 0; cyc < N + 2000; cyc++) {
        if (cyc == 4) t->rst = 0;
        // a reset in the middle (with nothing in flight), then en = 0 for a while, then on again
        bool quiet = !r_req && !m_busy && !t->s_req;
        if (((phase == 0 && cyc > N / 3) || (phase == 1 && cyc > N / 2) || (phase == 2 && cyc > 2 * N / 3)) && quiet && r_gap > 2) {
            phase++; t->rst = 1; rst_until = cyc + 3; t->en = phase != 2;
            for (int k = 0; k < LINES; k++) mv[k] = false;
            r_gap = LINES + 20;
        }
        if (rst_until && cyc == rst_until) { t->rst = 0; rst_until = 0; }
        t->eval();
        bool d_ack = t->d_ack, sreq = t->s_req; uint64_t d_rdata = t->d_rdata;

        // ---- the requester's registers
        bool n_req = r_req;
        if (r_req) {
            if (sreq) r_sreq_seen = true;
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
                    if (t->en) {
                        if (!r_we) {
                            checks++;
                            if (r_exp_hit && r_sreq_seen) bad("a read of a cached line went to the memory", cyc, ln);
                            if (!r_exp_hit && !r_sreq_seen) bad("a read of an absent line was answered by the cache", cyc, ln);
                            (r_exp_hit ? hits : misses)++;
                        } else if (!r_sreq_seen) bad("a write did not reach the memory", cyc, ln);
                    }
                }
            }
        } else if (!t->rst && cyc < N) {
            if (r_gap > 0) r_gap--;
            else {
                static const uint32_t tags[6] = {0, 1, 2, 3, 0xFFFF, 0x8001};
                uint32_t ln = ((tags[rnd() % (rnd() % 4 ? 2 : 6)] << LB) | (rnd() % (rnd() % 3 ? 8 : LINES))) & 0x3FFFFF;
                int k = rnd() % 100, ix = ln & (LINES - 1);
                bool present = mv[ix] && model[ix] == ln;
                n_req = true; r_beats = 0; r_sreq_seen = false; r_exp_hit = present;
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
                    if (t->en && r_be == 0xFFFFFFFFu && !present) { mv[ix] = true; model[ix] = ln; }
                } else if (t->en && r_line && !present) { mv[ix] = true; model[ix] = ln; }
            }
        }
        // ---- the memory's registers
        bool n_ack = false; uint64_t n_rdata = s_rdata;
        if (!sreq) m_acked = false;
        if (!m_busy) {
            if (sreq && !m_acked && !s_ack) {
                m_we = t->d_we; m_line = t->d_line && !t->d_we; m_addr = t->d_addr;
                if (m_we) {
                    Line &l = mem.at(m_addr >> 2);
                    for (int i = 0; i < 32; i++) if (t->d_be >> i & 1) l[i] = (uint8_t)(t->d_wdata[i >> 2] >> (8 * (i & 3)));
                    n_ack = true; m_acked = true;
                } else { m_busy = true; m_beat = 0; m_wait = rnd() % 9; }
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
    for (auto &e : ref.m) { checks++; if (mem.at(e.first) != e.second) bad("the memory differs from the reference at the end", 0, e.first); }
    if (hits < 30000 || misses < 30000) { printf("FAIL: too few hits or misses\n"); fails++; }
    printf("tb_bcache: %llu requests, %llu read hits, %llu read misses, %llu checks, %d failures\n",
           (unsigned long long)ops, (unsigned long long)hits, (unsigned long long)misses, (unsigned long long)checks, fails);
    delete t;
    return fails ? 1 : 0;
}
