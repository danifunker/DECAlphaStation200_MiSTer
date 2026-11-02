// Unit bench for rtl/net/tulip21040.v + rtl/net/tulip_nb.v (make -C verilator tb_tulip).
//
// The C++ side plays the 21071 (PCI configuration / I/O / memory accesses on the internal PCI
// target bus of docs/design/pci.md, the DMA port onto a 1 MB little-endian memory), the DDR3
// arbiter's mailbox port (64 KB of 64-bit words), and Main_MiSTer's bridge on the mailbox
// (support/decalpha/decalpha_enet.cpp: PMAC, the TX ring out, the RX ring in, the FCS
// appended). It checks the PCI header and BAR sizing, the CSRs' reset values through both BARs,
// the mailbox start-up, the Ethernet ID ROM read the way SRM's ew_driver reads it (and its
// checks: checksum, the reversed copy, the test pattern; NetBSD's little-endian checksum too),
// the SIA's link report, then the descriptor processes: a perfect setup frame, transmit (two
// buffers, an unaligned buffer, a frame over two chained descriptors, padding, AC), receive
// (perfect filter, broadcast, multicast, PM, PR, a hash setup frame, a frame over three
// descriptors, RU and the missed frame counter, a poll demand), internal loopback with the CRC,
// interrupts (mask, summary, write-1-to-clear), TU and the poll demand, stop (TPS, RPS),
// link fail (CSR12, LNF, the transmit status) and a software reset.
#include "Vtulip21040.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <deque>

static Vtulip21040 *t;
static uint64_t cyc;
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint8_t mem[1 << 20];                    // DMA memory: PCI address = index
static uint64_t mb[8192];                       // the mailbox (DDR3 0x1FF0_0000)

