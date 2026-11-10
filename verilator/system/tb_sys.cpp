// System simulation: rtl/as200_sys.v (the 21064 core loading our SROM, the
// 21071 model, COM1) with C++ models of the DRAM and the flashbus ROMs.
//
//   obj_sys/Vas200_sys --flash FLASH.bin --drom DROM.bin [options]
//     --mem N          OSD Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB
//     --cycles N       stop after N cycles (default 200M = 2 s at 100 MHz)
//     --until-led XX   stop when the LEDs show XX (hex)
//     --trace FILE     retire trace (alphaemu -T format)
//     --trace-from N   start the trace at retired instruction N
//     --trace-pc LO HI only retires with LO <= PC < HI
//     --jumpers XX     flashbus jumper byte (default 03: J1, J2 normal)
//     --save-at N      at cycle N write a checkpoint (FILE.v: the RTL; FILE.mem: DRAM,
//                      flashbus, the cycle and instruction counts) to --ckpt FILE
//     --save-led XX    write the checkpoint when the LEDs first show XX
//     --restore FILE   start from a checkpoint instead of reset
//     --disk0 / --disk1 / --cd FILE   SCSI images (IDs 0, 1, 4), read/write in memory
//                      (the CD is a flat file of 2048-byte sectors served as 512-byte blocks)
//     --type STR       type STR into COM1 (\n = Return), one character every
//                      2 ms of machine time, starting --type-at cycles in
//                      (default: at once); more --type options queue up
//     --arc            the OSD Console = ARC (overrides TOY CMOS 3Fh; default: SRM)
//     --flash-wp       J6 flash write disabled (the flashROMs ignore writes)
//     --nvram FILE     load the 8 KB flashbus NVRAM (the board's AS200.nvr) at the start
//     --cd-ua          pulse cd_change at the start (the CD's Unit Attention, as after the board's mount)
//     --key also takes {wN}: a pause of N x 100 ms
//     --save-every N   a checkpoint every N cycles (the same --ckpt file)
//     --key STR        type STR on the PS/2 keyboard (into the 8242): ASCII, \n = Enter,
//                      {up} {down} {left} {right} {esc} {f1}..{f12} {tab} {bs};
//                      one key every 20 ms of machine time from --key-at cycles
//     --ccstep N       after --restore: CC advances N a cycle from here on (1 = the board's timing)
//     --disk-lat N     every block request waits N cycles before the transfer (Main and the SD card)
//     --vram-every N   every N cycles write the TGA's 2 MB VRAM to --vram FILE
//                      (default ../scratch/vram.bin; tools/vram2png.py shows it)
//
// Prints every LED change (with the TI Table 8-1 meaning of the SROM codes),
// the SROM serial port's output (the DROM's console: SL_XMIT decoded as a
// 19200-baud line, the DROM's own timing at 100 MHz) and COM1's output.
#include "Vas200_sys.h"
#include "Vas200_sys___024root.h"
#include "verilated.h"
#include "verilated_save.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cinttypes>
#include <vector>
#include <string>
#include <ctime>

static const char *led_name(int v) {
    switch (v) {
    case 0xFF: return "SROM: CPU initialised";
    case 0xFE: return "SROM: memory sizing";
    case 0xFD: return "SROM: banks configured";
    case 0xFC: return "SROM: Bcache";
    case 0xFB: return "SROM: memory test 1 (caches off)";
    case 0xFA: return "SROM: memory test 2 (Bcache on)";
    case 0xF9: return "SROM: memory test 3 (D-cache on)";
    case 0xF8: return "SROM: memory test 4 (both on)";
    case 0xF7: return "SROM: memory tests done";
    case 0xF6: return "SROM: core logic initialised";
    case 0xF5: return "SROM: unexpected exception (ours)";
    case 0xF3: return "SROM: copying the DROM";
    case 0xF2: return "SROM: DROM header/checksum bad";
    case 0xF1: return "SROM: DROM good";
    case 0xF0: return "SROM: entering the DROM";
    default:   return "";
    }
}

