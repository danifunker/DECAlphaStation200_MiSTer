# Resume prompt

> 2026-11-01: historical. The target is now the **4/100**, at a 100 MHz clock target; `CLAUDE.md` and `docs/CORE_SPEC.md` are current.

Setup on the new Linux machine:
1. Clone the repo.
2. Unzip `scratch.zip` in the repo root so `scratch/` exists.
3. Run the setup commands in `README.md`.
4. Copy the NT 4.0 SP6 Alpha ISO from the NAS into `scratch/isos/`.
5. Start Claude Code in the repo root and paste the prompt below.

---

```text
We're building a MiSTer (DE10-Nano) FPGA core for the DEC AlphaStation 200 4/166. This repo holds the research and
spec phase, which was done on a Mac and has now moved to this Linux machine. No RTL exists yet.

Read these first, in order:
  README.md                 - layout, setup, licensing rule (third-party files stay in scratch/, never in git)
  docs/CORE_SPEC.md         - the LOCKED hardware configuration. Treat it as authoritative; change it only deliberately
  docs/CPU_TEST_PLAN.md     - 21064 functional blocks, reference models, test-suite plan
  docs/HARDWARE.md          - the real machine: chips, address map, interrupts, boot flow
  docs/FIRMWARE_DISASM.md, docs/NT_DRIVERS.md, docs/NT5_BETAS.md - reference material and how it was produced
scratch/README.md lists everything in scratch/ with SHA-1s.

Decisions already made (don't reopen without a reason):
- Machine: AlphaStation 200 4/166. CPU 21064 (EV4, 8K+8K caches, no BWX/FIX/CIX/MVI). Chipset 21071-AA (APECS).
- RAM: OSD option 32/64/128 MB (default 64), using identical non-split 21071-CA banks
  (32 = 1x32, 64 = 2x32, 128 = 1x128). The MiSTer SDRAM is enough; no DDR3.
- Video: ZLXp-E1 = DECchip 21030 TGA, 8-plane, 2 MB, PCI slot 1 (IDSEL AD23), default 1024x768@60.
  Chosen over TGA2 because ARC 4.58 only knows ZLXp-E1/E2/E3, and NT 3.51 and the early NT5 betas only ship the TGA driver.
- Firmware: default flash = the real board dump (SRM 6.4-1 + ARC 4.49) + DROM V1.2. SRM 7.0-9 / ARC 4.58 come later,
  after the flash check-byte question is answered.
- The original 64 Kbit SROM is NOT available. The core needs replacement init code that does the SROM's job
  (CPU/BIU init, memory sizing, 21071-CA bank setup), then jumps to the DROM.
- Bring-up path: serial console on COM1 first, then TGA.
- OS targets: SRM/ARC, NetBSD/Linux, Digital UNIX 4.0F/G, OpenVMS 6.2-7.2, NT 3.51/4.0 (NT4 SP6 ISO in scratch/isos),
  Windows 2000 RC1 2072 (main NT5 target; the Beta 2 1877 checked build is for debugging).

Facts that took effort to establish:
- Firmware images are DEC "WimC" containers holding raw DEFLATE (tools/fwextract.py). SRM decompresses to 0x8000
  (VMS PALcode @0x8000 = reset entry, OSF PALcode @0x14000, console from ~0x38000). ARC decompresses to PA 0x700000
  and runs at VA 0xFFFFFFFF80700000 (32-bit superpage). The ARC flash header's length field is about 0x40 too short.
- tools/alphaemu ran DEC's own stubs, and its output matched zlib byte for byte. It is the seed of our reference model.
- EV4 FP traps on NaN/Inf/denormal operands (OS software completion). Underflow can force +0. FP tests must model
  this; QEMU's full IEEE results won't match raw EV4 behaviour.
- No CPU test suite exists in any ROM. The DROM is an I/O POST plus an interactive monitor; the AS200 SRM has no test command.
- No hardware is available: verification is simulation-first (Verilator) against reference models.

Next tasks, in order:
1. Toolchain sanity check: alpha-linux-gnu-as/gcc with -mcpu=ev4, qemu-alpha -cpu ev4, and building tools/alphaemu.
2. Start the CPU test suite (docs/CPU_TEST_PLAN.md, tier T0): a bare-metal PALmode test harness (reset entry, pass/fail
   signature to a "tohost" address plus the diagnostic LEDs), and self-checking tests for every Ebox integer opcode.
3. Extend tools/alphaemu into the golden model: full integer ISA, trace output (PC, dest reg, value, memory writes),
   then FP with the EV4 trap rules.
4. Scaffold the RTL repo structure and a Verilator testbench that runs T0 tests and diffs traces against alphaemu.

Open items: SROM replacement design; the flash check bytes (E19 ends 0x81, E46 ends 0x52; not a sum or XOR; see the
APU update-utility listing); confirming the ZLXp-E1 RAMDAC and clock against card manual EK-T2424-OG.
```