// ---------------------------------------------------------------- Main's bridge (decalpha_enet.cpp)
static const uint64_t MAGIC = 0x4441455448303031ULL;    // DAETH001
static const uint8_t PMAC[6] = {0x08, 0x00, 0x2B, 0xAB, 0xCD, 0xEF};
static uint64_t gen_seen = ~0ULL;
static bool main_link = true;
static std::vector<std::vector<uint8_t>> wire_out;     // frames the core sent
static std::deque<std::vector<uint8_t>> wire_in;       // frames to deliver
static uint64_t main_txr = 0;
static uint32_t crc_tab[256];
static uint32_t crc32_le(const uint8_t *p, int n) {
    uint32_t c = 0xFFFFFFFF;
    while (n--) c = crc_tab[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return c;
}
static void main_poll() {
    if (mb[0] != MAGIC) return;
    if (mb[1] != gen_seen) {
        gen_seen = mb[1];
        uint64_t m = 0;
        for (int i = 0; i < 6; i++) m = m << 8 | PMAC[i];
        mb[7] = (1ULL << 63) | ((uint64_t)main_link << 62) | m;
        main_txr = 0;
    }
    uint64_t txw = mb[2];
    while (main_txr != txw) {
        uint32_t slot = 0x200 + 0x100 * (main_txr % 8);
        int len = mb[slot] & 0x7FF;
        std::vector<uint8_t> f(len);
        for (int i = 0; i < len; i++) f[i] = mb[slot + 1 + i / 8] >> (8 * (i % 8));
        wire_out.push_back(f);
        main_txr++;
    }
    mb[3] = main_txr;
    while (!wire_in.empty()) {
        uint64_t rxw = mb[4], rxr = mb[5];
        if (rxw - rxr >= 16) break;
        std::vector<uint8_t> f = wire_in.front();
        wire_in.pop_front();
        if (f.size() < 60) f.resize(60, 0);
        uint32_t fcs = ~crc32_le(f.data(), f.size());
        for (int k = 0; k < 4; k++) f.push_back(fcs >> (8 * k));
        uint32_t slot = 0xA00 + 0x100 * (rxw % 16);
        for (size_t i = 0; i < (f.size() + 7) / 8 * 8; i += 8) {
            uint64_t w = 0;
            for (int k = 0; k < 8; k++) w |= (uint64_t)(i + k < f.size() ? f[i + k] : 0) << (8 * k);
            mb[slot + 1 + i / 8] = w;
        }
        mb[slot] = f.size();
        mb[4] = rxw + 1;
    }
}

// ---------------------------------------------------------------- the models: DMA, the mailbox port
static int dm_st, dm_cnt, nb_st, nb_cnt;
static int dm_count;
static const uint8_t DEFMAC[6] = {0x08, 0x00, 0x2B, 0x00, 0x00, 0x01};
static void models() {
    // DMA: 3 cycles a longword
    if (dm_st == 2) { t->dm_ack = 0; dm_st = 0; }
    else if (dm_st == 1) {
        if (--dm_cnt == 0) {
            uint32_t a = t->dm_addr & 0xFFFFC;
            CHECK((t->dm_addr & 3) == 0 && t->dm_addr < sizeof(mem), "dm_addr %08X", t->dm_addr);
            if (t->dm_we) { for (int k = 0; k < 4; k++) if (t->dm_be >> k & 1) mem[a + k] = t->dm_wdata >> (8 * k); }
            else t->dm_rdata = mem[a] | mem[a + 1] << 8 | mem[a + 2] << 16 | (uint32_t)mem[a + 3] << 24;
            t->dm_ack = 1; dm_st = 2; dm_count++;
        }
    } else if (t->dm_req) { dm_st = 1; dm_cnt = 3; }
    // the mailbox: 6 cycles a word
    if (nb_st == 2) { t->nb_ack = 0; nb_st = 0; }
    else if (nb_st == 1) {
        if (--nb_cnt == 0) {
            if (t->nb_we) mb[t->nb_addr] = t->nb_wdata;
            else t->nb_rdata = mb[t->nb_addr];
            t->nb_ack = 1; nb_st = 2;
        }
    } else if (t->nb_req) { nb_st = 1; nb_cnt = 6; }
    if (cyc % 256 == 0) main_poll();
    // the top's ROM address: Main's PMAC when it is there, else a fixed DEC address
    uint64_t d = 0;
    for (int i = 0; i < 6; i++) d = d << 8 | DEFMAC[i];
    t->mac = t->nb_pmac_ok ? t->nb_pmac : d;
}
static void tick() {
    t->clk = 0; t->eval();
    t->clk = 1; t->eval();
    cyc++;
    models();
    t->eval();
}
static void ticks(int n) { while (n--) tick(); }

// ---------------------------------------------------------------- the PCI master
enum { CFG = 0, IO = 1, MEMSP = 2 };
static const int DEV = 11;
static const uint32_t IOBASE = 0x9000, MEMBASE = 0x02000080;
static bool pci(int cmd, int dev, uint32_t addr, int be, bool we, uint32_t wdata, uint32_t *rdata = nullptr) {
    t->pt_req = 1; t->pt_cmd = cmd; t->pt_dev = dev; t->pt_addr = addr; t->pt_be = be;
    t->pt_we = we; t->pt_wdata = wdata;
    t->clk = 0; t->eval();
    if (!t->pt_claim) { t->pt_req = 0; if (rdata) *rdata = 0xFFFFFFFF; tick(); return false; }
    for (int n = 0; n < 100; n++) {
        tick();
        if (t->pt_ack) { if (rdata) *rdata = t->pt_rdata; t->pt_req = 0; tick(); return true; }
    }
    CHECK(false, "no pt_ack");
    t->pt_req = 0;
    return false;
}
static uint32_t cfg_rd(int reg, int dev = DEV) { uint32_t v; pci(CFG, dev, reg, 0xF, false, 0, &v); return v; }
static void cfg_wr(int reg, uint32_t v, int be = 0xF) { pci(CFG, DEV, reg & 0xFC, be, true, v); }
static int space = IO;
static uint32_t csr(int n) { uint32_t v; pci(space, 0, (space == IO ? IOBASE : MEMBASE) + 8 * n, 0xF, false, 0, &v); return v; }
static void wcsr(int n, uint32_t v) { pci(space, 0, (space == IO ? IOBASE : MEMBASE) + 8 * n, 0xF, true, v); }

static void put32(uint32_t a, uint32_t v) { for (int k = 0; k < 4; k++) mem[a + k] = v >> (8 * k); }
static uint32_t get32(uint32_t a) { return mem[a] | mem[a + 1] << 8 | mem[a + 2] << 16 | (uint32_t)mem[a + 3] << 24; }

template <class F> static bool wait_for(F f, int limit = 200000) {
    for (int n = 0; n < limit; n++) { if (f()) return true; tick(); }
    return false;
}

// ---------------------------------------------------------------- frames
static std::vector<uint8_t> frame(const uint8_t *da, int len, int seed) {
    std::vector<uint8_t> f(len);
    for (int i = 0; i < len; i++) f[i] = (uint8_t)(i * 7 + seed * 13 + 1);
    memcpy(f.data(), da, 6);
    memcpy(f.data() + 6, "\xAA\x00\x04\x00\x99\x01", 6);
    f[12] = 0x08; f[13] = 0x00;                 // IPv4: an Ethernet type
    return f;
}

// the rings in host memory
static const uint32_t TXR = 0x1000, RXR = 0x2000, TXB = 0x10000, RXB = 0x40000, SETUP = 0x8000;
static const int NTX = 4, NRX = 4;
static int txi, rxi;
static uint32_t txd(int i) { return TXR + 16 * i; }
static uint32_t rxd(int i) { return RXR + 16 * i; }
static void rx_ring_init(int size = 1518) {
    for (int i = 0; i < NRX; i++) {
        put32(rxd(i) + 4, (i == NRX - 1 ? 0x02000000 : 0) | size);     // RER on the last
        put32(rxd(i) + 8, RXB + 0x800 * i);
        put32(rxd(i) + 12, 0);
        put32(rxd(i), 0x80000000);
    }
    rxi = 0;
}
// queue one frame in the next TX descriptor
static void tx_post(uint32_t tdes1, uint32_t b1, uint32_t b2 = 0) {
    int i = txi;
    if (i == NTX - 1) tdes1 |= 0x02000000;      // TER
    put32(txd(i) + 4, tdes1); put32(txd(i) + 8, b1); put32(txd(i) + 12, b2);
    put32(txd(i), 0x80000000);
    txi = (txi + 1) % NTX;
}
static bool tx_done_at(int i) { return !(get32(txd(i)) & 0x80000000); }

static const uint8_t BCAST[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

static void setup_perfect(const std::vector<const uint8_t *> &addrs, int ft = 0) {
    memset(mem + SETUP, 0, 192);
    for (int e = 0; e < 16; e++) {
        const uint8_t *a = addrs[e < (int)addrs.size() ? e : 0];
        for (int h = 0; h < 3; h++) put32(SETUP + 12 * e + 4 * h, 0xDEAD0000 | a[2 * h] | a[2 * h + 1] << 8);
    }
    uint32_t t1 = 0x08000000 | 192 | (ft & 2 ? 0x10000000 : 0) | (ft & 1 ? 0x00400000 : 0);
    tx_post(t1 | 0x80000000, SETUP);            // SET, IC
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtulip21040;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320 & -(c & 1));
        crc_tab[i] = c;
    }
    t->link_up = 1;
    t->reset = 1; ticks(5); t->reset = 0; ticks(5);

    // ---------------------------------------------------------------- the PCI header
    CHECK(cfg_rd(0x00) == 0x00021011, "CFID %08X", cfg_rd(0x00));
    CHECK(cfg_rd(0x08) == 0x02000023, "CFRV %08X", cfg_rd(0x08));
    CHECK(cfg_rd(0x04) == 0x02800000, "CFCS %08X", cfg_rd(0x04));
    CHECK(cfg_rd(0x3C) == 0x00000100, "CFIT %08X", cfg_rd(0x3C));
    CHECK(cfg_rd(0x00, 6) == 0xFFFFFFFF, "device 6 must not be claimed");
    { uint32_t v; CHECK(!pci(CFG, DEV, 0x100, 0xF, false, 0, &v), "function 1 claimed"); }
    cfg_wr(0x10, 0xFFFFFFFF); cfg_wr(0x14, 0xFFFFFFFF);
    CHECK(cfg_rd(0x10) == 0xFFFFFF81, "CBIO sizing %08X", cfg_rd(0x10));
    CHECK(cfg_rd(0x14) == 0xFFFFFF80, "CBMA sizing %08X", cfg_rd(0x14));
    cfg_wr(0x10, IOBASE); cfg_wr(0x14, MEMBASE);
    CHECK(cfg_rd(0x10) == (IOBASE | 1) && cfg_rd(0x14) == MEMBASE, "BARs");
    { uint32_t v; CHECK(!pci(IO, 0, IOBASE, 0xF, false, 0, &v), "I/O claimed while disabled"); }
    cfg_wr(0x04, 0x00000147);
    CHECK(cfg_rd(0x04) == 0x02800147, "CFCS %08X", cfg_rd(0x04));
    cfg_wr(0x0C, 0x0000FF00); CHECK(cfg_rd(0x0C) == 0x0000FF00, "CFLT %08X", cfg_rd(0x0C));
    cfg_wr(0x3C, 0x0000000B); CHECK(cfg_rd(0x3C) == 0x0000010B, "CFIT %08X", cfg_rd(0x3C));
    cfg_wr(0x40, 0x0000AB00); CHECK(cfg_rd(0x40) == 0x0000AB00, "CFDA %08X", cfg_rd(0x40));
    cfg_wr(0x40, 0);

    // ---------------------------------------------------------------- the CSRs after reset, both BARs
    for (int s = 0; s < 2; s++) {
        space = s ? MEMSP : IO;
        CHECK(csr(0) == 0xFFF80000, "CSR0 %08X", csr(0));
        CHECK(csr(5) == 0xFC000000, "CSR5 %08X", csr(5));
        CHECK(csr(6) == 0xFFFC0040, "CSR6 %08X", csr(6));
        CHECK(csr(7) == 0xFFFE0000, "CSR7 %08X", csr(7));
        CHECK(csr(8) == 0xFFFE0000, "CSR8 %08X", csr(8));
        CHECK(csr(11) == 0xFFFF0000, "CSR11 %08X", csr(11));
        CHECK(csr(12) == 0xFFFFFFC4, "CSR12 %08X", csr(12));
        CHECK(csr(13) == 0xFFFF0000 && csr(14) == 0xFFFFFFFF && csr(15) == 0xFFFF0000, "SIA CSRs");
    }
    space = IO;
    CHECK(t->inta_n == 1, "inta_n after reset");

    // ---------------------------------------------------------------- the mailbox up, Main's PMAC
    CHECK(wait_for([] { return t->nb_pmac_ok; }, 20000), "no PMAC from Main");
    CHECK(mb[0] == MAGIC, "magic %016llX", (unsigned long long)mb[0]);
    CHECK(t->nb_link == 1, "nb_link");
    ticks(10);
    CHECK(wait_for([] { return mb[6] == 0x800008002BABCDEFULL; }, 20000), "published MAC %016llX", (unsigned long long)mb[6]);

    // ---------------------------------------------------------------- the Ethernet ID ROM, as SRM reads it
    uint8_t ni[32];
    wcsr(9, 0);
    for (int i = 0; i < 32; i++) {
        int j;
        for (j = 0; j < 1000; j++) { uint32_t v = csr(9); if (!(v & 0x80000000)) { ni[i] = v; break; } }
        CHECK(j < 1000, "CSR9 DN never cleared");
    }
    CHECK(!memcmp(ni, PMAC, 6), "ROM address %02X-%02X-%02X-%02X-%02X-%02X", ni[0], ni[1], ni[2], ni[3], ni[4], ni[5]);
    {   // SRM tu_nirom_checksum: big-endian words; NetBSD tlp_parse_old_srom: little-endian words
        uint32_t c = 0;
        for (int i = 0; i < 6; i += 2) { c += c; c += ni[i] << 8 | ni[i + 1]; }
        while (c >= 65535) c -= 65535;
        CHECK(c == (uint32_t)(ni[6] << 8 | ni[7]), "SRM checksum %04X vs %02X%02X", c, ni[6], ni[7]);
        uint32_t l = 0;
        for (int i = 0; i < 6; i += 2) { l <<= 1; if (l > 0xFFFF) l -= 0xFFFF; l += ni[i] | ni[i + 1] << 8; if (l > 0xFFFF) l -= 0xFFFF; }
        if (l == 0xFFFF) l = 0;
        CHECK(l == (uint32_t)(ni[6] | ni[7] << 8), "NetBSD checksum");
        for (int i = 0; i < 8; i++) CHECK(ni[15 - i] == ni[16 + i] && ni[i] == ni[15 - i], "ROM copy %d", i);
        static const uint8_t pat[8] = {0xFF, 0x00, 0x55, 0xAA, 0xFF, 0x00, 0x55, 0xAA};
        CHECK(!memcmp(ni + 24, pat, 8), "ROM test pattern");
    }
    { uint32_t v = csr(9); CHECK(v & 0x80000000, "CSR9 DN right after a read"); }

    // ---------------------------------------------------------------- SRM's start-up: CSR0, the SIA, CSR6, CSR7
    wcsr(0, 0x00004800);                        // PBL8 | CAL1
    CHECK(csr(0) == 0xFFF84800, "CSR0 %08X", csr(0));
    wcsr(13, 0); wcsr(14, 0xFFFF7F3D); wcsr(15, 0x0008); wcsr(13, 0xEF01);   // 10BASE-T
    CHECK(csr(12) == 0xFFFFFF38, "CSR12 link pass %08X", csr(12));
    CHECK(csr(14) == 0xFFFF7F3D, "CSR14 %08X", csr(14));
    wcsr(6, 0);
    wcsr(7, 0x0C01FFFF);
    CHECK(csr(7) == 0xFFFFBFEF, "CSR7 %08X", csr(7));
    rx_ring_init();
    for (int i = 0; i < NTX; i++) put32(txd(i), 0);
    wcsr(3, RXR); wcsr(4, TXR);
    CHECK(csr(3) == RXR && csr(4) == TXR, "list bases");
    txi = 0;

    // ---------------------------------------------------------------- a perfect setup frame, then start
    uint8_t ME[6]; memcpy(ME, PMAC, 6);
    static const uint8_t MC1[6] = {0x09, 0x00, 0x2B, 0x00, 0x00, 0x0F};
    setup_perfect({ME, BCAST, MC1});
    wcsr(6, 0x00002002);                        // ST | SR
    CHECK(wait_for([] { return tx_done_at(0); }), "setup frame not taken");
    CHECK(get32(txd(0)) == 0x7FFFFFFF, "setup TDES0 %08X", get32(txd(0)));
    CHECK((csr(6) & 0x15) == 0, "CSR6 filter bits %08X", csr(6));
    ticks(50);
    { uint32_t s5 = csr(5); CHECK((s5 & 0x00010001) == 0x00010001, "TI/NIS after setup %08X", s5);
      CHECK(t->inta_n == 0, "INTA after the setup frame");
      CHECK(((s5 >> 20) & 7) == 6 && ((s5 >> 17) & 7) == 3, "TS suspended, RS waiting: %08X", s5);
      CHECK(s5 & 4, "TU after the ring ran dry");
      wcsr(5, s5);
      CHECK((csr(5) & 0x1FFFF) == 0, "CSR5 W1C %08X", csr(5));
      ticks(3); CHECK(t->inta_n == 1, "INTA after the clear"); }

    // ---------------------------------------------------------------- transmit: two buffers, buffer 1 unaligned
    std::vector<uint8_t> f1 = frame(BCAST, 100, 1);
    memcpy(mem + TXB + 3, f1.data(), 41);
    memcpy(mem + TXB + 0x400, f1.data() + 41, 59);
    tx_post(0xE0000000 | (59 << 11) | 41, TXB + 3, TXB + 0x400);     // IC LS FS
    wcsr(1, 1);
    CHECK(wait_for([] { return wire_out.size() >= 1; }), "frame 1 not on the wire");
    CHECK(wire_out.size() == 1 && wire_out[0] == f1, "frame 1 data (len %zu)", wire_out.empty() ? 0 : wire_out[0].size());
    CHECK(get32(txd(1)) == 0x00000000, "frame 1 TDES0 %08X", get32(txd(1)));

    // a frame over two chained descriptors (TCH), and a short frame (padded, CRC added by the chip)
    {
        std::vector<uint8_t> f2 = frame(ME, 300, 2);
        memcpy(mem + TXB + 0x1000, f2.data(), 200);
        memcpy(mem + TXB + 0x1800, f2.data() + 200, 100);
        // descriptor 2: FS, buffer 1, chained to descriptor 3 by TDES3
        put32(txd(3) + 4, 0x42000000 | 100 | 0x01000000); put32(txd(3) + 8, TXB + 0x1800); put32(txd(3) + 12, 0);
        put32(txd(3), 0x80000000);
        put32(txd(2) + 4, 0x21000000 | 200); put32(txd(2) + 8, TXB + 0x1000); put32(txd(2) + 12, txd(3));
        put32(txd(2), 0x80000000);
        txi = 0;
        std::vector<uint8_t> f3 = frame(ME, 20, 3);
        memcpy(mem + TXB + 0x2000, f3.data(), 20);
        tx_post(0xE0000000 | 20, TXB + 0x2000);  // descriptor 0 (after the TER of 3)
        wcsr(1, 1);
        CHECK(wait_for([] { return wire_out.size() >= 3; }), "frames 2-3 not on the wire");
        CHECK(wire_out.size() >= 2 && wire_out[1] == f2, "frame 2 (two descriptors)");
        f3.resize(60, 0);
        CHECK(wire_out.size() >= 3 && wire_out[2] == f3, "frame 3 padded to 60 (len %zu)", wire_out.size() >= 3 ? wire_out[2].size() : 0);
        CHECK(get32(txd(2)) == 0 && get32(txd(3)) == 0 && get32(txd(0)) == 0, "TDES0s");
        // AC: the driver's own CRC is not sent to the mailbox
        std::vector<uint8_t> f4 = frame(ME, 70, 4);
        uint32_t fcs = ~crc32_le(f4.data(), 70);
        memcpy(mem + TXB + 0x2800, f4.data(), 70);
        for (int k = 0; k < 4; k++) mem[TXB + 0x2800 + 70 + k] = fcs >> (8 * k);
        tx_post(0xE4000000 | 74, TXB + 0x2800);  // descriptor 1, AC
        wcsr(1, 1);
        CHECK(wait_for([] { return wire_out.size() >= 4; }), "frame 4");
        CHECK(wire_out.size() >= 4 && wire_out[3] == f4, "frame 4 (AC) without the FCS");
    }

    // ---------------------------------------------------------------- receive, perfect filtering
    auto rx_wait = [](int i) { bool ok = wait_for([i] { return !(get32(rxd(i)) & 0x80000000); }, 300000); ticks(20); return ok; };
    auto rx_check = [](int i, const std::vector<uint8_t> &f, const char *what) {
        uint32_t r0 = get32(rxd(i));
        int fl = r0 >> 16 & 0x7FFF;
        int len = f.size() < 60 ? 60 : f.size();
        CHECK(fl == len + 4, "%s: FL %d (RDES0 %08X)", what, fl, r0);
        CHECK((r0 & 0x0300) == 0x0300 && !(r0 & 0x8000), "%s: FS LS no ES (RDES0 %08X)", what, r0);
        CHECK(!memcmp(mem + get32(rxd(i) + 8), f.data(), f.size()), "%s: data", what);
        std::vector<uint8_t> p = f; p.resize(len, 0);
        uint32_t fcs = ~crc32_le(p.data(), len), got = get32(get32(rxd(i) + 8) + len);
        if ((len & 3) == 0) CHECK(got == fcs, "%s: FCS %08X vs %08X", what, got, fcs);
    };
    {
        wcsr(5, 0xFFFFFFFF);
        std::vector<uint8_t> a = frame(ME, 200, 10);
        wire_in.push_back(a);
        CHECK(rx_wait(0), "unicast to us not received");
        rx_check(0, a, "unicast");
        { uint32_t s5 = csr(5); CHECK(s5 & 0x40, "RI %08X", s5); }
        CHECK(((get32(rxd(0)) >> 5) & 1) == 1, "FT (Ethernet type)");
        static const uint8_t OTHER[6] = {0x08, 0x00, 0x2B, 0x99, 0x99, 0x99};
        static const uint8_t MC2[6] = {0x09, 0x00, 0x2B, 0x00, 0x00, 0x10};
        wire_in.push_back(frame(OTHER, 64, 11));    // not ours: dropped
        wire_in.push_back(frame(MC2, 64, 12));      // a multicast not in the table: dropped
        std::vector<uint8_t> b = frame(BCAST, 61, 13), c = frame(MC1, 1514, 14);
        wire_in.push_back(b); wire_in.push_back(c);
        CHECK(rx_wait(2), "broadcast / multicast not received");
        rx_check(1, b, "broadcast");
        rx_check(2, c, "multicast in the table (1514)");
        CHECK(get32(rxd(1)) & 0x0400, "MF on broadcast");
        CHECK(get32(rxd(3)) & 0x80000000, "a filtered frame took descriptor 3");
        // PM: all multicast
        wcsr(6, 0x00002082);
        std::vector<uint8_t> d = frame(MC2, 64, 15);
        wire_in.push_back(d);
        CHECK(rx_wait(3), "PM multicast");
        rx_check(3, d, "PM multicast");
        // the ring ran dry: RU, then a missed frame
        ticks(100);
        { uint32_t s5 = csr(5); CHECK(s5 & 0x80, "RU %08X", s5); CHECK(((s5 >> 17) & 7) == 4, "RS suspended %08X", s5); }
        wcsr(5, 0xFFFFFFFF);
        wire_in.push_back(frame(ME, 64, 16));
        CHECK(wait_for([] { return (csr(8) & 0xFFFF) == 1; }, 400000), "missed frame counter");
        CHECK((csr(8) & 0x1FFFF) == 0, "CSR8 clears on read");
        CHECK(!(csr(5) & 0x80), "RU only once");
        // give the ring back; a poll demand resumes
        rx_ring_init();
        wcsr(2, 1);
        CHECK(wait_for([] { return ((csr(5) >> 17) & 7) == 3; }, 1000), "poll demand: running");
        // PR: anything
        wcsr(6, 0x00002042);
        std::vector<uint8_t> e = frame(OTHER, 100, 17);
        wire_in.push_back(e);
        CHECK(rx_wait(0), "PR");
        rx_check(0, e, "promiscuous");
        wcsr(6, 0x00002002);
    }

    // ---------------------------------------------------------------- a hash setup frame (512 + 1)
    {
        static const uint8_t MC3[6] = {0x01, 0x00, 0x5E, 0x00, 0x00, 0x01}, MC4[6] = {0x01, 0x00, 0x5E, 0x00, 0x00, 0x02};
        memset(mem + SETUP, 0, 192);
        auto hset = [](const uint8_t *a) { int h = crc32_le(a, 6) & 0x1FF; mem[SETUP + 4 * (h >> 4) + ((h >> 3) & 1)] |= 1 << (h & 7); };
        hset(MC3); hset(BCAST);
        for (int hh = 0; hh < 3; hh++) put32(SETUP + 156 + 4 * hh, ME[2 * hh] | ME[2 * hh + 1] << 8);
        int s = txi;
        tx_post(0x88400000 | 192, SETUP);         // SET, FT0 = hash
        wcsr(1, 1);
        CHECK(wait_for([s] { return tx_done_at(s); }), "hash setup");
        CHECK((csr(6) & 0x15) == 0x01, "HP after a hash setup %08X", csr(6));
        std::vector<uint8_t> a = frame(MC3, 80, 20), b = frame(MC4, 80, 21), c = frame(ME, 90, 22);
        wire_in.push_back(b); wire_in.push_back(a); wire_in.push_back(c);
        CHECK(rx_wait(2), "hash: frames");
        rx_check(1, a, "hashed multicast");
        rx_check(2, c, "the perfect address");
        CHECK(get32(rxd(3)) & 0x80000000, "unhashed multicast dropped");
        // back to perfect filtering
        setup_perfect({ME, BCAST, MC1});
        wcsr(1, 1);
        CHECK(wait_for([] { return (csr(6) & 0x15) == 0; }), "perfect again");
    }

    // ---------------------------------------------------------------- a frame over three descriptors
    {
        wcsr(6, 0);                              // stop both
        CHECK(wait_for([] { return (csr(5) & 0x00FE0000) == 0; }, 1000), "stopped (TS RS = 0)");
        CHECK((csr(5) & 0x102) == 0x102, "TPS RPS");
        rx_ring_init(256);
        wcsr(3, RXR);
        wcsr(5, 0xFFFFFFFF);
        wcsr(6, 0x00002002);
        std::vector<uint8_t> a = frame(ME, 600, 30);
        wire_in.push_back(a);
        CHECK(rx_wait(2), "three descriptors");
        uint32_t r0 = get32(rxd(0)), r1 = get32(rxd(1)), r2 = get32(rxd(2));
        CHECK(r0 == 0x00000200 && r1 == 0x00000000, "first/middle RDES0 %08X %08X", r0, r1);
        CHECK((r2 & 0x7FFF0300) == ((604u << 16) | 0x0100), "last RDES0 %08X", r2);
        std::vector<uint8_t> got;
        for (int i = 0; i < 3; i++) got.insert(got.end(), mem + RXB + 0x800 * i, mem + RXB + 0x800 * i + 256);
        CHECK(!memcmp(got.data(), a.data(), 600), "data over three buffers");
        wcsr(6, 0);
        rx_ring_init();
        wcsr(3, RXR);
    }

    // ---------------------------------------------------------------- internal loopback
    {
        CHECK(wait_for([] { return (csr(5) & 0x00FE0000) == 0; }, 1000), "stopped");
        wcsr(6, 0x00002402);                     // OM = internal loopback, ST, SR
        size_t before = wire_out.size();
        std::vector<uint8_t> a = frame(ME, 128, 40);
        memcpy(mem + TXB + 0x3000, a.data(), 128);
        tx_post(0xE0000000 | 128, TXB + 0x3000);
        wcsr(1, 1);
        CHECK(rx_wait(0), "loopback frame not received");
        rx_check(0, a, "loopback");
        CHECK(((get32(rxd(0)) >> 12) & 3) == 1, "DT = internal loopback %08X", get32(rxd(0)));
        CHECK(wire_out.size() == before, "a loopback frame reached the wire");
        wcsr(6, 0);
        CHECK(wait_for([] { return (csr(5) & 0x00FE0000) == 0; }, 1000), "stopped");
        rx_ring_init(); wcsr(3, RXR);
        wcsr(6, 0x00002002);
    }

    // ---------------------------------------------------------------- link fail
    {
        wcsr(5, 0xFFFFFFFF);
        t->link_up = 0;
        ticks(5);
        CHECK((csr(12) & 0x6) == 0x6, "CSR12 LKF NCR %08X", csr(12));
        CHECK(csr(5) & 0x1000, "LNF");
        int s = txi;
        std::vector<uint8_t> a = frame(ME, 64, 50);
        memcpy(mem + TXB, a.data(), 64);
        size_t before = wire_out.size();
        tx_post(0xE0000000 | 64, TXB);
        wcsr(1, 1);
        CHECK(wait_for([s] { return tx_done_at(s); }), "link fail: closed");
        CHECK(get32(txd(s)) == 0x00008C04, "link fail TDES0 %08X", get32(txd(s)));
        ticks(2000);
        CHECK(wire_out.size() == before, "sent with no link");
        t->link_up = 1;
        ticks(5);
        CHECK((csr(12) & 0x6) == 0, "link back");
    }

    // ---------------------------------------------------------------- truncation: the frame outgrows the owned descriptors
    {
        wcsr(6, 0);
        CHECK(wait_for([] { return (csr(5) & 0x00FE0000) == 0; }, 1000), "stopped");
        rx_ring_init(256);
        put32(rxd(2), 0); put32(rxd(3), 0);      // only two are ours
        wcsr(3, RXR);
        wcsr(5, 0xFFFFFFFF);
        wcsr(6, 0x00002002);
        std::vector<uint8_t> a = frame(ME, 600, 60);
        wire_in.push_back(a);
        CHECK(rx_wait(1), "truncated frame");
        uint32_t r0 = get32(rxd(0)), r1 = get32(rxd(1));
        CHECK(r0 == 0x00000200, "truncation: first RDES0 %08X", r0);
        CHECK((r1 & 0x8000C300) == 0x0000C100, "truncation: LS LE ES, no FS %08X", r1);
        uint32_t s5 = csr(5);
        CHECK((s5 & 0xC0) == 0xC0 && ((s5 >> 17) & 7) == 4, "truncation: RI RU suspended %08X", s5);
        CHECK(!memcmp(mem + RXB, a.data(), 256) && !memcmp(mem + RXB + 0x800, a.data() + 256, 256), "truncation: data");
        wcsr(6, 0);
        CHECK(wait_for([] { return (csr(5) & 0x00FE0000) == 0; }, 1000), "stopped");
        rx_ring_init(); wcsr(3, RXR);
        wcsr(6, 0x00002002);
    }

    // ---------------------------------------------------------------- transmit automatic polling (CSR0<18:17> = 01: 200 us)
    {
        wcsr(0, 0x00024800);
        ticks(100);
        CHECK(((csr(5) >> 20) & 7) == 6, "TS suspended before TAP");
        int s = txi;
        size_t before = wire_out.size();
        std::vector<uint8_t> a = frame(BCAST, 90, 70);
        memcpy(mem + TXB, a.data(), 90);
        tx_post(0xE0000000 | 90, TXB);           // no poll demand
        ticks(15000);
        CHECK(!tx_done_at(s), "TAP polled too early");
        CHECK(wait_for([s] { return tx_done_at(s); }, 30000), "TAP did not poll");
        CHECK(wait_for([before] { return wire_out.size() == before + 1; }, 20000) && wire_out.back() == a, "TAP frame");
        wcsr(0, 0x00004800);
    }

    // ---------------------------------------------------------------- a software reset
    {
        wcsr(0, 1);
        ticks(20);
        CHECK(csr(0) == 0xFFF80000 && csr(6) == 0xFFFC0040 && csr(7) == 0xFFFE0000, "after SWR");
        CHECK((csr(5) & 0x03FFFFFF) == 0, "CSR5 after SWR %08X", csr(5));
        CHECK(cfg_rd(0x10) == (IOBASE | 1) && cfg_rd(0x04) == 0x02800147, "the configuration after SWR");
        CHECK(t->inta_n == 1, "INTA after SWR");
    }

    printf("tb_tulip: %d checks, %d failures, %llu cycles, %d DMA longwords, %zu frames out\n",
           checks, fails, (unsigned long long)cyc, dm_count, wire_out.size());
    delete t;
    return fails ? 1 : 0;
}
