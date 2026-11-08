# Resume prompt (Fable): the OpenVMS SCSI "offline" events — diagnosed 2026-11-08, fix open

Paste this into a new session. Read `CLAUDE.md`, then in `docs/gaps.md` the SCSI table's row "hps_io
stalls of seconds hold the SCSI bus" and the OpenVMS row of the OS table (its 2026-11-08 paragraphs).
`docs/OS_INSTALL_RESUME_PROMPT.md` is the general board procedure and the OS ladder. The user's rules:
only report what a test showed; commit small steps locally; never push, never delete files without
asking; never overwrite an installed disk image; **ask the user before any change to Main or to the
board's configuration** (both are theirs).

## 1. State

- **OpenVMS 7.3 is installed** (`VMS73_2GB.img`, backup `VMS73_2GB.installed-20261108.img.bak`), boots
  from `dka0` to the SYSTEM login, a copy checksums equal. OpenVMS 6.2 likewise (`VMS62_2GB.img`,
  backup of the same date; `VMS62_scratch.img` is a spare copy, md5-identical). 8.4, Tru64 and
  FreeBSD are not installed yet (`OS_INSTALL_RESUME_PROMPT.md`).
- Core `_Unstable/DECAlphaStation200_20261107l.rbf` = `d65633c` on .143 (and .92, not loaded there).
  .143 sits at SRM `>>>` after 7.3's orderly shutdown; OSD (unsaved) Console SRM, Display Serial
  console, 128 MB, Pri. disk `VMS73_2GB.img`, CD `OpenVMS 7.3 Alpha.iso`, Serial port = TGA trace.
- Passwords: `scratch/os_credentials.txt` (CRLF file; the token after `password:`; never print it).

## 2. The diagnosis (problem 1 of the previous hand-off)

Every `%SYSTEM-I-MOUNTVER, DKA0: is offline` during the 7.3 install (five in the PCSI copy, one in
AUTOGEN's GENFILES; 6.2's install had two) is the same event, seen in the board's SCRIPTS trace
(`scratch/inst_trace_3.log`, `_4`, `_6a`; decode with `tools/ncrtrace.py LOG`):

1. a WRITE(6) to ID 0 enters DATA OUT; the target takes 2 KB, hands it to hps_io (`sd_wr`) and waits
   in **T_STORE (trace state 08)** for Main's ack, REQ low;
2. **~3 s later** (the ticker-stamped `inst_trace_6a.log`: DATA OUT began 3.2 s before the abort)
   VMS's port driver writes ISTAT ABRT, then SRST, re-initialises the chip and pulses SCNTL1 RST (bus
   reset: `SIST0 RST`), re-selects the disk with SDTR and retries; the class driver reports the unit
   offline and mount-verifies it (always recovered);
3. at that same second **Main was blocked in uninterruptible disk sleep (state D) for 3726 ms**, then
   3190 ms seven seconds later (`scratch/vms73_stall.log`, from `scratch/stallmon_remote.sh`: a 20 ms
   sampler of `/proc/<MiSTer pid>/stat`). Main's `flush_run` (`support/decalpha/decalpha_disk.cpp`,
   branch `scsi-consolidated-2-decalpha`) writes a 64 KB run with one synchronous `write()`; `/media/fat`
   is exFAT mounted `sync,dirsync`; idle, such writes take 36 ms (max 73 ms over 1500), but under the
   install's mixed CD reads and disk writes the card stalls for seconds now and then.

So: **the SD card's write stalls reach the SCSI bus because the target holds DATA phase while it waits
for hps_io, and VMS gives a command about 3 s in a data phase.** NT and NetBSD tolerate it (longer
timeouts). Not the cause: the 53C810 model, the targets' command set, VMS's mode pages (the previous
hand-off's problem 2 — the CD "has been write-locked" mount verification — did not recur in six resets;
it needs a reset while a CD read is in flight, and the CD is mounted wrtlck anyway: `SHOW DEVICE`).
Dropped hypotheses and their measurements are in the gaps.md OpenVMS row.

## 3. The fix: decide with the user, then do one (or both)

