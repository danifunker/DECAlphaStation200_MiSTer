# Resume prompt: NT4 video leftovers and Windows 2000 RC1 (2026-11-03)

Paste this into a new session (Fable). Read `CLAUDE.md` first (decisions, board, build rules), then
`docs/gaps.md`, `docs/design/tga.md` and `docs/WIN2K_RESUME_PROMPT.md`. Work in order: the two video
leftovers first (short, the tooling is ready), then Windows 2000.

## Ground rules (from the user; they hold)

- Board: MiSTer at 192.168.99.143 (ssh root). Drive it with
  `~/Downloads/MiSTerKVMS-1.0.27-linux-x86_64/misterkvms-cli --mister 192.168.99.143`
  (`screenshot`, `key`, `type`, `mouse`). The capture is 800x600 while NT's GUI runs, 1024x768 otherwise.
- **Load cores only through the OSD** (F12, Right to the System page, Core, `_Unstable`). Never use
  `/dev/MiSTer_cmd`, `load-core` or CFG edits.
- Copy each board build to `/media/fat/_Unstable/DECAlphaStation200_<today YYYYMMDD>.rbf`, replacing that
  day's file. **At most two** DECAlphaStation200 rbfs may sit in `_Unstable`; delete older ones.
- Fits: in the worktree `../DECAlphaStation200_fit` (`git -C ../DECAlphaStation200_fit checkout --detach
  master`), one at a time, `setsid nohup quartus_sh --flow compile DECAlphaStation200 > fit.log 2>&1 <
  /dev/null &` (Quartus is in `~/intelFPGA_lite/17.0/quartus/bin`). About 25 min; kill at 45 min.
  Stop only your own fit, by PID (`readlink /proc/PID/cwd`). `pkill -f`/`pgrep -f` match your own shell:
  don't use them.
- Commit locally in small steps. Never push without asking. The Main_MiSTer `latest` release was
  updated on request (branch `scsi-consolidated-2-decalpha`, `d33167f`).
- Third-party material stays in `scratch/`. Never delete files without asking.

## After every core load

These settings reset to their defaults when a core loads, so set them each time in the OSD:
- Machine page, Console = **ARC** (it defaults to SRM, which leaves the TGA black).
- Advanced page (P5), Serial port = **TGA trace** for the video work.

Then Apply and reset (the last line of the main page). ARC autoboots NT4 from `NT4_2GB.img`:
- Ctrl+Alt+Del (`key ctrl+alt+del`).
- Enter (Administrator, blank password).
- About 3.5 min from reset to the desktop.

Board images in `games/DECAlphaStation200/`:
- `NT4_2GB.img` (installed NT 4.0 SP1), with the backup `NT4_2GB.installed-20261103.img.bak`.
- `NT5_2GB.img` (empty, for W2K).
- `W2K_RC1_Alpha.iso` (original), and `W2K_RC1_Alpha_kd*.iso` (TXTSETUP.SIF patches, see the W2K prompt).

## Debug tools that work

- **TGA trace** (`rtl/mister/dbg_trace.v`, OSD Serial port = TGA trace). Every register write
  (`Rooo dddddddd`, cursor writes left out) and every frame buffer write (`Wmm b oooooo dddddddd`),
  892857 baud, 4096-event ring (`D` lines count losses).
  Capture on the MiSTer:
  `stty -F /dev/ttyS1 921600 raw -echo; cat /dev/ttyS1 > /tmp/x.log` (background it, killall cat to stop).
- **VRAM dump**: `ssh root@... '/tmp/memdump 0x30100000 0x200000' > f.bin`. Copy `scratch/memdump` to
  `/tmp` after a MiSTer reboot.
  Layout in NT's 800x600 GUI: pixel (x, y) = byte `4096 + y*800 + x`, 8 bpp; index 6 = desktop teal.
- **Window moves without the mouse**: `key alt+space`, `key m`, arrow keys, `key Enter`. The Run dialog
  (`key ctrl+esc`, `key r`) is the test window.
- The method that found the last bugs:
  1. Dump VRAM.
  2. Start the trace.
  3. Do one move.
  4. Stop the trace and dump again.
  5. Parse the copy ops (copy-mode pairs = W07 source/destination; COPY64 = R160..R17C pairs; R038 =
     pixel shift, signed).
  6. Check which byte ranges NT expects each op to cover against the window's extent in the dumps.
  Examples: `scratch/replay/`, `scratch/replay2/`.
