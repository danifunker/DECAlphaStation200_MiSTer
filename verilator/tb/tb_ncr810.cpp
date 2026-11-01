// Unit bench for rtl/scsi/ncr53c810.v + rtl/scsi/scsi_targets.v
// (make -C verilator tb_ncr810).
//
// The C++ side plays the 21071 (PCI configuration / I/O / memory accesses on
// the internal PCI target bus of docs/design/pci.md, and the DMA port onto a
// 1 MB little-endian memory) and hps_io (block devices: two disks and a
// CD-ROM image in memory, 512-byte blocks). It checks the PCI header and BAR
// sizing, the DROM V1.7 "53C810 Test" accesses (config 0xDC-0xDF), register
// access through both BARs, SRM's chip reset and bus reset, then runs SCRIPTS
// programs against the targets: INQUIRY, TEST UNIT READY, READ CAPACITY,
// READ(10), WRITE(10), a selection timeout, LOAD/STORE, memory moves, single
// step, and the CD-ROM's block size through MODE SELECT. Then the CD-ROM's
// track table and audio (Main's windows on slot 2, docs/design/cdrom.md: a
// made-up disc of a data track and two audio tracks in two sessions): the
// table without Main's window, UNIT ATTENTION after a remount, READ TOC
// formats 0/1/2 in LBA and M:S:F, PLAY AUDIO MSF / TRACK INDEX with every
// sample checked on cd_audio_l/r/stb, READ SUB-CHANNEL, PAUSE/RESUME, STOP,
// MODE SELECT/SENSE page 0E (volume, channel selection), READ CD, NOT READY
// with no disc; and the disks' new commands (READ/WRITE(12), MODE SENSE
// pages, DBD, FORMAT UNIT with a defect list, READ DEFECT DATA).
#include "Vtb_ncr810_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <string>

static Vtb_ncr810_top *t;
static uint64_t cyc;
static int fails;
static uint8_t mem[1 << 20];                    // DMA memory: PCI address = index
static std::vector<uint8_t> img[3];             // the block devices

// ---------------------------------------------------------------- the CD's windows (support/decalpha)
// the disc: track 1 data at LBA 0 (8 sectors: img[2]), track 2 audio at 8,
// track 3 audio at 12 (session 2), the lead-out at 16
static bool win_on = false;                     // Main serves the windows (else zeros: the stock Main)
static const int AUD_T2 = 8, AUD_T3 = 12, LEADOUT = 16;
static int16_t smp_l(int f, int k) { return (int16_t)(0x1000 + f * 600 + k); }
static int16_t smp_r(int f, int k) { return (int16_t)-(0x1000 + f * 600 + k); }
static void toc_entry(uint8_t *e, int ctl, int trk, int lba) {
    int a = lba + 150;
    e[0] = ctl; e[1] = trk; e[2] = a / 4500; e[3] = a / 75 % 60; e[4] = a % 75;
    e[5] = lba >> 16; e[6] = lba >> 8; e[7] = lba;
}
static uint8_t cd_byte(uint32_t lba, int pos) {
    if (lba >= 0x80000000u && !win_on) return 0;
    if (lba >= 0xC0000000u) {
        uint8_t t[1024] = {};
        t[0] = 1; t[1] = 3; t[2] = 4; t[3] = 1; t[4] = 3; t[5] = 2;
        toc_entry(t + 8, 0x14, 1, 0); toc_entry(t + 16, 0x10, 2, AUD_T2); toc_entry(t + 24, 0x10, 3, AUD_T3);
        toc_entry(t + 32, 0x10, 0xAA, LEADOUT);
        return (lba == 0xC0000000u && pos < 1024) ? t[pos] : (lba == 0xC0000001u ? 0 : t[pos & 1023]);
    }
    if (lba >= 0x80000000u) {
        uint64_t off = (uint64_t)(lba - 0x80000000u) * 512 + pos;
        int f = off / 2560, fo = off % 2560;
        if (fo >= 2352 || f < AUD_T2 || f >= LEADOUT) return 0;
        int k = fo / 4;
        int16_t v = (fo & 2) ? smp_r(f, k) : smp_l(f, k);
        return (fo & 1) ? (uint8_t)((uint16_t)v >> 8) : (uint8_t)v;
    }
    size_t a = (size_t)lba * 512 + pos;
    return a < img[2].size() ? img[2][a] : 0;
}
// the audio output, sampled at cd_audio_stb
static bool cap_on = false;
static std::vector<std::pair<int16_t, int16_t>> cap;
static int stb_count;

#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ---------------------------------------------------------------- DMA and hps_io models
static int dma_wait = -1;
static int sd_slot = -1, sd_dir, sd_pos, sd_len;
static uint32_t sd_lba_q;

static uint32_t slot_lba(int s) { return t->sd_lba[s]; }
static int slot_cnt(int s) { return (int)((t->sd_blk_cnt >> (6 * s)) & 63) + 1; }

static void models() {
    // DMA: ack two cycles after the request
    t->dm_ack = 0;
    if (t->dm_req) {
        if (dma_wait < 0) dma_wait = 2;
        else if (dma_wait > 0) dma_wait--;
        if (dma_wait == 0) {
            uint32_t a = t->dm_addr & 0xFFFFC;
            if (t->dm_we) {
                for (int k = 0; k < 4; k++) if (t->dm_be & (1 << k)) mem[a + k] = t->dm_wdata >> (8 * k);
            } else
                t->dm_rdata = mem[a] | mem[a + 1] << 8 | mem[a + 2] << 16 | (uint32_t)mem[a + 3] << 24;
            t->dm_ack = 1;
            dma_wait = -1;
        }
    }
    // hps_io: one request at a time, a byte a cycle
    t->sd_buff_wr = 0;
    if (sd_slot < 0) {
        for (int s = 0; s < 3; s++) if ((t->sd_rd | t->sd_wr) & (1 << s)) {
            sd_slot = s; sd_dir = (t->sd_wr >> s) & 1; sd_pos = -1; sd_len = slot_cnt(s) * 512;
            sd_lba_q = slot_lba(s);
            t->sd_ack = 1 << s;
            break;
        }
    } else {
        size_t base = (size_t)sd_lba_q * 512;
        if (sd_dir == 0) {
            sd_pos++;
            if (sd_pos < sd_len) {
                t->sd_buff_addr = sd_pos; t->sd_buff_wr = 1;
                if (sd_slot == 2) t->sd_buff_dout = cd_byte(sd_lba_q, sd_pos);
                else t->sd_buff_dout = base + sd_pos < img[sd_slot].size() ? img[sd_slot][base + sd_pos] : 0xEE;
            } else { t->sd_ack = 0; sd_slot = -1; }
        } else {
            // the buffer's read port answers the cycle after the address
            if (sd_pos >= 0 && base + sd_pos < img[sd_slot].size()) img[sd_slot][base + sd_pos] = t->sd_buff_din;
            sd_pos++;
            if (sd_pos < sd_len) t->sd_buff_addr = sd_pos;
            else { t->sd_ack = 0; sd_slot = -1; }
        }
    }
}