static bool load(const char *path, std::vector<uint8_t> &mem, size_t off, size_t max) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return false; }
    size_t n = fread(&mem[off], 1, max, f);
    fclose(f);
    fprintf(stderr, "loaded %s: %zu bytes at flashbus %#zx\n", path, n, off);
    return true;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    setvbuf(stdout, nullptr, _IOLBF, 0);   // the logs are read while the run goes on
    const char *flash = nullptr, *drom = nullptr, *trace = nullptr;
    uint64_t cycles = 200000000, trace_from = 0, trace_lo = 0, trace_hi = ~0ull;
    int mem = 0, until_led = -1, jumpers = 0x03, save_led = -1;
    uint64_t save_at = 0;
    int ccstep = 0;
    uint64_t disk_lat = 0, disk_wait = 0;
    std::string ckpt = "../scratch/sys.ckpt", restore, typed;
    uint64_t type_at = 0, key_at = 0, vram_every = 0;
    bool arc = false, flash_wp = false, cd_ua = false;
    uint64_t save_every = 0;
    std::string keys, vram_file = "../scratch/vram.bin", nvram_file;
    std::vector<uint8_t> img[3];
    bool img_on[3] = {false, false, false};
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() { if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(2); } return argv[++i]; };
        if (a == "--flash") flash = next();
        else if (a == "--drom") drom = next();
        else if (a == "--mem") mem = atoi(next());
        else if (a == "--cycles") cycles = strtoull(next(), 0, 0);
        else if (a == "--until-led") until_led = strtol(next(), 0, 16);
        else if (a == "--trace") trace = next();
        else if (a == "--trace-from") trace_from = strtoull(next(), 0, 0);
        else if (a == "--trace-pc") { trace_lo = strtoull(next(), 0, 0); trace_hi = strtoull(next(), 0, 0); }
        else if (a == "--jumpers") jumpers = strtol(next(), 0, 16);
        else if (a == "--save-at") save_at = strtoull(next(), 0, 0);
        else if (a == "--save-led") save_led = strtol(next(), 0, 16);
        else if (a == "--ckpt") ckpt = next();
        else if (a == "--restore") restore = next();
        else if (a == "--type") {
            std::string v = next();
            for (size_t k = 0; k < v.size(); k++) {
                if (v[k] == '\\' && k + 1 < v.size() && v[k + 1] == 'n') { typed += '\r'; k++; }
                else typed += v[k];
            }
        }
        else if (a == "--type-at") type_at = strtoull(next(), 0, 0);
        else if (a == "--arc") arc = true;
        else if (a == "--flash-wp") flash_wp = true;
        else if (a == "--cd-ua") cd_ua = true;
        else if (a == "--nvram") nvram_file = next();
        else if (a == "--save-every") save_every = strtoull(next(), 0, 0);
        else if (a == "--ccstep") ccstep = atoi(next());
        else if (a == "--disk-lat") disk_lat = strtoull(next(), 0, 0);
        else if (a == "--key") keys += next();
        else if (a == "--key-at") key_at = strtoull(next(), 0, 0);
        else if (a == "--vram-every") vram_every = strtoull(next(), 0, 0);
        else if (a == "--vram") vram_file = next();
        else if (a == "--disk0" || a == "--disk1" || a == "--cd") {
            int sl = a == "--disk0" ? 0 : a == "--disk1" ? 1 : 2;
            const char *fn = next();
            FILE *f = fopen(fn, "rb");
            if (!f) { perror(fn); return 2; }
            fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
            img[sl].resize(sz);
            if (fread(img[sl].data(), 1, sz, f) != (size_t)sz) { fprintf(stderr, "short read %s\n", fn); return 2; }
            fclose(f); img_on[sl] = true;
            fprintf(stderr, "SCSI slot %d: %s, %ld bytes\n", sl, fn, sz);
        }
        else if (a[0] == '+') ;
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
    }

    std::vector<uint8_t> dram(128u << 20, 0);
    std::vector<uint8_t> fb(2u << 20, 0xFF);       // flashbus offsets 0..1F.FFFF
    std::vector<uint64_t> vram(1u << 18, 0);       // the TGA's 2 MB (DDR3 on the board)
    if (flash && !load(flash, fb, 0, 1u << 20)) return 2;
    if (drom && !load(drom, fb, 0x180000, 0x10000)) return 2;
    FILE *tf = trace ? fopen(trace, "w") : nullptr;

    Vas200_sys *t = new Vas200_sys;
    t->cfg_mem = mem;
    t->jumpers = jumpers;
    t->com1_rxd = 1;
    t->com2_rxd = 1;
    t->srom_rxd = 1;
    {
        uint8_t pres = 0;
        for (int sl = 0; sl < 3; sl++) if (img_on[sl]) {
            pres |= 1 << sl;
            uint32_t blocks = (uint32_t)(img[sl].size() / 512);
            t->img_blocks[sl] = blocks;
        }
        t->img_present = pres;
    }
    t->sd_ack = 0; t->sd_buff_wr = 0; t->cd_change = 0;
    t->nvb_addr = 0; t->nvb_we = 0; t->nvb_wdata = 0;
    int sd_slot = -1, sd_dir = 0, sd_pos = 0, sd_len = 0; uint32_t sd_lba_q = 0;
    t->ps2_key = 0; t->ps2_mouse = 0; t->console_mode = arc ? 2 : 1; t->cm_addr = 0; t->cm_we = 0; t->cm_wdata = 0; t->flash_wp = flash_wp; t->halt = 0;
    t->fd_mounted = 0; t->fd_readonly = 0; t->fd_size = 0; t->fd_ack = 0;
    t->vr_ack = 0; t->vr_rvalid = 0; t->vr_rdata = 0; t->sc_ack = 0; t->sc_rvalid = 0; t->sc_rdata = 0; t->clk_pix = 0;
    t->enet_mac = 0x08002BA50200ull; t->enet_link_up = 1; t->nb_ack = 0; t->nb_rdata = 0; t->year_ovr_en = 0; t->year_ovr = 0;
    {   // the TOY's time from the host clock, in hps_io's RTC layout (BCD:
        // sec, min, hour, day, month, year, weekday; bit 64 toggles on update)
        time_t now = time(nullptr); struct tm *tm = localtime(&now);
        auto bcd = [](int v) { return (uint64_t)(((v / 10) << 4) | (v % 10)); };
        uint64_t r = bcd(tm->tm_sec) | bcd(tm->tm_min) << 8 | bcd(tm->tm_hour) << 16 | bcd(tm->tm_mday) << 24 |
                     bcd(tm->tm_mon + 1) << 32 | bcd(tm->tm_year % 100) << 40 | bcd(tm->tm_wday + 1) << 48;
        t->rtc[0] = (uint32_t)r; t->rtc[1] = (uint32_t)(r >> 32); t->rtc[2] = 1;
    }
    // SROM port decoder: 8N1 at 19200 baud = 5208.33 cycles a bit
    const double SBIT = 100e6 / 19200.0;
    int s_last = 1, s_nbit = -1; double s_t0 = 0; int s_byte = 0;
    std::string sline;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    uint64_t cyc = 0, retired = 0;
    if (restore.empty()) {
        t->rst = 1; for (int i = 0; i < 8; i++) tick(); t->rst = 0;
    } else {
        VerilatedRestore rs; rs.open((restore + ".v").c_str()); rs >> *t; rs.close();
        FILE *f = fopen((restore + ".mem").c_str(), "rb");
        if (!f || fread(&cyc, 8, 1, f) != 1 || fread(&retired, 8, 1, f) != 1 ||
            fread(dram.data(), 1, dram.size(), f) != dram.size() || fread(fb.data(), 1, fb.size(), f) != fb.size() ||
            fread(vram.data(), 8, vram.size(), f) != vram.size()) {
            fprintf(stderr, "cannot restore %s\n", restore.c_str()); return 2;
        }
        fclose(f);
        cycles += cyc;
        if (ccstep) t->rootp->as200_sys__DOT__cpu__DOT__cc_step = ccstep;
        fprintf(stderr, "restored %s at cycle %" PRIu64 ", %" PRIu64 " instructions\n", restore.c_str(), cyc, retired);
    }
    auto save = [&]() {
        VerilatedSave os; os.open((ckpt + ".v").c_str()); os << *t; os.close();
        FILE *f = fopen((ckpt + ".mem").c_str(), "wb");
        fwrite(&cyc, 8, 1, f); fwrite(&retired, 8, 1, f);
        fwrite(dram.data(), 1, dram.size(), f); fwrite(fb.data(), 1, fb.size(), f);
        fwrite(vram.data(), 8, vram.size(), f); fclose(f);
        fprintf(stderr, "checkpoint %s at cycle %" PRIu64 ", %" PRIu64 " instructions\n", ckpt.c_str(), cyc, retired);
    };
    // the PS/2 key list: {code, extended} presses (a release follows each)
    std::vector<std::pair<int,int>> kseq;
    {
        static const char *lc = "abcdefghijklmnopqrstuvwxyz";
        static const int lcode[26] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,
                                      0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A};
        static const int dcode[10] = {0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46};
        static const int fcode[12] = {0x05,0x06,0x04,0x0C,0x03,0x0B,0x83,0x0A,0x01,0x09,0x78,0x07};
        for (size_t k = 0; k < keys.size(); k++) {
            char c = keys[k];
            if (c == '{') {
                size_t e = keys.find('}', k); std::string n = keys.substr(k + 1, e - k - 1); k = e;
                if (n == "up") kseq.push_back({0x75, 1}); else if (n == "down") kseq.push_back({0x72, 1});
                else if (n == "left") kseq.push_back({0x6B, 1}); else if (n == "right") kseq.push_back({0x74, 1});
                else if (n == "esc") kseq.push_back({0x76, 0}); else if (n == "tab") kseq.push_back({0x0D, 0});
                else if (n == "bs") kseq.push_back({0x66, 0}); else if (n == "enter") kseq.push_back({0x5A, 0});
                else if (n[0] == 'w') kseq.push_back({-atoi(n.c_str() + 1), 0});      // {wN}: wait N x 100 ms
                else if (n[0] == 'f') kseq.push_back({fcode[atoi(n.c_str() + 1) - 1], 0});
            } else if (c == '\\' && k + 1 < keys.size() && keys[k + 1] == 'n') { kseq.push_back({0x5A, 0}); k++; }
            else if (c >= 'a' && c <= 'z') kseq.push_back({lcode[c - 'a'], 0});
            else if (c >= 'A' && c <= 'Z') kseq.push_back({lcode[c - 'A'], 0});
            else if (c >= '0' && c <= '9') kseq.push_back({dcode[c - '0'], 0});
            else if (c == ' ') kseq.push_back({0x29, 0});
            else if (c == '\\') kseq.push_back({0x5D, 0});
            else if (c == '(') kseq.push_back({0x146, 0});
            else if (c == ')') kseq.push_back({0x145, 0});
            else if (c == ':') kseq.push_back({0x14C, 0});
            else if (c == '_') kseq.push_back({0x14E, 0});
            else if (c == '.') kseq.push_back({0x49, 0});
            else if (c == '-') kseq.push_back({0x4E, 0});
            (void)lc;
        }
    }
    const bool srom_edges = getenv("SROM_EDGES") != nullptr;
    int last_led = -1;
    bool vpend = false; int vr_left = 0; uint32_t vr_ra = 0;
    bool dpend = false, fpend = false;
    std::string line;
    while (cyc < cycles) {
        // DRAM: answer on the cycle after the request appears
        t->d_ack = 0;
        static int dbeat = 0;
        if (t->d_req && !dpend) { dpend = true; dbeat = 0; }
        else if (t->d_req && dpend) {
            uint64_t a = ((uint64_t)t->d_addr << 3) + (t->d_line ? 8 * dbeat : 0), q;
            memcpy(&q, &dram[a], 8);
            if (t->d_we) {
                uint64_t m = 0;
                for (int b = 0; b < 8; b++) if (t->d_be >> b & 1) m |= 0xFFull << (8 * b);
                q = (q & ~m) | (t->d_wdata & m);
                memcpy(&dram[a], &q, 8);
            }
            t->d_rdata = q; t->d_ack = 1;
            if (!t->d_line || ++dbeat == 4) dpend = false;
        }
        // flashbus ROMs
        t->f_ack = 0;
        if (t->f_req && !fpend) fpend = true;
        else if (t->f_req && fpend) {
            uint32_t a = t->f_addr & 0x1FFFFF;
            if (t->f_we) {      // a programmed byte or the erase's FFs (rtl/apecs/flash28f020.v)
                static uint64_t nw = 0;
                if (a < 0x100000) fb[a] = t->f_wdata;
                if (++nw <= 64 || (a & 0x3FFFF) == 0) fprintf(stderr, "[%10" PRIu64 " cyc] flash write %05x = %02x\n", cyc, a, t->f_wdata);
            }
            t->f_rdata = fb[a]; t->f_ack = 1; fpend = false;
        }
        // the TGA's VRAM port (rtl/mister/ddr3_arb.v's handshake): ack the cycle after
        // the request; a read's words follow, one a cycle
        t->vr_ack = 0; t->vr_rvalid = 0; t->sc_ack = 0; t->sc_rvalid = 0;
        if (vr_left) { t->vr_rdata = vram[vr_ra++ & 0x3FFFF]; t->vr_rvalid = 1; vr_left--; }
        else if (t->vr_req && !vpend) vpend = true;
        else if (t->vr_req && vpend) {
            uint32_t a = t->vr_addr & 0x3FFFF;
            if (t->vr_we) {
                uint64_t m = 0;
                for (int b = 0; b < 8; b++) if (t->vr_be >> b & 1) m |= 0xFFull << (8 * b);
                vram[a] = (vram[a] & ~m) | (t->vr_wdata & m);
            } else { vr_ra = a; vr_left = t->vr_len ? t->vr_len : 16; }
            t->vr_ack = 1; vpend = false;
        }
        if (vram_every && cyc && cyc % vram_every == 0) {
            FILE *vf = fopen(vram_file.c_str(), "wb");
            if (vf) { fwrite(vram.data(), 8, vram.size(), vf); fclose(vf); }
            fprintf(stderr, "[%10" PRIu64 " cyc] VRAM written to %s\n", cyc, vram_file.c_str());
        }
        // PS/2 keys: press, then release 10 ms later, then the next key 10 ms on
        {
            static size_t kpos = 0; static uint64_t knext = 0; static int kph = 0;
            if (kpos < kseq.size() && cyc >= key_at && cyc >= knext && kseq[kpos].first < 0) {
                knext = cyc + (uint64_t)(-kseq[kpos].first) * 10000000ull; kpos++;
            } else if (kpos < kseq.size() && cyc >= key_at && cyc >= knext) {
                // phases: 0 shift down (shifted keys), 1 key down, 2 key up, 3 shift up
                int code = kseq[kpos].first & 0xFF, ext = kseq[kpos].second, sh = kseq[kpos].first >> 8;
                if (kph == 0 && !sh) kph = 1;
                uint32_t tog = ((t->ps2_key >> 10) & 1) ^ 1;
                if (kph == 0)      t->ps2_key = tog << 10 | 1u << 9 | 0x12;
                else if (kph == 1) t->ps2_key = tog << 10 | 1u << 9 | ext << 8 | code;
                else if (kph == 2) t->ps2_key = tog << 10 | ext << 8 | code;
                else               t->ps2_key = tog << 10 | 0x12;
                if (kph == 2 && !sh) kph = 4; else kph++;
                if (kph >= 4) { kph = 0; kpos++; fprintf(stderr, "[%10" PRIu64 " cyc] key %02X%s%s\n", cyc, code, ext ? " (E0)" : "", sh ? " (shift)" : ""); }
                knext = cyc + 1000000;
            }
        }
        // --nvram: the 8 KB flashbus NVRAM image through the 21071 model's port B, a byte a cycle
        {
            static std::vector<uint8_t> nv; static int nvi = -1;
            if (nvi < 0) { nvi = 0; if (!nvram_file.empty()) { FILE *nf = fopen(nvram_file.c_str(), "rb");
                if (nf) { nv.resize(8192); size_t got = fread(nv.data(), 1, 8192, nf); fclose(nf); fprintf(stderr, "NVRAM %s: %zu bytes\n", nvram_file.c_str(), got); } } }
            t->nvb_we = 0;
            if (nvi < (int)nv.size()) { t->nvb_addr = nvi; t->nvb_wdata = nv[nvi]; t->nvb_we = 1; nvi++; }
        }
        // --cd-ua: the mount pulse the board's Main gives at core load (the CD's Unit Attention)
        { static int cdp = 0; t->cd_change = (cd_ua && cdp < 4) ? 1 : 0; if (cdp < 4) cdp++; }
        tick();
        cyc++;
        // the hps_io block devices (as in verilator/tb/tb_ncr810.cpp): one byte a cycle
        t->sd_buff_wr = 0;
        if (sd_slot < 0 && !(t->sd_rd | t->sd_wr)) disk_wait = 0;
        else if (sd_slot < 0 && disk_wait < disk_lat) disk_wait++;
        else if (sd_slot < 0) {
            for (int sl = 0; sl < 3; sl++) if ((t->sd_rd | t->sd_wr) & (1 << sl)) {
                disk_wait = 0;
                sd_slot = sl; sd_dir = (t->sd_wr >> sl) & 1; sd_pos = -1;
                sd_len = ((int)((t->sd_blk_cnt >> (6 * sl)) & 63) + 1) * 512;
                sd_lba_q = t->sd_lba[sl];
                t->sd_ack = 1 << sl;
                break;
            }
        } else {
            size_t base = (size_t)sd_lba_q * 512;
            std::vector<uint8_t> &im = img[sd_slot];
            bool toc = sd_lba_q >= 0xC0000000u;          // the CD's track table: none (zeros)
            if (sd_dir == 0) {
                sd_pos++;
                if (sd_pos < sd_len) {
                    t->sd_buff_addr = sd_pos; t->sd_buff_wr = 1;
                    t->sd_buff_dout = (!toc && base + sd_pos < im.size()) ? im[base + sd_pos] : 0;
                } else { t->sd_ack = 0; sd_slot = -1; }
            } else {
                if (sd_pos >= 0 && !toc && base + sd_pos < im.size()) im[base + sd_pos] = t->sd_buff_din;
                sd_pos++;
                if (sd_pos < sd_len) t->sd_buff_addr = sd_pos;
                else { t->sd_ack = 0; sd_slot = -1; }
            }
        }
        // COM1 typing
        t->com1_kbd_stb = 0;
        {
            static size_t tpos = 0; static uint64_t tnext = 0;
            if (tpos < typed.size() && cyc >= type_at && cyc >= tnext) {
                t->com1_kbd_byte = (uint8_t)typed[tpos++]; t->com1_kbd_stb = 1;
                tnext = cyc + 200000;
            }
        }
        if ((save_at && cyc == save_at) || (save_every && cyc % save_every == 0)) save();
        if (t->leds != last_led && (int)t->leds == save_led) { save(); save_led = -1; }
        if (t->leds != last_led) {
            fprintf(stderr, "[%10" PRIu64 " cyc, %9" PRIu64 " insns] LED %02X %s\n", cyc, retired, t->leds, led_name(t->leds));
            last_led = t->leds;
            if (t->leds == until_led) break;
        }
        if (t->com1_tx_stb) { putchar(t->com1_tx_byte); fflush(stdout); }
        // the SROM port
        {
            int v = t->srom_txd;
            static int ntr = 0; static uint64_t lastt = 0;
            if (srom_edges && v != s_last && ntr < 60) { fprintf(stderr, "edge %d->%d after %" PRIu64 "\n", s_last, v, cyc - lastt); lastt = cyc; ntr++; }
            if (s_nbit < 0) {
                if (s_last && !v) { s_nbit = 0; s_t0 = cyc; s_byte = 0; }
            } else {
                double centre = s_t0 + SBIT * (s_nbit + 1.5);
                if (cyc >= centre) {
                    if (s_nbit < 8) { s_byte |= v << s_nbit; s_nbit++; }
                    else {
                        s_nbit = -1;
                        if (s_byte == '\n') { fprintf(stderr, "[%10" PRIu64 " cyc] SROM port: %s\n", cyc, sline.c_str()); sline.clear(); }
                        else if (s_byte >= 0x20 && s_byte < 0x7F) sline += (char)s_byte;
                    }
                }
            }
            s_last = v;
        }
        if (t->dbg_retire) {
            retired++;
            if (tf && retired >= trace_from && (uint64_t)t->dbg_pc >= trace_lo && (uint64_t)t->dbg_pc < trace_hi) {
                fprintf(tf, "%016" PRIx64 " %08x", (uint64_t)t->dbg_pc, t->dbg_insn);
                if (t->dbg_rwr) fprintf(tf, " r%d=%016" PRIx64, t->dbg_rnum, (uint64_t)t->dbg_rval);
                if (t->dbg_mwr) fprintf(tf, " m%016" PRIx64 "=%016" PRIx64 "/%d", (uint64_t)t->dbg_maddr, (uint64_t)t->dbg_mval, t->dbg_msize);
                fputc('\n', tf);
            }
        }
    }
    if (!sline.empty()) fprintf(stderr, "SROM port (partial line): %s\n", sline.c_str());
    fprintf(stderr, "stopped after %" PRIu64 " cycles (%.3f ms at 100 MHz), %" PRIu64 " instructions, last PC %#" PRIx64 ", LED %02X\n",
            cyc, cyc / 1e5, retired, (uint64_t)t->dbg_pc, t->leds);
    if (tf) fclose(tf);
    t->final();
    delete t;
    return 0;
}
