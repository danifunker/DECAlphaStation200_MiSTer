// Bench of the TOY CMOS kept with the NVRAM image (rtl/sio/isa_rtc.v cm_* port, rtl/mister/nvsave.v
// block 16) and the OSD Console modes (0 NVRAM file, 1 SRM, 2 ARC; CMOS 3Fh = 1 starts ARC):
//   - an 8,704-byte image with the "CMOS" marker loads 3Fh and the rest of the CMOS; 3Fh reads as
//     kept in mode 0 and as the override in modes 1 and 2;
//   - a guest write of 3Fh (a firmware console switch) is saved 2 s later into block 16 with the
//     marker, the NVRAM blocks unchanged, and an override never ends up in the file;
//   - an 8 KB image is read and saved as 16 blocks (no CMOS, 3Fh reads 0: SRM);
//   - a padded image (block 16 all zeros) loads no CMOS but gets one at the next save;
//   - 17h (SRM's console variable, 1 graphics, 0 serial) under the OSD SRM console (0 Graphics,
//     1 Serial, 2 NVRAM file): reads the override in 0 and 1, the kept value in 2; `set console`
//     under an override is kept and saved, the override never reaches the file.
// hps_io is played here: a request is acknowledged, then each byte k of the transfer has
// sd_buff_addr = k; on a read (file to core) sd_buff_dout/sd_buff_wr carry it, on a write (core
// to file) sd_buff_din is taken after the clock edge that presented the address (the NVRAM's
// registered read), as the original 8 KB save does on the board.
//
//   make -C verilator tb_cmos
#include "Vtb_cmos_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vtb_cmos_top *t;
static int fails, checks;
static std::vector<uint8_t> file;   // the image on the SD card

#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
static void wait(int n) { while (n--) tick(); }
static void outb(int port, uint8_t v) { t->io_addr = port; t->io_din = v; t->io_wr = 1; tick(); t->io_wr = 0; t->io_addr = 0; }
static uint8_t inb(int port) { t->io_addr = port; t->io_rd = 1; t->eval(); uint8_t v = t->io_dout; tick(); t->io_rd = 0; t->io_addr = 0; return v; }
static uint8_t cmos(int i) { outb(0x70, i); return inb(0x71); }
static void cmos_w(int i, uint8_t v) { outb(0x70, i); outb(0x71, v); }

