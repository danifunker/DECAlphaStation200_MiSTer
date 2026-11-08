# Resume prompt (Fable): the OpenVMS 7.3 install's SCSI failures — state on 2026-11-08

Paste this into a new session. Read `CLAUDE.md`, then in `docs/gaps.md` the OpenVMS row of the OS
table (its last two bold paragraphs, 2026-11-08: the 6.2 install and the 7.3 first try) and the SCSI
section. `docs/OS_INSTALL_RESUME_PROMPT.md` is the general board procedure and the OS ladder, and
`docs/OS_SWEEP_RESUME_PROMPT.md` section 2 is how the last two OpenVMS SCSI bugs were found (DKDRIVER
off the CD with `tools/ods2.py`, `tools/alphadis.py`, a retire trace). The user's rules: only report
what a test showed; commit small steps locally; never push, never delete files without asking; never
overwrite an installed disk image.

**The job: make the OpenVMS 7.3 install on the board run to the end**, by finding and fixing the two
SCSI problems below. When it is fixed: install 7.3 onto `VMS73_2GB.img`, boot it from `dka0`, log in,
back it up (`OS_INSTALL_RESUME_PROMPT.md` sections 2, 3 and 6 have the steps).

## 1. What the board showed (core `_Unstable/DECAlphaStation200_20261107l.rbf` = `d65633c`, .143)

- **OpenVMS 6.2 installed fine** onto `VMS62_2GB.img` (2026-11-08, 20 min copy, boots from dka0,
  SYSTEM login, a copy checksums equal; backup `VMS62_2GB.installed-20261108.img.bak`), **but** during
  its copy VMS printed `%SYSTEM-I-MOUNTVER, DKA0: is offline. Mount verification in progress.` /
  `... has completed mount verification.` twice, and recovered.
- **OpenVMS 7.3, first try**: `boot dka400` right after an OSD reset, menu option 1, INITIALIZE, DKA0,
  label ALPHASYS, YES → `%INIT-F-MEDOFL, medium is offline`, then `MOUNTVER, DKA400: is offline` /
  `completed`, `%INIT-F-MEDOFL` again, "Installation has been terminated by an unexpected error".
- **Second try (same boot, option 1 again)**: INIT passed, "Creating page and swap files", SYSTEM
  password, no cluster, no Galaxy; `MOUNTVER, DKA0: is offline` / `completed` while it listed the
  products; DECwindows NO, DECnet-Plus NO, Phase IV NO, TCP/IP Services 5.1 YES, SCSNODE AS200,
  no DECnet, SCSSYSTEMID 1025, time zone 34 (UTC), confirm →
  **`%SYSTEM-I-MOUNTVER, DKA400: has been write-locked. Mount verification in progress.`** and nothing
  after it (watched 5+ min; left like that at ~08:45). DKA400, the CD, is the running system disk
  during an install, so the installer is stuck until MVTIMEOUT.
- Also seen on 6.2 (cosmetic, separate row in gaps.md SIO table): every typed line logs a "Local
  interactive login failure ... %LOGIN-F-CMDINPUT" on `_OPA2:`: the PS/2 keystrokes reach the 8242 as
  well as COM1. Not this job.

## 2. The two problems and what is known