static void tick() {
    t->clk = 0; t->eval();
    t->clk = 1; t->eval();
    cyc++;
    if (t->cd_audio_stb) { stb_count++; if (cap_on) cap.push_back({(int16_t)t->cd_audio_l, (int16_t)t->cd_audio_r}); }
    models();
    t->eval();
}

// ---------------------------------------------------------------- the PCI master
enum { CFG = 0, IO = 1, MEMSP = 2 };
static const uint32_t IOBASE = 0x8000, MEMBASE = 0x01000000;

// one access; returns false (all ones) when nobody claims it
static bool pci(int cmd, int dev, uint32_t addr, int be, bool we, uint32_t wdata, uint32_t *rdata = nullptr) {
    t->pt_req = 1; t->pt_cmd = cmd; t->pt_dev = dev; t->pt_addr = addr; t->pt_be = be;
    t->pt_we = we; t->pt_wdata = wdata;
    t->clk = 0; t->eval();
    if (!t->pt_claim) { t->pt_req = 0; if (rdata) *rdata = 0xFFFFFFFF; tick(); return false; }
    for (int n = 0; n < 100; n++) {
        tick();
        if (t->pt_ack) { if (rdata) *rdata = t->pt_rdata; t->pt_req = 0; return true; }
    }
    CHECK(false, "no pt_ack");
    t->pt_req = 0;
    return false;
}
static uint32_t cfg_rd(int dev, int reg, int fn = 0) {
    uint32_t v; pci(CFG, dev, (fn << 8) | reg, 0xF, false, 0, &v); return v;
}
static void cfg_wr(int reg, uint32_t v, int be = 0xF) { pci(CFG, 6, reg & 0xFC, be, true, v << (8 * (reg & 3))); }
// chip registers through BAR1 (memory) by default, or BAR0 (I/O)
static int space = MEMSP;
static uint32_t base() { return space == MEMSP ? MEMBASE : IOBASE; }
static uint8_t rb(int r) { uint32_t v; pci(space, 0, base() + (r & ~3), 1 << (r & 3), false, 0, &v); return v >> (8 * (r & 3)); }
static void wb(int r, uint8_t v) { pci(space, 0, base() + (r & ~3), 1 << (r & 3), true, (uint32_t)v << (8 * (r & 3))); }
static uint32_t rl(int r) { uint32_t v; pci(space, 0, base() + r, 0xF, false, 0, &v); return v; }
static void wl(int r, uint32_t v) { pci(space, 0, base() + r, 0xF, true, v); }

enum { SCNTL0 = 0x00, SCNTL1 = 0x01, SCNTL2 = 0x02, SCNTL3 = 0x03, SCID = 0x04, SXFER = 0x05, SFBR = 0x08,
       DSTAT = 0x0C, DSA = 0x10, ISTAT = 0x14, CTEST3 = 0x1B, TEMP = 0x1C, DFIFO = 0x20, CTEST4 = 0x21,
       DBC = 0x24, DNAD = 0x28, DSP = 0x2C, DSPS = 0x30, SCRATCHA = 0x34, DMODE = 0x38, DIEN = 0x39,
       DCNTL = 0x3B, SIEN0 = 0x40, SIEN1 = 0x41, SIST0 = 0x42, SIST1 = 0x43, STIME0 = 0x48, RESPID = 0x4A,
       STEST3 = 0x4F, SCRATCHB = 0x5C };

// ---------------------------------------------------------------- SCRIPTS
static void put32(uint32_t a, uint32_t v) { for (int k = 0; k < 4; k++) mem[a + k] = v >> (8 * k); }
static uint32_t get32(uint32_t a) { return mem[a] | mem[a + 1] << 8 | mem[a + 2] << 16 | (uint32_t)mem[a + 3] << 24; }

static const uint32_t SCRIPT = 0x1000, MSGOUT = 0x2000, CMD = 0x2010, STS = 0x2020, MSGIN = 0x2028,
                      TABLE = 0x2100, DATA = 0x4000;
enum { P_DOUT = 0, P_DIN = 1, P_CMD = 2, P_STS = 3, P_MOUT = 6, P_MIN = 7 };

// wait for ISTAT.DIP or SIP (polled, as SRM runs the chip); returns ISTAT
static uint8_t wait_int(int limit = 400000) {
    for (int n = 0; n < limit; n += 64) {
        uint8_t i = rb(ISTAT);
        if (i & 3) return i;
        for (int k = 0; k < 64; k++) tick();
    }
    CHECK(false, "no interrupt (DSP %08X)", rl(DSP));
    return 0;
}