// serve one pending request of the core (if any): returns 1 read, 2 write, 0 none
static int serve() {
    if (!t->sd_rd && !t->sd_wr) return 0;
    int rd = t->sd_rd, n = (t->sd_blk_cnt + 1) * 512, base = t->sd_lba * 512;
    t->sd_ack = 1; tick();
    for (int k = 0; k < n; k++) {
        t->sd_buff_addr = k;
        if (rd) { t->sd_buff_dout = base + k < (int)file.size() ? file[base + k] : 0; t->sd_buff_wr = 1; }
        tick();
        t->sd_buff_wr = 0;
        // the registered read: the byte for the address of this edge, valid after it
        if (!rd && base + k < (int)file.size()) file[base + k] = t->sd_buff_din;
    }
    t->sd_ack = 0; tick(); wait(4);
    return rd ? 1 : 2;
}
static void mount() {
    t->img_size = file.size(); t->img_mounted = 1; tick(); t->img_mounted = 0;
    int r = 0; for (int i = 0; i < 50 && !r; i++) { r = serve(); tick(); }
    CHECK(r == 1, "mount: no read request");
}
static int save_wait() {   // let the 2 s quiet time pass and serve the save
    for (int i = 0; i < 3000; i++) { tick(); if (t->sd_wr) return serve(); }
    return 0;
}
static int srm = 2;   // the OSD SRM console for the next reset (2 NVRAM file: 17h as kept)
static void reset(int mode) { t->console_mode = mode; t->srm_con_mode = srm; t->rst = 1; wait(3); t->rst = 0; wait(3); }
static bool marker_at(int o) { return file[o] == 'C' && file[o + 1] == 'M' && file[o + 2] == 'O' && file[o + 3] == 'S'; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_cmos_top;

    // an 8,704-byte image: NVRAM pattern, block 16 with the marker, CMOS 3Fh = 1 (ARC), 20h = 5Ah
    file.assign(8704, 0);
    for (int i = 0; i < 8192; i++) file[i] = (uint8_t)(i * 7 + 3);
    file[8192] = 'C'; file[8193] = 'M'; file[8194] = 'O'; file[8195] = 'S';
    file[8192 + 128 + 0x3F] = 0x01; file[8192 + 128 + 0x20] = 0x5A;
    reset(0); mount();
    CHECK(t->sd_blk_cnt == 16, "17 blocks for an 8,704-byte image (got %d)", t->sd_blk_cnt + 1);
    CHECK(t->loaded, "loaded");
    CHECK(cmos(0x3F) == 0x01, "mode 0: 3Fh from the image = 1 (ARC), got %02x", cmos(0x3F));
    CHECK(cmos(0x20) == 0x5A, "CMOS 20h from the image, got %02x", cmos(0x20));
    reset(1); CHECK(cmos(0x3F) == 0x00, "mode 1: 3Fh reads 0 (SRM override)");
    reset(2); CHECK(cmos(0x3F) == 0x01, "mode 2: 3Fh reads 1 (ARC override)");
    reset(1);
    CHECK(save_wait() == 0, "an override alone saves nothing");

    // mode 0: the firmware switches to SRM (3Fh = 0) and writes the NVRAM: both saved
    reset(0);
    std::vector<uint8_t> before(file.begin(), file.begin() + 8192);
    cmos_w(0x3F, 0x00);
    CHECK(cmos(0x3F) == 0x00, "3Fh written 0 reads 0");
    CHECK(save_wait() == 2, "a CMOS write is saved");
    CHECK(marker_at(8192), "block 16 marker after the save");
    CHECK(file[8192 + 128 + 0x3F] == 0x00, "3Fh saved 0, got %02x", file[8192 + 128 + 0x3F]);
    CHECK(file[8192 + 128 + 0x20] == 0x5A, "CMOS 20h kept, got %02x", file[8192 + 128 + 0x20]);
    bool same = true; for (int i = 0; i < 8192; i++) same = same && file[i] == before[i];
    CHECK(same, "NVRAM blocks unchanged by a CMOS save");

    // an override in force: a guest 3Fh write is the kept value; the file keeps it, not the override
    reset(2);
    cmos_w(0x3F, 0x00);
    CHECK(cmos(0x3F) == 0x01, "mode 2 still reads 1");
    CHECK(save_wait() == 2, "saved under the override");
    CHECK(file[8192 + 128 + 0x3F] == 0x00, "file keeps the guest's 0, not the override, got %02x", file[8192 + 128 + 0x3F]);

    // switch back to ARC in mode 0, reset: 3Fh 1 and kept across a fresh load (a core load)
    reset(0); cmos_w(0x3F, 0x01); CHECK(save_wait() == 2, "saved");
    delete t; t = new Vtb_cmos_top; reset(0); mount();
    CHECK(cmos(0x3F) == 0x01, "after a core load: 3Fh 1 again (ARC), got %02x", cmos(0x3F));

    // an 8 KB image (the older size): 16 blocks, no CMOS, 3Fh reads 0 (SRM)
    file.assign(8192, 0x11);
    delete t; t = new Vtb_cmos_top; reset(0); mount();
    CHECK(t->sd_blk_cnt == 15, "16 blocks for an 8 KB image");
    CHECK(cmos(0x3F) == 0x00, "8 KB image: 3Fh 0 (SRM)");
    cmos_w(0x30, 0x77); CHECK(save_wait() == 2, "saved");
    CHECK(file.size() == 8192 && file[0] == 0x11, "8 KB image keeps its size and NVRAM");

    // a padded image (block 16 zeros, no marker): nothing loads; the next save writes the marker
    file.assign(8704, 0); for (int i = 0; i < 8192; i++) file[i] = 0x22;
    delete t; t = new Vtb_cmos_top; reset(0); mount();
    CHECK(cmos(0x3F) == 0x00, "padded image: 3Fh 0 (SRM)");
    cmos_w(0x3F, 0x01); CHECK(save_wait() == 2, "saved");
    CHECK(marker_at(8192) && file[8192 + 128 + 0x3F] == 0x01, "padded image gets the marker and 3Fh 1");
    CHECK(file[100] == 0x22, "NVRAM of the padded image kept");

    // SRM's console variable, 17h: an image that keeps 17h = 1 (graphics), 3Fh = 0
    file.assign(8704, 0); for (int i = 0; i < 8192; i++) file[i] = 0x33;
    file[8192] = 'C'; file[8193] = 'M'; file[8194] = 'O'; file[8195] = 'S'; file[8192 + 128 + 0x17] = 0x01;
    srm = 2; delete t; t = new Vtb_cmos_top; reset(0); mount();
    CHECK(cmos(0x17) == 0x01, "SRM console NVRAM file: 17h from the image = 1 (graphics), got %02x", cmos(0x17));
    srm = 1; reset(0); CHECK(cmos(0x17) == 0x00, "SRM console Serial: 17h reads 0, got %02x", cmos(0x17));
    srm = 0; reset(0); CHECK(cmos(0x17) == 0x01, "SRM console Graphics: 17h reads 1, got %02x", cmos(0x17));
    CHECK(save_wait() == 0, "an SRM console override alone saves nothing");
    // `set console serial` under the Graphics override: kept and saved, still reads 1
    cmos_w(0x17, 0x00);
    CHECK(cmos(0x17) == 0x01, "Graphics override still reads 1 after a guest 0");
    CHECK(save_wait() == 2, "the guest's 17h write is saved");
    CHECK(file[8192 + 128 + 0x17] == 0x00, "the file keeps the guest's 0, not the override, got %02x", file[8192 + 128 + 0x17]);
    srm = 2; reset(0); CHECK(cmos(0x17) == 0x00, "NVRAM file again: 17h reads the kept 0, got %02x", cmos(0x17));
    // an 8 KB image: nothing kept, 17h 0 (serial) in NVRAM file mode, the Graphics default reads 1
    file.assign(8192, 0x44);
    srm = 2; delete t; t = new Vtb_cmos_top; reset(0); mount();
    CHECK(cmos(0x17) == 0x00, "8 KB image, NVRAM file: 17h 0 (serial)");
    srm = 0; reset(0); CHECK(cmos(0x17) == 0x01, "8 KB image, Graphics: 17h 1");
    CHECK(cmos(0x3F) == 0x00 && cmos(0x16) == 0x00 && cmos(0x18) == 0x00, "the neighbours of 17h unaffected");

    printf("tb_cmos: %d checks, %d failures\n", checks, fails);
    delete t;
    return fails ? 1 : 0;
}