**(1) Units drop "offline" now and then, always so far during heavy disk writes** (6.2's copy, 7.3's
INIT, 7.3's page/swap file creation). In VMS, "medium is offline" / MOUNTVER "is offline" means the
unit's I/O failed as offline: a NOT READY answer, or a command timeout and the port driver's bus reset
(then every unit with an outstanding I/O mount-verifies, which fits DKA400 and DKA0 dropping together).
- Our targets (`rtl/scsi/scsi_targets.v`) never answer NOT READY for a disk (the only NOT READY is the
  CD's MEDIUM NOT PRESENT with no image), never disconnect, and hold the bus in DATA phase while they
  wait for hps_io (`sd_busy`, T_FETCH/T_STORE). A bus reset (`brst`) does not post a UNIT ATTENTION.
- Main (`support/decalpha/decalpha_disk.cpp` on the `scsi-consolidated-2-decalpha` branch; read it with
  `git -C ../Main_MiSTer_scsi show origin/scsi-consolidated-2-decalpha:support/decalpha/decalpha_disk.cpp`;
  the board runs that build) buffers writes in 64 KB runs and flushes after 20 ms idle or 500 ms age,
  from Main's single thread. **`/media/fat` on .143 is exFAT on the SD card (`mmcblk0p1`), mounted
  `sync,dirsync`** (checked 2026-11-08), so every flush is a synchronous SD write; 491 MB RAM.
- **Hypothesis, not measured**: an SD write stall (hundreds of ms to seconds) blocks Main, the target
  holds the bus with no REQ, the VMS port driver (PKRDRIVER for the 53C810) times out and resets the bus.
  Unknowns: VMS's timeout(s) (a per-I/O timeout and/or a bus phase timeout), and how long Main really
  stalls.

**(2) After a mount verification the CD is "write-locked" and VMS waits for it to be write-enabled.**
MOUNTVER prints "has been write-locked" when a volume mounted write-enabled gets a write-lock error
(SS$_WRITLCK, e.g. a WRITE answered DATA PROTECT; our CD answers every WRITE with CHECK CONDITION
7/27, `scsi_targets.v` ~line 807). So VMS believed the CD was writable and wrote to it.
- **Suspect: `d65633c`** (2026-11-08), which set the CD's MODE SENSE header device-specific byte to 0
  (was 0x80 = WP, the disks' bit) because 6.2's DKDRIVER refused a non-zero value there at unit init
  (gaps.md OpenVMS row, "Found (2026-11-08)": a differing mode field must be reported changeable). With
  WP clear, 7.3 may mount (or re-verify) the CD system disk write-enabled. Not verified: on 6.2 with this
  core `SHOW DEVICE` gave DKA400 "Mounted wrtlck" at its menu.
- A cheap first check on the board: boot the 7.3 CD, menu option 7 (DCL), `SHOW DEVICE/FULL DKA400`
  ("software write-locked"? "write-locked"?), and compare with the core before `d65633c`
  (`_20261107k` = `84789fd`, still in `_Unstable` on .143; 7.3 reached its menu on `_20261107j` too).
- A fix has to keep 6.2 happy: e.g. WP set in the header *and* reported changeable in the page-control
  01 (changeable) answer, or WP set for 7.3/8.4's MODE SENSE while 6.2's check passes for another
  reason: read 7.3's DKDRIVER for how it decides write-lock (ods2.py the driver off
  `scratch/isos/vms73.iso`) before choosing.

Problem (1) is what makes (2) visible (the mount verification), so fixing (1) may let the install
finish even with (2) open; fix both anyway: (2) hangs any 7.3/8.4 boot from CD that hits one MOUNTVER.

## 3. Ways to get evidence (pick the cheapest first)

1. **VMS's own error log, on the installed 6.2** (cheap, no RTL): copy `VMS62_2GB.img` to a scratch
   image on the board first (`cp`, ~6 min; never write to the `.bak`), boot it (OSD Pri. disk; `boot
   dka0` right after an OSD reset), log in as SYSTEM (password in `scratch/os_credentials.txt`), make
   heavy writes (`COPY` a big file several times, or `BACKUP SYS$SYSTEM:*.* DKA0:[TEST]/...`) until a
   MOUNTVER shows, then `ANALYZE/ERROR_LOG/SINCE=TODAY` (and `/FULL`): the entry says timeout vs. bus
   reset vs. SCSI status/sense, and which command. 6.2's errors are the same family as 7.3's.
2. **Measure the SD card's sync-write stalls on .143**: a small script that writes 64 KB with O_SYNC
   (e.g. `dd if=/dev/zero of=/media/fat/sdlat.tmp bs=64k count=1 oflag=sync,seek_bytes seek=...` in a
   loop with `date +%s%N` around each) into a test file and reports the max latency; ask the user
   before deleting the test file afterwards. Also look for whether Main's stdout goes anywhere
   (`ls -l /proc/$(pidof MiSTer)/fd/1`); a timing printf in `flush_run` needs a Main rebuild (the Main
   worktree `../Main_MiSTer-decalpha` is on the Linux box; on this Windows machine only the remote
   branch is in `../Main_MiSTer_scsi`: ask the user before building or deploying a Main).
3. **Simulator** (WSL, `scratch/simN.sh`, `verilator/system/tb_sys.cpp`): `--disk-lat N` delays every
   block request by N cycles (100 MHz: 1 s = 1e8). Find the delay at which VMS goes offline. Checkpoint
   `scratch/simruns/v9.ck` = 7.3 at its installation menu, written by **`obj_sys_fast5`** (RTL before
   `1dd6c4e`/`84789fd`/`d65633c`: the old CD mode pages, WP set), restored from `v8_7e9.ck`, at cycle
   2.1e10; it was run with `--cd ../scratch/isos/vms73.iso` and no disk. Check in `tb_sys.cpp` whether a
   `--disk0` given at `--restore` is seen by the RTL (the mount handshake happens at start); if not, a
   7.3 boot with `--disk0` from reset on the current RTL (`make -C verilator obj_sys_fast9/Vas200_sys`
   after a fresh N) takes about 2.5 h to the banner at ~0.6 Mcycles/s: save checkpoints
   (`--save-every 1000000000 --ckpt ../scratch/simruns/TAG.ck`). A checkpoint loads only into the
   binary that wrote it. `--type` drives the installer's answers (`--type-at` cycle), `+ccstep=16`
   speeds the idle loops. v9 on fast5 vs. a fast9 run is also the A/B for problem (2) (old vs. new CD
   WP byte), e.g. option 7 and `SHOW DEVICE/FULL DKA400` in both.
4. **The VMS drivers' code**: `tools/ods2.py` pulls `SYS$PKRDRIVER.EXE`, `SYS$DKDRIVER.EXE` (and
   `SYS$PKCDRIVER`) off `scratch/isos/vms73.iso`; `tools/alphadis.py` disassembles. Look for the timeout
   constants and the write-lock decision.

## 4. Fix directions (decide from the evidence; ask the user before any Main or board-config change)

- **Core side, problem (1)**: let a target DISCONNECT while it waits for hps_io and RESELECT when the
  data is there (SCSI-correct, and what a real disk does; VMS's per-I/O timeouts are long, the phase
  timeouts are what a held bus trips). `ncr53c810.v` and the SCRIPTS VMS loads must handle reselection:
  check `docs/design/scsi.md` and `tb_ncr810` before. Bigger change, needs a bench case in
  `verilator/tb/tb_ncr810.cpp` (the 53C810 + targets bench).
- **Main side, problem (1)**: keep the SD stall off the SCSI path (flush in a worker thread, or bigger
  runs/longer idle so flushes happen between commands). The user's Main branches; ask.
- **Board side, problem (1)**: `/media/fat` without `sync` would hide it but is the user's system
  setting and risks the SD on power-off: only with the user's OK, and only as a test.
- **Problem (2)**: the CD's WP reporting (section 2) with 6.2 and 7.3 both passing their unit init:
  re-run 6.2 to its menu (and the installed 6.2 from dka0) after any change.

Every fix: a bench case, a `docs/gaps.md` row, then a fit (`OS_INSTALL_RESUME_PROMPT.md` section 5:
`../DECAlphaStation200_fit`, Quartus 17.0, ~40 min, one fit at a time) and the rbf as
`_Unstable/DECAlphaStation200_20261108<letter>.rbf` (at most two DEC rbfs there; the older to
`/media/fat/rbf_old/`; load on .143 only, the user loads .92).

## 5. Board state at hand-off (2026-11-08 ~09:00)

- .143 runs `_20261107l`, OSD (unsaved): Console SRM, Display Serial console, 128 MB, eth0, Pri. disk
  = `VMS73_2GB.img` (initialized by the failed install: re-initialize it, it holds nothing), CD =
  `OpenVMS 7.3 Alpha.iso`. The 7.3 installer is hung in the DKA400 write-locked mount verification:
  OSD → Apply and reset to get out (the OSD cursor is on its first row).
- Images in `/media/fat/games/DECAlphaStation200/`: `VMS62_2GB.img` + `.installed-20261108.img.bak`
  (md5 a6191d11...), `VMS73_2GB.img` (scratch), NETBSD/NT4/NT4TSE/WIN2K (installed: the user's; do not
  touch), `NT4_stage.img`. Not yet created: `VMS84_4GB.img`, `TRU64_*`, `FREEBSD_*`.
- `bootdef_dev` in SRM's NVRAM is `dka0`.
- Passwords: `scratch/os_credentials.txt` (not in git; don't print them in chat).

## 6. Board helpers (in `scratch/`, not in git; run from Git Bash)

- `ms.sh 'cmd'` ssh to .143 — WSL only: `wsl.exe -d Ubuntu-24.04 -- bash -lc "cd
  /mnt/c/Temp/mistercore/DECAlphaStation200_MiSTer && sh scratch/ms.sh 'sh -s' < scratch/X.sh"` (put
  anything with quotes in a script file and feed it on stdin).
- `k.sh OUT.png KEY...` keys then a screenshot; `ans.sh OUT.png WAIT TEXT` types TEXT (may be ""),
  Enter, waits WAIT s, screenshots; `shot.sh OUT.png WAIT` waits then screenshots;
  `osdboot.sh N "boot dkaX"` from the OSD's first row: Apply and reset, 28 s, then the boot command N
  times 50 s apart (`$TEMP/t<i>.png`). Screenshot paths: `$TEMP` = `C:\Users\spam\AppData\Local\Temp`.
- The tool harness blocks a bare `sleep N; cmd` over ~a minute in the foreground: put long waits in
  `run_in_background` (e.g. `sleep 300; misterkvms-cli ... screenshot`) and act on the notification.
- The SRM P0 failure (an SRM fault dump and restart, or "halt code 5, PC 180000020") hits about every
  other boot from a running SRM: boot right after an OSD reset instead of retrying at `>>>`.
