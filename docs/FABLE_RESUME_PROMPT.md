# Resume prompt: TGA window moves, the remaining artefacts (2026-11-04)

Paste this into a new session (Fable). Read `CLAUDE.md` first (decisions, board, build rules), then
`docs/gaps.md` and `docs/design/tga.md` (§3 register 038 and §4 copy mode hold the copy semantics
worked out so far). The task: **windows moved around in NT 4.0 / Windows 2000 still leave drawing
artefacts on the board.** Find each one with the trace-and-replay method below, fix it in `rtl/tga/tga.v`,
add a bench case that fails on the old RTL, fit, check on the board.

## Where it stands (2026-11-04)

- **Board core: `DECAlphaStation200_20261104.rbf` = commit `3fd1dc5`** (pushed to origin, `ced4942`).
- Windows 2000 now runs on the core (the user, 2026-11-04). `docs/WIN2K_RESUME_PROMPT.md` and the
  gaps.md W2K row describe the old RC1 hang and are out of date on that point.
- Fixed today:
  - `20500af`: a right-to-left copy-mode pair (pixel shift negative) takes its 32-bit mask by byte lanes
    in **reverse quadword order**: <7:0> for [A, A+8), <15:8> [A-8, A), <23:16> [A-16, A-8), <31:24>
    [A-24, A-16), bit (x - A) & 7 within a lane (= the byte-swapped mask for NT's 8-aligned A). Before,
    a 1-7 px column at a window's right edge stayed stale after vertical moves, and 8 px at the left
    edge after a 9-px move right.
  - `3fd1dc5`: the TGA's 8-entry command queue is in logic (`ramstyle "logic"`). As an M10K, Quartus
    absorbed the c_* registers into its output register and E_DEC missed 100 MHz by 1.6 ns; that build
    drew NT's text with most pixels missing. **Lesson: when the board draws something the replay says
    it shouldn't, look at the TGA paths in the timing report before the RTL.**
- Verified on `3fd1dc5`: 26 keyboard moves of the Run dialog (Left/Up/Down at 8 x alignments, Right x1)
  match the ideal move pixel for pixel (`scratch/replay4/`). The only flagged column (13 rows, ff/00) is
  the text box's blinking caret: ignore it.
- **2026-11-04, later (this machine, Windows): the root cause of the remaining artefacts found.** The
  21030's pixel mask is one register at two addresses (manual 4.4.21.3, `scratch/refs/ec-n0683-72.pdf`
  p. 130): a one-shot write (02C) serves the next frame buffer operation and then the register
  reinitializes to FFFFFFFF; it does not revert to the value written persistently (05C) before. NT 4.0
  draws 1-pixel vertical lines with 05C = 1 and restores with 02C = FFFFFFFF alone, so with the old
  two-register model the mask stayed 1 from the first such line on: the Start menu's icons drew one
  pixel in four, its text (stipple 05) nothing, and every window move after it was masked too (the
  OSD P5 Video debug overlay showed PXP = 00000001 on the board). Fixed in `tga.v` (one `pxm` + `os_v`,
  GMOR<23> GPXR state on reads), `tools/tgareplay.py`, `verilator/tb/tb_tga.cpp` (fails on the old
  RTL). Captures: `scratch/replay5/menu` (the Start menu opening: the replay shows the x%4 != 0 pixels
  the board left grey). **Board build `0e7a496` (`_Unstable/DECAlphaStation200_20261104b.rbf`, also on .92):
  the Start menu is right; 25 traced mouse drags of the Run dialog (pixel shifts 0-7 both ways, with and
  without dy) match byte for byte (`scratch/replay5/dr*`, `c*`, `s*`); large-window drags (My Computer) over
  other windows, the icons and past the screen edges are clean.**