**A. Main (the right place):** keep the SD write off the hps_io path. In `decalpha_disk.cpp`, `stage()`
already buffers; `flush_run` is what blocks. A writer thread (a queue of runs, `pthread`, the main
thread only enqueues; `decalpha_disk_flush` waits for the queue to drain; the read path's
`flush_overlap` must wait for the overlapping run's completion or serve the read from the run) makes
the ack immediate. **Done 2026-11-08**: branch `decalpha-writer` in the worktree
`../Main_MiSTer_decalpha_fix` (`f2d29c2` the thread, `2074fbd` core-0 affinity like `offload.cpp`,
`635fcad` the descriptor fix), built in WSL (`export PATH=$PATH:/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin;
make -j12` in the worktree; the binary is `bin/MiSTer`; if Ubuntu's `arm-linux-gnueabihf-g++` ever
ran there, `rm -rf bin` first — its objects need glibc 2.39 symbols) and deployed to .143
(`scratch/deploy_main.sh`: backup `/media/fat/MiSTer.before-writer-20261108`, copy, reboot). The
pitfall that cost one install attempt: `fileTYPE.path` is empty for hps_io images (only `ide.cpp`
fills it), so a writer must take its descriptor from the stream (`/proc/self/fd/N`) — and since the
main thread reads through stdio, a read after writes purges the stream (`__fpurge`).

**B. Core:** SCSI disconnect/reselect in `rtl/scsi/scsi_targets.v` while a target waits for hps_io
(T_STORE/T_FETCH longer than, say, 10 ms): send SAVE DATA POINTER + DISCONNECT, free the bus, and when
the data is there, arbitrate, reselect the initiator (ID 7), IDENTIFY, continue the data phase. Needs:
reselection in `rtl/scsi/ncr53c810.v` (the WAIT RESELECT path; the drivers' SCRIPTS all have it —
VMS PKC/PKR, NetBSD siop, Linux, NT symc810: check `scratch/simruns/vms_scripts.txt`), the DISCONNECT
privilege bit from the IDENTIFY message, and a `verilator/tb/tb_ncr810.cpp` case with a delayed
hps_io ack (`--disk-lat` exists in `tb_sys`). **Done 2026-11-08**: `09336cd` (`docs/design/scsi.md`
section 5, `tb_ncr810`'s WRITE/READ disconnect cases pass), fit `20261108a` (-1.607 ns at 100 MHz,
36.6k ALMs, 87 %) on both boards, loaded on .143; the fast system sim on this RTL still finds every
device in SRM's `show device`.

Verification (running 2026-11-08 from ~15:05): the OpenVMS 8.4 install onto `VMS84_4GB.img` with
`scratch/tracerot84.sh` (pieces `scratch/inst84_trace_N.log`), `scratch/stallmon_start.sh` and
`scratch/watch.sh 24 w84_` (a screenshot every 5 min, `scratch/w84_N.png`). After 20 min: 10 % done,
no MOUNTVER, no Main block >= 300 ms (`/tmp/stall.log` on .143), no bus reset, no disconnect in the
trace (none needed: Main never stalled). VMS's IDENTIFY is `C0`, so the core's disconnect path is
armed if a stall ever comes.

## 4. Board helpers (in `scratch/`, not in git; Git Bash unless noted)

`ms.sh 'cmd'` ssh (WSL only: `wsl.exe -d Ubuntu-24.04 -- bash -lc "cd /mnt/c/Temp/mistercore/
DECAlphaStation200_MiSTer && sh scratch/ms.sh '...'"`; feed scripts on stdin: `sh scratch/ms.sh 'sh -s'
< scratch/X.sh`); `k.sh OUT.png KEY...`; `ans.sh OUT.png WAIT TEXT` (type, Enter, wait, screenshot);
`shot.sh OUT.png WAIT`; `slowtype.sh TEXT` (3 characters at a time: no-echo prompts drop fast typing);
`osdboot.sh N "boot dkaX"` (from the OSD's first row: Apply and reset, 28 s, N boots); `trace_start.sh`
/ `trace_stop.sh OUT` (the SCRIPTS trace with the ticker; `tracerot.sh N` rotates it); `stallmon_start.sh`
/ `stallmon_stop.sh OUT`; `watch.sh N PREFIX` (a screenshot every 5 min). The harness blocks a
foreground `sleep` over a minute: use `run_in_background` or an `until` loop. The SRM P0 boot failure
still hits about every other boot from a running SRM: boot right after an OSD reset, retry on failure.
VMS's PS/2 keystrokes also reach the 8242 (`_OPA2:` login-failure audits on every line): cosmetic.
