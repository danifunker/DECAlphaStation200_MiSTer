// Headless Verilator run of the AlphaStation 200 machine (verilator/sim_top.v).
//
//   obj_dir/Vsim_top [options]
//     --ms N            stop after N ms of simulated time (default 1000)
//     --until STR       stop as soon as COM1 has printed STR (then run --after ms more)
//     --after N         ms to keep running after --until matched (default 0)
//     --rx STR          once --until matched (or at start), send STR on the RXD line, 9600 8N1
//     --type STR        same, but typed on the MiSTer keyboard path (straight into the FIFO),
//                       after the --rx text
//     --mem N           OSD Memory: 0 = 64 MB, 1 = 32 MB, 2 = 128 MB
//     --screenshot F    write the last complete frame to F (PNG) at the end
//     --stamp           prefix each COM1 line with the simulated time
//
// STR escapes: \r \n \e \\.  COM1's output goes to stdout. The TXD line is
// also decoded here at 9600 8N1 and compared with what the 16550 loaded into
// its shift register; any difference is reported (the exit code is 2).

#include "Vsim_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <deque>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

static std::string unescape(const char *s) {
    std::string o;
    for (; *s; s++) {
        if (*s == '\\' && s[1]) {
            s++;
            switch (*s) {
            case 'r': o += '\r'; break;
            case 'n': o += '\n'; break;
            case 'e': o += '\x1b'; break;
            default:  o += *s; break;
            }
        } else o += *s;
    }
    return o;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    double ms = 1000, after_ms = 0;
    std::string until, rx_text, type_text, shot;
    int mem = 0;
    bool stamp = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> const char * {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs a value\n", a.c_str()); exit(1); }
            return argv[++i];
        };
        if (a == "--ms") ms = atof(next());
        else if (a == "--until") until = unescape(next());
        else if (a == "--after") after_ms = atof(next());
        else if (a == "--rx") rx_text = unescape(next());
        else if (a == "--type") type_text = unescape(next());
        else if (a == "--mem") mem = atoi(next());
        else if (a == "--screenshot") shot = next();
        else if (a == "--stamp") stamp = true;
        else if (a[0] == '+') ;            // Verilator plusargs
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 1; }
    }

    Vsim_top *top = new Vsim_top;
    top->cfg_mem = mem;
    top->uart_rxd = 1;
    top->reset = 1;

    // clocks: 50 MHz system, 65 MHz pixel; time in ps
    const double T_SYS = 20000.0, T_PIX = 1e6 / 65.0;
    double t = 0, n_sys = 0, n_pix = 0, t_end = ms * 1e9;
    uint64_t sys_cycles = 0;

    // COM1 output
    std::string con;
    bool line_start = true, matched = until.empty();
    double t_match = 0;

    // TXD decoder (9600 8N1): bit time in ps
    const double T_BIT = 1e12 / 9600.0;
    int last_txd = 1; double rx_t0 = 0; bool rx_busy = false;
    std::deque<int> loaded;                 // bytes the 16550 started sending
    int mismatches = 0;
    unsigned decoded = 0;

    // RXD line driver and keyboard injection
    std::deque<int> rx_q, kbd_q;
    double rx_next = 0; int rx_bitn = -1, rx_byte = 0;
    double kbd_next = 0;
    bool input_started = false;

    // frame capture
    const int W = 1024, H = 768;
    std::vector<uint8_t> frame(W * H * 3), last(W * H * 3);
    bool have_frame = false;
    int px = 0, py = 0, last_hs = 1, last_vs = 1, last_de = 0;
    bool line_had_de = false;

    while (t < t_end && !Verilated::gotFinish()) {
        bool sys_edge = n_sys <= n_pix;
        t = sys_edge ? n_sys : n_pix;
        if (sys_edge) {
            top->clk_sys = !top->clk_sys;
            n_sys += T_SYS / 2;
        } else {
            top->clk_pix = !top->clk_pix;
            n_pix += T_PIX / 2;
        }
        top->eval();

        if (sys_edge && top->clk_sys) {
            sys_cycles++;
            if (sys_cycles == 16) top->reset = 0;
            top->kbd_stb = 0;

            if (top->com1_tx_stb) {
                int c = top->com1_tx_byte;
                loaded.push_back(c);
                if (stamp && line_start) printf("[%9.3f ms] ", t / 1e9);
                line_start = c == '\n';
                putchar(c);
                fflush(stdout);
                con += (char)c;
                if (!matched && con.find(until) != std::string::npos) {
                    matched = true;
                    t_match = t;
                    if (after_ms <= 0) t_end = t;
                    else t_end = t + after_ms * 1e9;
                }
            }

            // start the input once the console is ready
            if (!input_started && matched) {
                input_started = true;
                for (char c : rx_text) rx_q.push_back((unsigned char)c);
                for (char c : type_text) kbd_q.push_back((unsigned char)c);
                rx_next = kbd_next = t + 1e9;   // 1 ms later
                if (until.empty()) t_end = std::max(t_end, t);
                if (!rx_q.empty() || !kbd_q.empty())
                    t_end = std::max(t_end, t + (rx_q.size() + kbd_q.size() + 4) * 2.2e9 + after_ms * 1e9);
            }
            // keyboard: one character every 2 ms
            if (!rx_q.empty() || rx_bitn >= 0) kbd_next = std::max(kbd_next, t + 5e9);
            if (!kbd_q.empty() && t >= kbd_next) {
                top->kbd_stb = 1;
                top->kbd_byte = kbd_q.front();
                kbd_q.pop_front();
                kbd_next = t + 2e9;
            }
            // RXD: 8N1 at 9600, then 1 ms gap
            if (t >= rx_next) {
                if (rx_bitn < 0 && !rx_q.empty()) {
                    rx_byte = rx_q.front(); rx_q.pop_front();
                    rx_bitn = 0; top->uart_rxd = 0; rx_next = t + T_BIT;
                } else if (rx_bitn >= 0) {
                    rx_bitn++;
                    if (rx_bitn <= 8) { top->uart_rxd = (rx_byte >> (rx_bitn - 1)) & 1; rx_next = t + T_BIT; }
                    else { top->uart_rxd = 1; rx_bitn = -1; rx_next = t + T_BIT + 1e9; }
                }
            }

            // TXD decode: sample each bit in its middle
            int txd = top->uart_txd;
            if (!rx_busy && last_txd && !txd) { rx_busy = true; rx_t0 = t; }
            last_txd = txd;
        }

        // TXD sampling at bit centres (done on every system edge for accuracy)
        static int bitv[10]; static int nbit = 0;
        if (sys_edge && top->clk_sys && rx_busy) {
            double c = rx_t0 + T_BIT * (nbit + 0.5);
            if (nbit < 10 && t >= c) {
                bitv[nbit++] = top->uart_txd;
                if (nbit == 10) {
                    int v = 0;
                    for (int b = 0; b < 8; b++) v |= bitv[b + 1] << b;
                    bool ok = bitv[0] == 0 && bitv[9] == 1;
                    int exp = loaded.empty() ? -1 : loaded.front();
                    if (!loaded.empty()) loaded.pop_front();
                    decoded++;
                    if (!ok || v != exp) {
                        mismatches++;
                        fprintf(stderr, "\nTXD mismatch at %.3f ms: line %02x%s, loaded %02x\n",
                                t / 1e9, v, ok ? "" : " (framing)", exp);
                    }
                    nbit = 0;
                    rx_busy = false;
                }
            }
        }
        if (!rx_busy) nbit = 0;

        // video capture on the pixel clock's rising edge
        if (!sys_edge && top->clk_pix) {
            int hs = top->vga_hs, vs = top->vga_vs, de = top->vga_de;
            if (de) {
                if (px < W && py < H) {
                    uint8_t *p = &frame[(py * W + px) * 3];
                    p[0] = top->vga_r; p[1] = top->vga_g; p[2] = top->vga_b;
                }
                px++;
                line_had_de = true;
            }
            if (last_de && !de) { px = 0; if (line_had_de) py++; line_had_de = false; }
            if (last_vs && !vs) {
                if (py >= H) { last.swap(frame); have_frame = true; }
                py = 0; px = 0;
            }
            last_hs = hs; last_vs = vs; last_de = de;
        }
    }

    if (!line_start) putchar('\n');
    fprintf(stderr, "sim: %.3f ms simulated, %llu system cycles, %u characters checked on TXD, %d mismatches%s\n",
            t / 1e9, (unsigned long long)sys_cycles, decoded, mismatches,
            matched ? "" : ", --until not matched");
    if (!shot.empty()) {
        if (have_frame) {
            stbi_write_png(shot.c_str(), W, H, 3, last.data(), W * 3);
            fprintf(stderr, "sim: screenshot %s\n", shot.c_str());
        } else fprintf(stderr, "sim: no complete frame for the screenshot\n");
    }
    top->final();
    delete top;
    (void)t_match;
    return mismatches ? 2 : matched ? 0 : 1;
}