- **Still open (2026-11-04, afternoon):** (1) maximize + restore leaves a black band across the restored
  window's first icon row (the band is where the maximized icon row lands under the restore's client copy,
  displacement (203, 56)); F5 repaints it. (2) Minimize leaves a black wedge on the desktop with staircase
  edges (`scratch/shots/mn1.png`): NT's minimize animation. Its frames are block fills (mode 2D) with the
  colours 00/07/f8/ff/04 at rop 0, which block fill ignores (manual 4.4.3: block fill, block stipple and
  DMA-write copy always do dest = src), so the fills themselves are right; the residue must come from the
  background save/restore copies around them (copies to and from off-screen VRAM below line 600, which NT
  uses as a bitmap cache; unwritten off-screen VRAM reads as 0 = black). Both bursts overflow the 4096-event
  trace ring (30k+ events lost), so the writers were never captured: hence the **TGA trace throttle** (OSD
  P5, status bit 25, `3a467d3` + `483f51b`): with Serial port = TGA trace the TGA holds the host's writes
  while the ring holds 3800+ events, so nothing is lost and NT just draws slower. (The first build's
  threshold, 4032, sat above the reader's skip-ahead at 4000 and never fired.) Next: load the `483f51b`
  build, trace `alt+space n` (minimize) and a maximize/restore with `scratch/tgakeys_w.sh` (it waits for
  the UART to drain), `tgareplay.py --who X,Y` on a black pixel, fix, bench, fit.
- **Root cause found with the lossless traces (`scratch/replay5/{minim3,restore4,alttab1,max1}`,
  2026-11-04):** NT's minimize/restore animation flies the window's *caption bar* (blue, icon, white
  text) between the window and its taskbar button. Under each frame it saves the screen with
  copy-mode source writes (one per 32-byte block, the pixel shift set per block) followed by 8 PCI
  reads of the copy buffer registers GCBR0-7 (000-01C), and later restores the background with simple
  writes of the saved bytes. Our 000-01C read back what was last written (zeros), so every restore
  wrote 00000000 (the "pass of zeros" in the traces), and the engine paired the lone fills as
  source/destination copies. Manual 4.4.6 + 6.2.9: the GCBRs read entries 0-3 of the engine's
  64-byte copy buffer (the slope-no-go registers 100-11C entries 4-7), aligned as the destination
  gets them; even/odd GCBR writes load an entry for a drain. Fixed in `18e350e` (tga.v, a `Qooo`
  trace line per such read, tgareplay.py, tb_tga reads + loads; the old RTL fails the bench). The
  throttle build had hidden the minimize wedge by timing only. **Board build `18e350e`
  (`_Unstable/DECAlphaStation200_20261104e.rbf` on .143 and .92): minimize, Alt+Tab, maximize and
  restore clean at full speed, drags and the Start menu afterwards too; lossless traces of a maximize
  and a restore (`scratch/replay5/max2`, `restore5`: 3.7k / 7.2k Q lines) replay byte for byte.**
  Remaining to check: Windows 2000 (the user runs it on .92), bigger NT sessions (Explorer windows,
  dialogs, menus) for anything else; then the release items below.
- **Mouse drags from the command line:** `misterkvms-cli mouse drag DX DY [--steps N] [--step-ms MS]` and
  `--path "dx,dy dx,dy ..."` (added to the user's MiSTerKVMS cli, commits `9941804`, `d4688ba`): a separate
  `mouse down` is released when its process exits. NT doubles a move of 30 px to 60 and adds a tail of
  1-4 px as is (path "30,0 3,0" gives 62..64), and moves under ~4 px start no drag. `scratch/tgadrag_w.sh`,
  `dragbatch2.sh` (a batch file of name<TAB>path), `titlebar.py` (the active title bar for the grab point).
- Earlier suspects (before the root cause above), none tested:
  - **Mouse drags** (all tests so far were keyboard moves of one small dialog): many small moves in a
    row, full-window drag if enabled, moves while the window overlaps others or the screen edge.
  - **Bigger windows**: trace ring overflow hides them from the replay (see below); copies with
    different block counts, COPY64 runs with other shifts, rows that start/end mid-quadword on both sides.
  - Right-to-left copies with A not 8-aligned (all of NT's so far were), or c_off[2] set: the reverse-lane
    rule for those cases is extrapolated (`cp_msk`'s c_off[2] branch), not observed.
  - The redraw of uncovered areas (stipple 05 text, fills 2D/21/25, simple writes with the one-shot
    pixel mask 02C) and the desktop icon labels ("My Computer" losing pixels, seen 2026-11-03, not
    reproduced since).
  - Windows 2000 uses its own display driver build: its register stream may use modes or patterns NT 4.0's
    tga.dll never did (other raster ops, line modes, 0E/Z modes not drawn by the model at all).
  - Timing: worst slack -1.795 ns at 100 MHz, all in `ev4_core` now; re-check the TGA after any change.

## Ground rules (from the user; they hold)

- **Development is moving to another computer (2026-11-04), possibly Windows.** Quartus 17.0 Lite runs
  on Windows or Linux (not macOS): on Windows, fit with the native Quartus (`quartus_sh --flow compile
  DECAlphaStation200` in a clone on the Windows drive). Verilator, the bench (`make -C verilator ...`),
  `tools/*.sh`/`*.py`, ssh to the MiSTer and the Alpha cross tools go in WSL2 (Ubuntu: `verilator
  build-essential python3-pil binutils-alpha-linux-gnu gcc-alpha-linux-gnu qemu-user`). The old Linux
  box is m900 (repo `~/repos/DECAlphaStation200_MiSTer`, fit worktree `../DECAlphaStation200_fit`).
  `scratch/` is not in git: copy what you need (`memdump`, `refs/`, `disasm/`, `nt_drivers/`, `ntkd/`,
  `roms/`, `replay*/`); `docs/RESUME_PROMPT.md` has the rsync line.
- Board: MiSTer at 192.168.99.143 (ssh root, key login; add the new machine's key). Drive it with
  `misterkvms-cli --mister 192.168.99.143` (`screenshot`, `key`, `type`, `mouse`; MiSTerKVMS 1.0.26+,
  the user's repo danifunker/MiSTerKVMS). The capture is 800x600 while NT's GUI runs, 1284x964 in ARC.
  **On the Windows machine (2026-11-04):** the repo is `C:\Temp\mistercore\DECAlphaStation200_MiSTer`
  (WSL: `/mnt/c/Temp/mistercore/DECAlphaStation200_MiSTer`; `scratch/` is there); misterkvms-cli is
  `C:\Temp\mistercore\MiSTerKVMS	arget
elease\misterkvms-cli.exe` (its settings file names the
  capture stream); ssh to the board works only from WSL (Ubuntu-24.04) with `-i ~/.ssh/mister_only`,
  so the dumps and the trace capture run there (`scratch/ms.sh`, `trace_start.sh`, `trace_stop.sh`,
  `vramdump.sh`; call WSL as `wsl.exe -d Ubuntu-24.04 -- bash -lc "cd /mnt/c/... && ..."` from Git
  Bash, since it rewrites bare `/mnt/c` paths); Quartus 17.0 is `C:\intelFPGA_lite.0`.
  **The OSD reopens on the page it was closed on**, and Enter on a file row opens the selector, on an
  option toggles it: screenshot before every Enter (one Enter toggled J2 floppy boot today).
- **Load cores only through the OSD** (F12, Right to the System page, Core, `_Unstable`). Never use
  `/dev/MiSTer_cmd`, `load-core` or CFG edits.
- Copy each board build to `/media/fat/_Unstable/DECAlphaStation200_<today YYYYMMDD>.rbf`. **At most two**
  DECAlphaStation200 rbfs in `_Unstable`. Deleting on the board may be blocked: move old ones to
  `/media/fat/rbf_old/` instead.
- Fits: one at a time, `setsid nohup quartus_sh --flow compile DECAlphaStation200 > fit.log 2>&1 <
  /dev/null &` in the fit worktree. About 30 min; kill at 45. Stop only your own fit, by PID.
  `pkill -f`/`pgrep -f` match your own shell: don't use them.
- Commit locally in small steps. Never push without asking. Third-party material stays in `scratch/`.
  Never delete files without asking (move them to the trash).

## After every core load

The OSD keeps Console = ARC and the mounted images, but **Serial port resets to COM1**: set Advanced
(P5) Serial port = **TGA trace**, then Apply and reset.

ARC's default boot entry is Terminal Server, which is not on `NT4_2GB.img` ("ntoskrnl.exe missing").
When that error shows: Enter, wait 4 s, Down, Enter, then Enter on "Boot Windows NT Workstation
Version 4.00". Keys sent while the OSD is open go to the OSD (that once remounted the wrong disk): check a
screenshot before sending ARC keys. NT: Ctrl+Alt+Del, Enter (Administrator, blank password), about 3.5 min
from reset to the desktop. The test window: `key ctrl+Escape`, `key r` (the Run dialog).

Board images in `games/DECAlphaStation200/`: `NT4_2GB.img` (NT 4.0 SP1, backup
`NT4_2GB.installed-20261103.img.bak`), `WIN2K_2GB.img`, `NT4TSE_2GB.img`, the W2K RC1 ISOs.

## The method (tools in git)

1. `tools/tgamove.sh DIR KEY N`: dumps VRAM (`/tmp/memdump 0x30100000 0x200000` on the MiSTer; copy
   `scratch/memdump` there after a MiSTer reboot), starts the trace capture on `/dev/ttyS1`, moves the
   active window with the keyboard (Alt+Space, M, KEY x N, a 2.5 s drain pause, Enter), stops the capture,
   dumps again: `DIR/{before.bin,trace.log,after.bin}`. For a mouse drag, copy the script and use
   `misterkvms-cli mouse`.
2. `python3 tools/tgareplay.py DIR/before.bin DIR/trace.log DIR/after.bin --ideal` replays the trace with
   the model's semantics (the same as tga.v and tb_tga's reference) and:
   - lists the bytes where the replay differs from the board's after dump (RTL or timing fault: the
     hardware didn't do what the model says);
   - `--ideal`: takes the commonest copy displacement as the window move and lists every destination
     column whose pixels aren't the source's (a model fault: the model's semantics are wrong for NT).
   - `--list` prints each copy op with its block and source bytes; `--who X,Y` names the ops that
     wrote a pixel. Pixel (x, y) = byte `4096 + y*800 + x` in the 800x600 GUI.
3. **Trace losses**: lines `Dnnnnnnnn` mean the 4096-event ring overflowed (892857 baud); the replay
   is then wrong after that point. Keep moves small (one key step), close big windows, or capture
   only what you need. Windows bigger than the Run dialog overflow on most moves.
4. Find the rule from the ops around the bad columns (masks, A & 7, the shift in R038, which pair),
   change `tga.v`, `tools/tgareplay.py` and `verilator/tb/tb_tga.cpp` together, `make -C verilator
   tb_tga` (must fail on the old RTL), fit, board, sweep again.

Other tools: `tools/tgashot.sh` (screenshot from VRAM), `tools/ntkd.py` (NT kernel debugger over COM1,
OSD Serial port = COM1), the OSD P5 Video debug overlay (the TGA's drawing state on screen).

After the video: put `dbg_trace` and `dbg_overlay` behind a compile switch for release builds (about
960 LUTs, 33 M10Ks), and make NT Workstation the default ARC boot entry on `NT4_2GB.img`.
