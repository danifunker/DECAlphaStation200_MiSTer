// System simulation: rtl/as200_sys.v (the 21064 core loading our SROM, the
// 21071 model, COM1) with C++ models of the DRAM and the flashbus ROMs.
//
//   obj_sys/Vas200_sys --flash FLASH.bin --drom DROM.bin [options]
//     --mem N          OSD Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB
//     --cycles N       stop after N cycles (default 200M = 2 s at 100 MHz)
//     --until-led XX   stop when the LEDs show XX (hex)
//     --trace FILE     retire trace (alphaemu -T format)
//     --trace-from N   start the trace at retired instruction N
//     --jumpers XX     flashbus jumper byte (default 03: J1, J2 normal)
//
// Prints every LED change (with the TI Table 8-1 meaning of the SROM codes),
// the SROM serial port's output (the DROM's console: SL_XMIT decoded as a
// 19200-baud line, the DROM's own timing at 100 MHz) and COM1's output.
#include "Vas200_sys.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cinttypes>
#include <vector>
#include <string>

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
    const char *flash = nullptr, *drom = nullptr, *trace = nullptr;
    uint64_t cycles = 200000000, trace_from = 0;
    int mem = 0, until_led = -1, jumpers = 0x03;
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
        else if (a == "--jumpers") jumpers = strtol(next(), 0, 16);
        else if (a[0] == '+') ;
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
    }

    std::vector<uint8_t> dram(128u << 20, 0);
    std::vector<uint8_t> fb(2u << 20, 0xFF);       // flashbus offsets 0..1F.FFFF
    if (flash && !load(flash, fb, 0, 1u << 20)) return 2;
    if (drom && !load(drom, fb, 0x180000, 0x10000)) return 2;
    FILE *tf = trace ? fopen(trace, "w") : nullptr;

    Vas200_sys *t = new Vas200_sys;
    t->cfg_mem = mem;
    t->jumpers = jumpers;
    t->com1_rxd = 1;
    t->srom_rxd = 1;
    // SROM port decoder: 8N1 at 19200 baud = 5208.33 cycles a bit
    const double SBIT = 100e6 / 19200.0;
    int s_last = 1, s_nbit = -1; double s_t0 = 0; int s_byte = 0;
    std::string sline;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    t->rst = 1; for (int i = 0; i < 8; i++) tick(); t->rst = 0;

    uint64_t cyc = 0, retired = 0;
    int last_led = -1;
    bool dpend = false, fpend = false;
    std::string line;
    while (cyc < cycles) {
        // DRAM: answer on the cycle after the request appears
        t->d_ack = 0;
        if (t->d_req && !dpend) dpend = true;
        else if (t->d_req && dpend) {
            uint64_t a = (uint64_t)t->d_addr << 3, q;
            memcpy(&q, &dram[a], 8);
            if (t->d_we) {
                uint64_t m = 0;
                for (int b = 0; b < 8; b++) if (t->d_be >> b & 1) m |= 0xFFull << (8 * b);
                q = (q & ~m) | (t->d_wdata & m);
                memcpy(&dram[a], &q, 8);
            }
            t->d_rdata = q; t->d_ack = 1; dpend = false;
        }
        // flashbus ROMs
        t->f_ack = 0;
        if (t->f_req && !fpend) fpend = true;
        else if (t->f_req && fpend) {
            uint32_t a = t->f_addr & 0x1FFFFF;
            if (t->f_we) { /* flash programming: not modelled yet */ }
            t->f_rdata = fb[a]; t->f_ack = 1; fpend = false;
        }
        tick();
        cyc++;
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
            if (getenv("SROM_EDGES") && v != s_last && ntr < 60) { fprintf(stderr, "edge %d->%d after %" PRIu64 "\n", s_last, v, cyc - lastt); lastt = cyc; ntr++; }
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
            if (tf && retired >= trace_from) {
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