// a command to target id: SELECT ATN, IDENTIFY, the CDB, the data phase (table
// indirect from DSA: {count, address}), STATUS, MESSAGE IN, CLEAR ACK, WAIT
// DISCONNECT, INT 0x600D. Returns DSPS (0x600D when the program ends).
static uint32_t run_cmd(int id, const std::vector<uint8_t> &cdb, int dphase, uint32_t dlen, uint8_t *sts, uint8_t *msg) {
    uint32_t p = SCRIPT;
    auto ins = [&](uint32_t a, uint32_t b) { put32(p, a); put32(p + 4, b); p += 8; };
    mem[MSGOUT] = 0x80;                                          // IDENTIFY, LUN 0
    for (size_t k = 0; k < cdb.size(); k++) mem[CMD + k] = cdb[k];
    put32(TABLE, dlen); put32(TABLE + 4, DATA);
    mem[STS] = 0xAA; mem[MSGIN] = 0xAA;
    ins(0x41000000 | id << 16, 0);                               // SELECT ATN id
    ins(0x98000000 | P_MOUT << 24 | 0x30000, 0xE1);             // INT 0xE1, WHEN NOT MSG_OUT
    ins(0x0E000001, MSGOUT);                                     // MOVE 1, msgout, WHEN MSG_OUT
    ins(0x0A000000 | (uint32_t)cdb.size(), CMD);                 // MOVE n, cmd, WHEN CMD
    ins(0x830B0000, SCRIPT + 0x30);                              // JUMP status, WHEN STATUS
    ins(0x18000000 | dphase << 24, 0);                           // MOVE FROM 0 (DSA table), WHEN data
    ins(0x0B000001, STS);                                        // 0x30: MOVE 1, sts, WHEN STATUS
    ins(0x0F000001, MSGIN);                                      // MOVE 1, msgin, WHEN MSG_IN
    ins(0x60000040, 0);                                          // CLEAR ACK
    ins(0x48000000, 0);                                          // WAIT DISCONNECT
    ins(0x98080000, 0x600D);                                     // INT 0x600D
    wl(DSA, TABLE);
    wl(DSP, SCRIPT);                                             // DMODE.MAN = 0: starts
    uint8_t i = wait_int();
    uint8_t ds = rb(DSTAT);
    uint8_t s0 = rb(SIST0), s1 = rb(SIST1);
    if (sts) *sts = mem[STS];
    if (msg) *msg = mem[MSGIN];
    if (!(i & 1) || !(ds & 4)) { printf("  (istat %02X dstat %02X sist0 %02X sist1 %02X dsp %08X)\n", i, ds, s0, s1, rl(DSP)); return 0; }
    return rl(DSPS);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_ncr810_top;

    // the images: disk 0 = 64 blocks with a pattern, disk 1 absent, CD = 8 x 2048 bytes
    img[0].resize(64 * 512);
    for (size_t k = 0; k < img[0].size(); k++) img[0][k] = (uint8_t)(k * 7 + (k >> 9));
    img[2].resize(8 * 2048);
    for (size_t k = 0; k < img[2].size(); k++) img[2][k] = (uint8_t)(k ^ 0x5A);
    t->img_present = 0b101;
    t->img_blocks[0] = 64; t->img_blocks[1] = 0; t->img_blocks[2] = 32;

    t->reset = 1;
    for (int k = 0; k < 8; k++) tick();
    t->reset = 0;
    tick();

    // ---- PCI configuration header
    CHECK(cfg_rd(6, 0x00) == 0x00011000, "ID %08X", cfg_rd(6, 0x00));
    {   // the DROM reads the ID with a byte length: all 32 bits come back
        uint32_t v; pci(CFG, 6, 0x00, 0x1, false, 0, &v);
        CHECK((v & 0xFFFF) == 0x1000, "byte-length ID read %08X", v);
    }
    CHECK(cfg_rd(6, 0x08) == 0x01000002, "class/rev %08X", cfg_rd(6, 0x08));
    CHECK(cfg_rd(6, 0x00, 1) == 0xFFFFFFFF, "function 1 claimed");
    CHECK(cfg_rd(7, 0x00) == 0xFFFFFFFF, "device 7 claimed");
    CHECK((cfg_rd(6, 0x3C) & 0xFFFFFF00) == 0x40110100, "int pin/min_gnt/max_lat %08X", cfg_rd(6, 0x3C));
    cfg_wr(0x10, 0xFFFFFFFF); cfg_wr(0x14, 0xFFFFFFFF);
    CHECK(cfg_rd(6, 0x10) == 0xFFFFFF01, "BAR0 size %08X", cfg_rd(6, 0x10));
    CHECK(cfg_rd(6, 0x14) == 0xFFFFFF00, "BAR1 size %08X", cfg_rd(6, 0x14));
    cfg_wr(0x10, IOBASE); cfg_wr(0x14, MEMBASE);
    CHECK(!pci(MEMSP, 0, MEMBASE, 0xF, false, 0), "BAR1 decoded before the memory enable");
    cfg_wr(0x04, 0x0007, 0x3);                                   // I/O, memory, bus master
    cfg_wr(0x3C, 3, 0x1);                                        // interrupt line
    CHECK((cfg_rd(6, 0x04) & 0xFFFF) == 0x0007, "command %08X", cfg_rd(6, 0x04));
    CHECK((cfg_rd(6, 0x3C) & 0xFF) == 3, "interrupt line");
    printf("PCI header: ID 00011000, class 010000 rev 02, BAR0 I/O %X, BAR1 memory %X\n", IOBASE, MEMBASE);

    // ---- the DROM V1.7 53C810 Test: 0xAA then 0x55 into config bytes 0xDC-0xDF, each read back
    for (int pat : {0xAA, 0x55})
        for (int lane = 0; lane < 4; lane++) {
            pci(CFG, 6, 0xDC, 1 << lane, true, (uint32_t)pat << (8 * lane));
            uint32_t v; pci(CFG, 6, 0xDC, 1 << lane, false, 0, &v);
            CHECK(((v >> (8 * lane)) & 0xFF) == (uint32_t)pat, "DROM pattern %02X lane %d read %08X", pat, lane, v);
        }
    CHECK(rl(SCRATCHB) == 0x55555555, "SCRATCHB after the DROM test %08X", rl(SCRATCHB));
    printf("DROM 53C810 Test accesses: pass\n");

    // ---- registers through both BARs
    space = IO; wl(SCRATCHA, 0x12345678);
    space = MEMSP; CHECK(rl(SCRATCHA) == 0x12345678, "SCRATCHA via BAR1 %08X", rl(SCRATCHA));
    wb(SCRATCHA + 2, 0xAB);
    space = IO; CHECK(rl(SCRATCHA) == 0x12AB5678, "SCRATCHA byte write %08X", rl(SCRATCHA));
    CHECK(rb(SCRATCHA + 3) == 0x12, "byte read via BAR0");
    CHECK(pci(IO, 0, IOBASE + 0x80 + SCRATCHA, 0xF, false, 0), "80-FF alias");
    space = MEMSP;
    CHECK(rb(DSTAT) == 0x80, "DSTAT %02X", rb(DSTAT));
    CHECK(rb(ISTAT) == 0x00, "ISTAT %02X", rb(ISTAT));
    CHECK((rb(CTEST3) >> 4) == 2, "CTEST3 revision");

    // ---- SRM's n810_init_n810 and pke_bus_reset
    wb(ISTAT, 0x40); wb(ISTAT, 0x00);
    CHECK(rl(SCRATCHA) == 0, "SCRATCHA after the chip reset");
    wb(SCNTL0, 0x0A); wb(SCNTL1, 0x80); wb(SCNTL3, 0x33); wb(SCID, 7); wb(SXFER, 0);
    wb(CTEST4, 0x08); wb(DMODE, 0xC0); wb(DIEN, 0); wb(DCNTL, 0x09); wb(SIEN0, 0); wb(SIEN1, 0);
    wb(STEST3, 0x80); wb(RESPID, 0x80); wl(SCRATCHB, 0x96000769);
    CHECK(rb(SCNTL3) == 0x33 && rb(DMODE) == 0xC0 && rb(DCNTL) == 0x09 && rb(STEST3) == 0x80, "init registers");
    wb(SCNTL1, 0x08);
    for (int k = 0; k < 20; k++) tick();
    wb(SCNTL1, 0x80);
    CHECK(rb(ISTAT) & 2, "SIP after the bus reset");
    CHECK(rb(SIST0) == 0x02, "SIST0.RST");
    CHECK(rb(SIST0) == 0x00, "SIST0 read clears");
    rb(SIST1); rb(DSTAT);
    CHECK(rb(ISTAT) == 0, "ISTAT clear %02X", rb(ISTAT));
    wb(STIME0, 0x01);                                            // a short selection timeout (bench: STO_UNIT 16)
    wb(DIEN, 0x04);                                              // SIR interrupts on INTA

    uint8_t sts, msg;
    // ---- INQUIRY on ID 0
    memset(mem + DATA, 0xCC, 64);
    uint32_t r = run_cmd(0, {0x12, 0, 0, 0, 36, 0}, P_DIN, 36, &sts, &msg);
    CHECK(r == 0x600D && sts == 0 && msg == 0, "INQUIRY dsps %X status %02X msg %02X", r, sts, msg);
    CHECK(mem[DATA] == 0x00 && mem[DATA + 4] == 31, "INQUIRY header");
    CHECK(!memcmp(mem + DATA + 8, "DEC     RZ28     (C) DEC442D", 28), "INQUIRY strings %.28s", mem + DATA + 8);
    CHECK(mem[DATA + 36] == 0xCC, "INQUIRY overran");
    printf("INQUIRY dka0: \"%.28s\" status %02X\n", mem + DATA + 8, sts);
    // the SIR interrupt reached INTA while DSTAT held it; DSTAT was read in run_cmd
    CHECK(t->inta_n == 1, "INTA still asserted after the DSTAT read");
    {   // INTA asserted while SIR is pending
        uint32_t p = SCRIPT;
        put32(p, 0x98080000); put32(p + 4, 0x1111);
        wl(DSP, SCRIPT);
        wait_int();
        CHECK(t->inta_n == 0, "INTA not asserted on SIR");
        rb(DSTAT);
        tick();                                                  // INTA is registered: one clock after the read
        CHECK(t->inta_n == 1, "INTA not released");
        CHECK(rl(DSPS) == 0x1111, "INT DSPS");
    }

    // ---- TEST UNIT READY
    r = run_cmd(0, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0, &sts, &msg);
    CHECK(r == 0x600D && sts == 0, "TEST UNIT READY dsps %X status %02X", r, sts);
    // ---- READ CAPACITY
    r = run_cmd(0, {0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 8, &sts, &msg);
    CHECK(r == 0x600D && sts == 0 && get32(DATA) == 0x3F000000 && get32(DATA + 4) == 0x00020000,
          "READ CAPACITY %08X %08X", get32(DATA), get32(DATA + 4));
    // ---- READ(10) LBA 3, 3 blocks
    memset(mem + DATA, 0, 2048);
    r = run_cmd(0, {0x28, 0, 0, 0, 0, 3, 0, 0, 3, 0}, P_DIN, 1536, &sts, &msg);
    CHECK(r == 0x600D && sts == 0, "READ(10) dsps %X status %02X", r, sts);
    CHECK(!memcmp(mem + DATA, &img[0][3 * 512], 1536), "READ(10) data");
    printf("READ(10) dka0 LBA 3, 3 blocks: %s\n", memcmp(mem + DATA, &img[0][3 * 512], 1536) ? "data differs" : "data ok");
    // ---- WRITE(10) LBA 10, 1 block
    for (int k = 0; k < 512; k++) mem[DATA + k] = (uint8_t)(0xA0 + k * 3);
    r = run_cmd(0, {0x2A, 0, 0, 0, 0, 10, 0, 0, 1, 0}, P_DOUT, 512, &sts, &msg);
    CHECK(r == 0x600D && sts == 0, "WRITE(10) dsps %X status %02X", r, sts);
    CHECK(!memcmp(&img[0][10 * 512], mem + DATA, 512), "WRITE(10) data in the image");
    printf("WRITE(10) dka0 LBA 10: %s\n", memcmp(&img[0][10 * 512], mem + DATA, 512) ? "data differs" : "data ok");
    // ---- REQUEST SENSE after an illegal command
    r = run_cmd(0, {0xC7, 0, 0, 0, 0, 0}, P_DIN, 0, &sts, &msg);
    CHECK(r == 0x600D && sts == 2, "vendor command status %02X", sts);
    r = run_cmd(0, {0x03, 0, 0, 0, 18, 0}, P_DIN, 18, &sts, &msg);
    CHECK(r == 0x600D && sts == 0 && mem[DATA] == 0x70 && mem[DATA + 2] == 5 && mem[DATA + 12] == 0x20,
          "REQUEST SENSE %02X %02X %02X", mem[DATA], mem[DATA + 2], mem[DATA + 12]);

    // ---- selection timeout: nobody at ID 1
    {
        uint32_t p = SCRIPT;
        put32(p, 0x41010000); put32(p + 4, 0); put32(p + 8, 0x98080000); put32(p + 12, 0xBAD);
        wl(DSP, SCRIPT);
        uint8_t i = wait_int();
        CHECK(i == 0x02, "STO ISTAT %02X", i);
        CHECK(rb(SIST0) == 0 && rb(SIST1) == 0x04, "SIST1.STO");
        printf("SELECT ID 1 (absent): selection timeout, SIST1.STO\n");
    }

    // ---- register instructions, LOAD/STORE, memory move, single step
    {
        uint32_t p = SCRIPT;
        auto ins = [&](uint32_t a, uint32_t b) { put32(p, a); put32(p + 4, b); p += 8; };
        put32(0x5000, 0xCAFEF00D);
        wl(SCRATCHA, 0x00000000);
        ins(0x78340000 | 0x11 << 8, 0);                          // MOVE 0x11 TO SCRATCHA0
        ins(0x7E340000 | 0x22 << 8, 0);                          // MOVE SCRATCHA0 + 0x22 TO SCRATCHA0 (0x33)
        ins(0x6A340000, 0);                                      // MOVE SFBR | 0 TO SCRATCHA0
        ins(0xE1340004, 0x5000);                                 // LOAD SCRATCHA, 4, 0x5000
        ins(0xE05C0004, 0x5010);                                 // STORE SCRATCHB, 4, 0x5010
        ins(0xF1100004, 0x20);                                   // LOAD DSA, 4, DSA-relative +0x20 (DSA = TABLE)
        put32(p, 0xC0000004); put32(p + 4, 0x5000); put32(p + 8, 0x5020); p += 12;   // MEMORY MOVE 4, 0x5000 -> 0x5020
        ins(0x98080000, 0x77);
        put32(TABLE + 0x20, 0x00A0B0C0);
        wl(SCRATCHB, 0x11223344);
        wl(DSA, TABLE);
        wl(DSP, SCRIPT);
        uint8_t i = wait_int();
        uint8_t ds = rb(DSTAT);
        CHECK((i & 1) && (ds & 4) && rl(DSPS) == 0x77, "register program istat %02X dstat %02X dsps %X", i, ds, rl(DSPS));
        CHECK(rl(SCRATCHA) == 0xCAFEF00D, "LOAD SCRATCHA %08X", rl(SCRATCHA));
        CHECK(get32(0x5010) == 0x11223344, "STORE SCRATCHB %08X", get32(0x5010));
        CHECK(rl(DSA) == 0x00A0B0C0, "LOAD DSA-relative %08X", rl(DSA));
        CHECK(get32(0x5020) == 0xCAFEF00D, "MEMORY MOVE %08X", get32(0x5020));
        // the register operators and SFBR (the first program's LOAD overwrote SCRATCHA)
        p = SCRIPT;
        ins(0x78080000 | 0x40 << 8, 0);                          // MOVE 0x40 TO SFBR
        ins(0x7A080000 | 0x05 << 8, 0);                          // MOVE SFBR | 0x05 TO SFBR (0x45)
        ins(0x6A350000, 0);                                      // MOVE SFBR | 0 TO SCRATCHA1
        ins(0x7E350000 | 0xFF << 8, 0);                          // MOVE SCRATCHA1 + 0xFF TO SCRATCHA1 (0x44, carry)
        ins(0x98080000, 0x78);
        wl(SCRATCHA, 0);
        wl(DSP, SCRIPT);
        wait_int(); rb(DSTAT);
        CHECK(rl(SCRATCHA) == 0x00004400 && rb(SFBR) == 0x45, "register ops SCRATCHA %08X SFBR %02X", rl(SCRATCHA), rb(SFBR));
        // memory move from memory into our own registers through BAR1
        put32(0x5030, 0x0BADBEEF);
        p = SCRIPT;
        put32(p, 0xC0000004); put32(p + 4, 0x5030); put32(p + 8, MEMBASE + SCRATCHA); p += 12;
        ins(0x98080000, 0x79);
        wl(DSP, SCRIPT);
        wait_int(); rb(DSTAT);
        CHECK(rl(SCRATCHA) == 0x0BADBEEF, "memory move to own registers %08X", rl(SCRATCHA));
        // single step: SSI after each instruction, STD goes on
        p = SCRIPT;
        ins(0x78340000 | 0x01 << 8, 0);
        ins(0x78340000 | 0x02 << 8, 0);
        ins(0x98080000, 0x7A);
        wb(DIEN, 0x0C);
        wb(DCNTL, 0x19);                                         // SSM
        wl(DSP, SCRIPT);
        int steps = 0;
        for (;;) {
            wait_int();
            uint8_t d = rb(DSTAT);
            if (d & 4) break;
            CHECK(d & 8, "SSI expected, DSTAT %02X", d);
            steps++;
            if (steps > 5) break;
            wb(DCNTL, 0x1D);                                     // STD
        }
        CHECK(steps == 2 && rb(SCRATCHA) == 2, "single step: %d steps, SCRATCHA0 %02X", steps, rb(SCRATCHA));
        wb(DCNTL, 0x09); wb(DIEN, 0x04);
        printf("register ops, LOAD/STORE, memory moves, single step: %s\n", fails ? "see failures" : "ok");
    }

    // ---- the CD-ROM at ID 4: 2048-byte blocks, then 512 after MODE SELECT (as SRM sets)
    r = run_cmd(4, {0x12, 0, 0, 0, 36, 0}, P_DIN, 36, &sts, &msg);
    CHECK(r == 0x600D && mem[DATA] == 0x05 && mem[DATA + 1] == 0x80, "CD INQUIRY %02X %02X", mem[DATA], mem[DATA + 1]);
    r = run_cmd(4, {0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 8, &sts, &msg);
    CHECK(r == 0x600D && get32(DATA) == 0x07000000 && get32(DATA + 4) == 0x00080000,
          "CD READ CAPACITY %08X %08X", get32(DATA), get32(DATA + 4));
    r = run_cmd(4, {0x28, 0, 0, 0, 0, 2, 0, 0, 1, 0}, P_DIN, 2048, &sts, &msg);
    CHECK(r == 0x600D && sts == 0 && !memcmp(mem + DATA, &img[2][2 * 2048], 2048), "CD READ(10) 2048");
    {
        uint8_t ms[12] = {0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 2, 0};   // block descriptor: 512 bytes
        // MODE SELECT's data goes out of DATA: write it there through run_cmd's table
        std::vector<uint8_t> cdb = {0x15, 0x10, 0, 0, 12, 0};
        memcpy(mem + DATA, ms, 12);
        r = run_cmd(4, cdb, P_DOUT, 12, &sts, &msg);
        CHECK(r == 0x600D && sts == 0, "CD MODE SELECT dsps %X status %02X", r, sts);
    }
    r = run_cmd(4, {0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 8, &sts, &msg);
    CHECK(r == 0x600D && get32(DATA) == 0x1F000000 && get32(DATA + 4) == 0x00020000,
          "CD READ CAPACITY after MODE SELECT %08X %08X", get32(DATA), get32(DATA + 4));
    r = run_cmd(4, {0x28, 0, 0, 0, 0, 5, 0, 0, 1, 0}, P_DIN, 512, &sts, &msg);
    CHECK(r == 0x600D && sts == 0 && !memcmp(mem + DATA, &img[2][5 * 512], 512), "CD READ(10) 512");
    printf("CD-ROM dka400: 2048-byte blocks, 512 after MODE SELECT: %s\n", fails ? "see failures" : "ok");

    // ================================================================ the CD's table and audio
    auto run = [&](int id, std::vector<uint8_t> cdb, int ph, uint32_t len) -> uint8_t {
        uint8_t st_ = 0xFF, m_ = 0xFF;
        uint32_t rr = run_cmd(id, cdb, ph, len, &st_, &m_);
        if (rr != 0x600D) { CHECK(false, "command %02X: dsps %X", cdb[0], rr); return 0xFF; }
        return st_;
    };
    auto sense = [&](int id) -> int {      // REQUEST SENSE: key << 8 | ASC
        if (run(id, {0x03, 0, 0, 0, 18, 0}, P_DIN, 18) != 0) return -1;
        return mem[DATA + 2] << 8 | mem[DATA + 12];
    };
    auto pulse_change = [&]() { t->cd_change = 1; tick(); t->cd_change = 0; tick(); };
    auto wait_cyc = [&](int n) { for (int k = 0; k < n; k++) tick(); };
    // block length back to 2048 (the bus reset would also do it)
    {
        uint8_t ms[12] = {0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 8, 0};
        memcpy(mem + DATA, ms, 12);
        CHECK(run(4, {0x15, 0x10, 0, 0, 12, 0}, P_DOUT, 12) == 0, "CD MODE SELECT 2048");
    }

    // ---- no window (a stock Main): the made-up table, one data track on the image (8 sectors)
    CHECK(run(4, {0x43, 0, 0, 0, 0, 0, 0, 0, 20, 0}, P_DIN, 20) == 0, "READ TOC (no window)");
    CHECK(mem[DATA + 1] == 18 && mem[DATA + 2] == 1 && mem[DATA + 3] == 1 && mem[DATA + 5] == 0x14 &&
          mem[DATA + 6] == 1 && mem[DATA + 14] == 0xAA && get32(DATA + 16) == 0x08000000,
          "made-up TOC %02X %02X %02X / %02X %02X / %02X %08X", mem[DATA + 1], mem[DATA + 2], mem[DATA + 3],
          mem[DATA + 5], mem[DATA + 6], mem[DATA + 14], get32(DATA + 16));
    CHECK(run(4, {0x43, 2, 0, 0, 0, 0, 0, 0, 20, 0}, P_DIN, 20) == 0 &&
          mem[DATA + 17] == 0 && mem[DATA + 18] == 2 && mem[DATA + 19] == 8, "made-up TOC lead-out M:S:F %02X:%02X:%02X",
          mem[DATA + 17], mem[DATA + 18], mem[DATA + 19]);
    printf("CD without Main's window: one data track, lead-out 00:02:08: %s\n", fails ? "see failures" : "ok");

    // ---- a remount (Main with the windows): UNIT ATTENTION once, then the new table
    win_on = true;
    pulse_change();
    CHECK(run(4, {0x12, 0, 0, 0, 36, 0}, P_DIN, 36) == 0, "INQUIRY with UNIT ATTENTION pending");
    CHECK(run(4, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0) == 2, "TUR after a remount: CHECK CONDITION");
    CHECK(sense(4) == 0x0628, "UNIT ATTENTION sense %04X", sense(4));
    CHECK(run(4, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0) == 0, "TUR after the attention");
    pulse_change();
    CHECK(sense(4) == 0x0628, "REQUEST SENSE reports a pending attention");
    CHECK(run(4, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0) == 0, "TUR after REQUEST SENSE took the attention");

    // ---- READ TOC format 0, LBA: tracks 1-3 and the lead-out
    CHECK(run(4, {0x43, 0, 0, 0, 0, 0, 0, 0, 36, 0}, P_DIN, 36) == 0, "READ TOC 0");
    CHECK(mem[DATA] == 0 && mem[DATA + 1] == 34 && mem[DATA + 2] == 1 && mem[DATA + 3] == 3, "TOC header");
    {
        const int trk[4] = {1, 2, 3, 0xAA}, ctl[4] = {0x14, 0x10, 0x10, 0x10}, lb[4] = {0, AUD_T2, AUD_T3, LEADOUT};
        for (int e = 0; e < 4; e++) {
            uint8_t *d = mem + DATA + 4 + 8 * e;
            uint32_t a = (uint32_t)d[4] << 24 | d[5] << 16 | d[6] << 8 | d[7];
            CHECK(d[1] == ctl[e] && d[2] == trk[e] && a == (uint32_t)lb[e], "TOC entry %d: %02X %02X %u", e, d[1], d[2], a);
        }
    }
    // format 0, M:S:F, from track 2
    CHECK(run(4, {0x43, 2, 0, 0, 0, 0, 2, 0, 28, 0}, P_DIN, 28) == 0, "READ TOC 0 MSF from track 2");
    CHECK(mem[DATA + 1] == 26 && mem[DATA + 6] == 2 && mem[DATA + 9] == 0 && mem[DATA + 10] == 2 && mem[DATA + 11] == 8 &&
          mem[DATA + 14] == 3 && mem[DATA + 19] == 12 && mem[DATA + 22] == 0xAA && mem[DATA + 27] == 16,
          "TOC MSF %02X %02X %02X:%02X:%02X %02X %02X %02X", mem[DATA + 1], mem[DATA + 6], mem[DATA + 9], mem[DATA + 10],
          mem[DATA + 11], mem[DATA + 14], mem[DATA + 22], mem[DATA + 27]);
    CHECK(run(4, {0x43, 0, 0, 0, 0, 0, 4, 0, 12, 0}, P_DIN, 0) == 2 && sense(4) == 0x0524, "READ TOC past the last track");
    // format 1: the last session's first track (3 at LBA 12), 2 sessions; also through byte 9's SCSI-2 bits
    for (int form = 0; form < 2; form++) {
        std::vector<uint8_t> c = {0x43, 0, (uint8_t)(form ? 0 : 1), 0, 0, 0, 0, 0, 12, (uint8_t)(form ? 0x40 : 0)};
        CHECK(run(4, c, P_DIN, 12) == 0, "READ TOC 1");
        CHECK(mem[DATA + 1] == 10 && mem[DATA + 2] == 1 && mem[DATA + 3] == 2 && mem[DATA + 5] == 0x10 &&
              mem[DATA + 6] == 3 && get32(DATA + 8) == 0x0C000000, "TOC session %02X %02X %02X %02X %08X",
              mem[DATA + 1], mem[DATA + 3], mem[DATA + 5], mem[DATA + 6], get32(DATA + 8));
    }
    // format 2: A0 A1 A2 and the three tracks, 11 bytes each
    CHECK(run(4, {0x43, 2, 2, 0, 0, 0, 0, 0, 70, 0}, P_DIN, 70) == 0, "READ TOC 2");
    {
        uint8_t *d = mem + DATA + 4;
        CHECK(mem[DATA + 1] == 68 && mem[DATA + 2] == 1 && mem[DATA + 3] == 1, "full TOC header %02X", mem[DATA + 1]);
        CHECK(d[3] == 0xA0 && d[8] == 1 && d[1] == 0x14, "A0 %02X %02X %02X", d[3], d[8], d[1]);
        CHECK(d[11 + 3] == 0xA1 && d[11 + 8] == 3, "A1 %02X %02X", d[11 + 3], d[11 + 8]);
        CHECK(d[22 + 3] == 0xA2 && d[22 + 8] == 0 && d[22 + 9] == 2 && d[22 + 10] == 16, "A2 %02X %02X:%02X:%02X",
              d[22 + 3], d[22 + 8], d[22 + 9], d[22 + 10]);
        CHECK(d[33 + 0] == 1 && d[33 + 3] == 1 && d[44 + 3] == 2 && d[44 + 10] == 8 && d[55 + 3] == 3 && d[55 + 10] == 12,
              "full TOC tracks %02X %02X %02X %02X %02X", d[33 + 3], d[44 + 3], d[44 + 10], d[55 + 3], d[55 + 10]);
    }
    printf("READ TOC formats 0 (LBA, M:S:F, start track), 1, 2: %s\n", fails ? "see failures" : "ok");

    // ---- PLAY AUDIO MSF track 2 (00:02:08 to 00:02:12): every sample, in order, unity volume
    auto check_play = [&](int f0, int f1, int vol_l, int vol_r, int mode, const char *what) {
        // mode 0: L/R as recorded, 1: port 0 = right, port 1 = left
        int first = -1;
        for (size_t k = 0; k < cap.size(); k++) if (cap[k].first || cap[k].second) { first = (int)k; break; }
        int n = (f1 - f0) * 588, bad = 0;
        CHECK(first >= 0 && cap.size() >= (size_t)(first + n), "%s: %zu samples, first %d", what, cap.size(), first);
        if (first < 0 || cap.size() < (size_t)(first + n)) return;
        for (int j = 0; j < n && bad < 4; j++) {
            int f = f0 + j / 588, k = j % 588;
            int l = mode ? smp_r(f, k) : smp_l(f, k), r = mode ? smp_l(f, k) : smp_r(f, k);
            int el = (int)(((int64_t)l * (vol_l + (vol_l >> 7))) >> 8), er = (int)(((int64_t)r * (vol_r + (vol_r >> 7))) >> 8);
            if (cap[first + j].first != el || cap[first + j].second != er) {
                bad++;
                CHECK(false, "%s: sample %d (frame %d, %d) %d %d, expected %d %d", what, j, f, k,
                      cap[first + j].first, cap[first + j].second, el, er);
            }
        }
        for (size_t j = first + n; j < cap.size() && bad < 4; j++)
            if (cap[j].first || cap[j].second) { bad++; CHECK(false, "%s: sound after the end (%zu)", what, j - first); }
    };
    cap.clear(); cap_on = true; stb_count = 0;
    CHECK(run(4, {0x47, 0, 0, 0, 2, 8, 0, 2, 12, 0}, P_DIN, 0) == 0, "PLAY AUDIO MSF");
    wait_cyc(3000);
    CHECK(run(4, {0x42, 2, 0x40, 1, 0, 0, 0, 0, 16, 0}, P_DIN, 16) == 0, "READ SUB-CHANNEL");
    CHECK(mem[DATA + 1] == 0x11 && mem[DATA + 3] == 12 && mem[DATA + 4] == 1 && mem[DATA + 5] == 0x10 &&
          mem[DATA + 6] == 2 && mem[DATA + 9] == 0 && mem[DATA + 10] == 2 && mem[DATA + 11] >= 8 && mem[DATA + 11] < 12,
          "sub-channel playing: %02X track %02X %02X:%02X:%02X", mem[DATA + 1], mem[DATA + 6], mem[DATA + 9],
          mem[DATA + 10], mem[DATA + 11]);
    wait_cyc(4 * 5880 + 4000);
    cap_on = false;
    check_play(AUD_T2, AUD_T3, 255, 255, 0, "PLAY MSF");
    CHECK(stb_count > 4 * 588 && stb_count < 4 * 588 + 1200, "the strobe rate: %d strobes", stb_count);
    CHECK(run(4, {0x42, 0, 0x40, 1, 0, 0, 0, 0, 16, 0}, P_DIN, 16) == 0 && mem[DATA + 1] == 0x13, "completed %02X", mem[DATA + 1]);
    CHECK(run(4, {0x42, 0, 0x40, 1, 0, 0, 0, 0, 16, 0}, P_DIN, 16) == 0 && mem[DATA + 1] == 0x15, "then none %02X", mem[DATA + 1]);
    CHECK(run(4, {0x42, 0, 0x00, 1, 0, 0, 0, 0, 4, 0}, P_DIN, 4) == 0 && mem[DATA + 3] == 0, "SUB-CHANNEL without SubQ");
    CHECK(run(4, {0x42, 0, 0x40, 2, 0, 0, 0, 0, 24, 0}, P_DIN, 24) == 0 && mem[DATA + 3] == 20 && mem[DATA + 4] == 2 &&
          mem[DATA + 8] == 0, "SUB-CHANNEL UPC");
    CHECK(run(4, {0x4B, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 0) == 2 && sense(4) == 0x052C, "PAUSE with no play");
    printf("PLAY AUDIO MSF: %d samples checked, READ SUB-CHANNEL, completion: %s\n", 4 * 588, fails ? "see failures" : "ok");

    // ---- MODE SELECT page 0E: port 0 = channel 1 (right) at 128, port 1 = channel 0 (left) at 255;
    // then PLAY TRACK/INDEX 3 with a PAUSE and RESUME in the middle
    {
        uint8_t ms[20] = {0, 0, 0, 0, 0x0E, 14, 0x04, 0, 0, 0, 0, 0, 0x02, 128, 0x01, 255, 0, 0, 0, 0};
        memcpy(mem + DATA, ms, 20);
        CHECK(run(4, {0x15, 0x10, 0, 0, 20, 0}, P_DOUT, 20) == 0, "MODE SELECT page 0E");
        CHECK(run(4, {0x1A, 0x08, 0x0E, 0, 255, 0}, P_DIN, 20) == 0, "MODE SENSE page 0E (DBD)");
        CHECK(mem[DATA] == 19 && mem[DATA + 3] == 0 && mem[DATA + 4] == 0x0E && mem[DATA + 5] == 14 &&
              mem[DATA + 12] == 2 && mem[DATA + 13] == 128 && mem[DATA + 14] == 1 && mem[DATA + 15] == 255,
              "page 0E read back %02X %02X %02X %02X %02X %02X", mem[DATA], mem[DATA + 4], mem[DATA + 12], mem[DATA + 13],
              mem[DATA + 14], mem[DATA + 15]);
        CHECK(run(4, {0x1A, 0x08, 0x4E, 0, 255, 0}, P_DIN, 20) == 0 && mem[DATA + 12] == 0x0F && mem[DATA + 13] == 0xFF &&
              mem[DATA + 6] == 0, "page 0E changeable");
    }
    cap.clear(); cap_on = true;
    CHECK(run(4, {0x48, 0, 0, 0, 3, 1, 0, 3, 1, 0}, P_DIN, 0) == 0, "PLAY AUDIO TRACK/INDEX 3");
    wait_cyc(3000);
    CHECK(run(4, {0x4B, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 0) == 0, "PAUSE");
    CHECK(run(4, {0x42, 0, 0x40, 1, 0, 0, 0, 0, 16, 0}, P_DIN, 16) == 0 && mem[DATA + 1] == 0x12 && mem[DATA + 6] == 3,
          "paused %02X track %02X", mem[DATA + 1], mem[DATA + 6]);
    size_t at_pause = cap.size();
    wait_cyc(5000);
    {
        bool quiet = true;
        for (size_t k = at_pause + 2; k < cap.size(); k++) if (cap[k].first || cap[k].second) quiet = false;
        CHECK(quiet, "sound while paused");
    }
    CHECK(run(4, {0x4B, 0, 0, 0, 0, 0, 0, 0, 1, 0}, P_DIN, 0) == 0, "RESUME");
    wait_cyc(4 * 5880 + 6000);
    cap_on = false;
    {   // the paused stretch removed (zeros between two nonzero samples), the rest is track 3 in order
        std::vector<std::pair<int16_t, int16_t>> c2;
        for (auto &x : cap) if (x.first || x.second) c2.push_back(x);
        cap.swap(c2);
    }
    check_play(AUD_T3, LEADOUT, 128, 255, 1, "PLAY TRACK/INDEX");
    // STOP during a play
    CHECK(run(4, {0x48, 0, 0, 0, 2, 1, 0, 3, 1, 0}, P_DIN, 0) == 0, "PLAY TRACK/INDEX 2-3");
    wait_cyc(2000);
    CHECK(run(4, {0x4E, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 0) == 0, "STOP PLAY");
    CHECK(run(4, {0x42, 0, 0x40, 1, 0, 0, 0, 0, 16, 0}, P_DIN, 16) == 0 && mem[DATA + 1] == 0x15, "stopped %02X", mem[DATA + 1]);
    CHECK(run(4, {0x45, 0, 0, 0, 0, 40, 0, 0, 1, 0}, P_DIN, 0) == 2 && sense(4) == 0x0521, "PLAY past the lead-out");
    printf("page 0E volume and channels, PLAY TRACK/INDEX, PAUSE/RESUME, STOP: %s\n", fails ? "see failures" : "ok");

    // ---- READ CD (user data), MODE SENSE all pages on the CD
    memset(mem + DATA, 0, 4096);
    {
        uint8_t st_ = run(4, {0xBE, 0, 0, 0, 0, 3, 0, 0, 2, 0x10, 0, 0}, P_DIN, 4096);
        int diff = -1;
        for (int k = 0; k < 4096; k++) if (mem[DATA + k] != img[2][3 * 2048 + k]) { diff = k; break; }
        CHECK(st_ == 0 && diff < 0, "READ CD 2 sectors: status %02X, first difference at %d", st_, diff);
    }
    CHECK(run(4, {0x1A, 0, 0x3F, 0, 255, 0}, P_DIN, 64) == 0 && mem[DATA] == 63 && mem[DATA + 2] == 0x80 &&
          mem[DATA + 12] == 0x01 && mem[DATA + 24] == 0x02 && mem[DATA + 40] == 0x0D && mem[DATA + 48] == 0x0E &&
          mem[DATA + 9 + 1] == 0x08, "CD MODE SENSE 3F %02X %02X %02X %02X %02X", mem[DATA], mem[DATA + 12], mem[DATA + 24],
          mem[DATA + 40], mem[DATA + 48]);
    CHECK(run(4, {0x1A, 0, 0x04, 0, 255, 0}, P_DIN, 0) == 2 && sense(4) == 0x0524, "CD has no page 4");
    // ---- no disc: NOT READY, MEDIUM NOT PRESENT; INQUIRY still answers
    t->img_present = 0b001;
    pulse_change();
    CHECK(run(4, {0x12, 0, 0, 0, 36, 0}, P_DIN, 36) == 0 && mem[DATA] == 5, "INQUIRY with no disc");
    CHECK(run(4, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0) == 2 && sense(4) == 0x0628, "attention at the eject");
    CHECK(run(4, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0) == 2 && sense(4) == 0x023A, "TUR with no disc");
    CHECK(run(4, {0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 0) == 2 && sense(4) == 0x023A, "READ CAPACITY with no disc");
    t->img_present = 0b101;
    pulse_change();
    CHECK(run(4, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0) == 2 && run(4, {0x00, 0, 0, 0, 0, 0}, P_DIN, 0) == 0, "disc back");
    printf("READ CD, CD mode pages, NOT READY without a disc: %s\n", fails ? "see failures" : "ok");

    // ================================================================ the disks' commands
    memset(mem + DATA, 0, 4096);
    CHECK(run(0, {0xA8, 0, 0, 0, 0, 20, 0, 0, 0, 5, 0, 0}, P_DIN, 2560) == 0 && !memcmp(mem + DATA, &img[0][20 * 512], 2560),
          "READ(12) 5 blocks");
    for (int k = 0; k < 2560; k++) mem[DATA + k] = (uint8_t)(k * 13 + 1);
    CHECK(run(0, {0xAA, 0, 0, 0, 0, 30, 0, 0, 0, 5, 0, 0}, P_DOUT, 2560) == 0 && !memcmp(&img[0][30 * 512], mem + DATA, 2560),
          "WRITE(12) 5 blocks");
    for (int k = 0; k < 1024; k++) mem[DATA + k] = (uint8_t)(k * 5 + 3);
    CHECK(run(0, {0x0A, 0, 0, 40, 2, 0}, P_DOUT, 1024) == 0 && !memcmp(&img[0][40 * 512], mem + DATA, 1024), "WRITE(6)");
    CHECK(run(0, {0x08, 0, 0, 40, 2, 0}, P_DIN, 1024) == 0 && !memcmp(&img[0][40 * 512], mem + DATA, 1024), "READ(6)");
    CHECK(run(0, {0x28, 0, 0, 0, 0, 63, 0, 0, 2, 0}, P_DIN, 0) == 2 && sense(0) == 0x0521, "READ past the end");
    CHECK(run(0, {0x1A, 0, 0x3F, 0, 255, 0}, P_DIN, 112) == 0 && mem[DATA] == 111 && mem[DATA + 3] == 8 &&
          mem[DATA + 12] == 0x01 && mem[DATA + 24] == 0x02 && mem[DATA + 40] == 0x03 && mem[DATA + 64] == 0x04 &&
          mem[DATA + 88] == 0x08 && mem[DATA + 100] == 0x0A && mem[DATA + 40 + 11] == 64 && mem[DATA + 64 + 5] == 16,
          "disk MODE SENSE 3F %02X %02X %02X %02X %02X %02X %02X", mem[DATA], mem[DATA + 12], mem[DATA + 24], mem[DATA + 40],
          mem[DATA + 64], mem[DATA + 88], mem[DATA + 100]);
    CHECK(run(0, {0x5A, 0x08, 0x08, 0, 0, 0, 0, 0, 255, 0}, P_DIN, 20) == 0 && mem[DATA + 1] == 18 && mem[DATA + 7] == 0 &&
          mem[DATA + 8] == 0x08 && mem[DATA + 9] == 10, "MODE SENSE(10) page 8 DBD %02X %02X", mem[DATA + 1], mem[DATA + 8]);
    {
        uint8_t fl[12] = {0, 0x02, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8};
        memcpy(mem + DATA, fl, 12);
        CHECK(run(0, {0x04, 0x18, 0, 0, 0, 0}, P_DOUT, 12) == 0, "FORMAT UNIT with a defect list");
    }
    CHECK(run(0, {0x04, 0, 0, 0, 0, 0}, P_DIN, 0) == 0, "FORMAT UNIT");
    CHECK(run(0, {0x37, 0, 0x1C, 0, 0, 0, 0, 0, 4, 0}, P_DIN, 4) == 0 && mem[DATA + 1] == 0x1C && mem[DATA + 3] == 0,
          "READ DEFECT DATA");
    CHECK(run(0, {0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0}, P_DIN, 0) == 0, "SYNCHRONIZE CACHE");
    CHECK(run(0, {0x2F, 0, 0, 0, 0, 0, 0, 0, 8, 0}, P_DIN, 0) == 0, "VERIFY");
    CHECK(run(0, {0x1B, 0, 0, 0, 1, 0}, P_DIN, 0) == 0, "START STOP UNIT");
    CHECK(run(0, {0x43, 0, 0, 0, 0, 0, 0, 0, 12, 0}, P_DIN, 0) == 2 && sense(0) == 0x0520, "READ TOC on a disk");
    CHECK(run(0, {0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0}, P_DIN, 0) == 2 && sense(0) == 0x0520,
          "a 16-byte CDB is taken whole");
    printf("disks: READ/WRITE(6/12), mode pages, DBD, FORMAT UNIT, READ DEFECT DATA: %s\n", fails ? "see failures" : "ok");

    printf("%s: %d failure(s), %llu cycles\n", fails ? "FAIL" : "PASS", fails, (unsigned long long)cyc);
    delete t;
    return fails ? 1 : 0;
}