- **NT kernel debugger** (`tools/ntkd.py`; header and memory notes). Needs ARC OSLOADOPTIONS
  `/DEBUG /DEBUGPORT=COM1 /BAUDRATE=115200` (set on the NT4 boot entry), OSD Serial port = COM1, and
  `socat TCP-LISTEN:5150,reuseaddr,fork /dev/ttyS1,raw,echo=0,b115200` on the MiSTer. The tool:
  - logs image loads and exceptions;
  - sets kernel breakpoints, which log the argument registers and the process;
  - reads memory.
- NT symbols: `scratch/ntkd/SUPPORT/DEBUG/ALPHA/SYMBOLS`. Helpers in `tools/nt/`.
  Disassemble tga.dll with symbols: `pedbg.py` + `alpha-linux-gnu-objdump -D -b binary -m alpha`.
- TGA bench: `make -C verilator tb_tga`. It holds NT's copy patterns (rows in both directions,
  overlapping, the shifter residue). Add a case for every fix and check that it fails on the old RTL.

## Task 1: the two NT4 video leftovers (core `43dd7e9`)

What's fixed today, with commits in git log and details in `docs/design/tga.md` §3/§4:
- COPY64's four pairs.
- The signed pixel shift.
- Right-to-left blocks addressed by their last quadword (COPY64 [A&~7-56, A|7], copy mode [A&~7-24, A|7]
  with mask bit (x-A)&31).
- The shifter residue, and the copy toggle.
- Line modes 02/06; the simple-mode pixel mask per longword.

The right-to-left addressing is inferred from NT's register stream, not from the 21030 data sheet;
re-check it if a new case contradicts it.

1. **Stale 1-8 px column at the window's right edge after some vertical moves.**
   - Reproduce: Run dialog, Up x6, then Down x2/x3 (or a sequence like Right x8, Up x8, Left x3).
   - Dump, trace one bad move, and compare the right copy-mode pair's mask, shift and residue with
     the window's right edge.
   - Suspects:
     - pixels of the first block in a row that need source bytes beyond the block (the residue at
       row start, where `tga.v` reads VRAM since no previous read matches);
     - copy-mode masks with low bits set (e.g. `ffffff01`, `ffffff03`);
     - a non-8-aligned destination in a right-to-left pair.
2. **Desktop icon labels redrawn after a window passes over them lose pixels** ("My Computer" shows as
   "r p t r").
   - Trace the redraw: move a window off the icon, or close a dialog over it.
   - Text is mode 05 (transparent stipple). Clipped text may use the one-shot pixel mask 02C or a
     glyph cache in off-screen VRAM (tga.dll `stipple_text`, `cache_glyphs`, `store_glyph`).
   - Compare the written masks and addresses with the glyph positions.

## Task 2: Windows 2000 RC1

Everything known is in `docs/WIN2K_RESUME_PROMPT.md` (the hang, the KD attempts, the machine-check
lead, next steps). Short version:
- RC1 build 2072 Setup loads every file, then hangs at "Setup is starting Windows 2000".
- The PC loops in ntoskrnl 0x800BFF58-A8: a ready-list drain that re-queues a thread onto the same
  process because the process's state byte (+97) says not resident.
- It's the same at 64 and 128 MB, and before and after today's CPU fixes (I-fill redirect, lock flag,
  interrupt vs ITB-miss priority).
- TXTSETUP.SIF debug options gave no COM1 traffic.

Leads, in order:
1. The OSD Serial port "CPU exceptions" trace: the rare PAL entries before the hang.
2. A longword read-modify-write stress (andnot/ldl/mskbl/insbl/stl) plus UNALIGN under
   `tests/cpu/irq_sweep.sh`.
3. The system simulation (`make -C verilator system-fast`, tb_sys `--arc --key --cd-ua --trace-pc`).
4. RC1 `halavant.dll` vs NT4's: registers it touches that NT4 doesn't; whether it expects machine
   checks on master aborts (the core never raises MCHK, `docs/design/cpu.md` Q15).

Set the OSD TOY year to 1999 for RC1, and back to "From RTC" afterwards.
