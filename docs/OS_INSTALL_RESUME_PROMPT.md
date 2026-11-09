# Resume prompt: install the operating systems — state on 2026-11-08

Paste this into a new session (Opus). Read `CLAUDE.md`, then `docs/gaps.md` (the OS table, the TGA and
SCSI tables, the "SRM boots: the first console open fails" row), then `docs/OPUS_RESUME_PROMPT.md`
section 1 (the survey plan and the user's rules for images and backups, all still in force).
`docs/OS_SWEEP_RESUME_PROMPT.md` is the previous hand-off: the diagnoses of the two OpenVMS bugs and
the simulator method, for when an install hits a new bug. The user's standing instruction: keep working
on the plan independently, get the operating systems installed and booting from disk. Only report what a
test showed; never push or delete without asking; commit small steps locally.

## 1. Where the sweep stands

Every SRM OS on the list now boots from its CD to its installer on the current core:

| OS | CD boots to | Installed? | Disk image |
|---|---|---|---|
| NetBSD 10.2 | sysinst | **yes** (2026-11-06), boots from `dka0` to `login:` | `NETBSD_2GB.img` (+ `.installed-20261106.img.bak`) |
| OpenVMS 7.3 | installation menu (options 1-8) | **yes** (2026-11-08), boots from `dka0`, SYSTEM login, copy checksums equal | `VMS73_2GB.img` (+ `.installed-20261108.img.bak`) |
| OpenVMS 8.4 | **installed 2026-11-08** (65 min, all products, TCP/IP; one CD MOUNTVER, recovered). Its first boot died in `CDSA-I-InitCDSA` with an ACCVIO until the core stopped faulting on `lds $f31` prefetches (`3a74a68` = `_20261108c.rbf`); on that build the first boot ran CDSA, AUTOGEN and its own reboot | **yes** (2026-11-08), boots from `dka0` (`bootdef_dev` set), SYSTEM login, SHOW DEVICE clean | `VMS84_4GB.img` (+ `.installed-20261108.img.bak` pre-boot, `.firstboot-20261108.img.bak` after the clean shutdown) |
| OpenVMS 6.2 | installation menu (options 1-5) | **yes** (2026-11-08), boots from `dka0`, SYSTEM login | `VMS62_2GB.img` (+ `.installed-20261108.img.bak`, `VMS62_scratch.img` spare) |
| Tru64 UNIX 4.0G | not tried on the current core | no | to create: `TRU64_2GB.img` (4 GB if the base system won't fit) |
| FreeBSD 4.6 | not tried on the current core | no | to create: `FREEBSD_2GB.img` |

**Backups (ZIPs), 2026-11-08**, on the Windows machine. Each ZIP holds the image, `AS200.nvr` and
`README.txt`. The NVR is a copy of the board's `AS200.nvr` (8192 bytes, md5 `c759873ca71f37d71f8dd8c99bc3cd9b`,
SRM `bootdef_dev` dka0). The README gives the OSD settings (128 MB, Console SRM, Display Serial console),
the boot command, the licence state (no PAKs) and the core build, and says where the SYSTEM password is
kept. Image md5s are equal on the board and in the copy.

| ZIP | Image (md5) | ZIP size, md5 |
|---|---|---|
| `C:\temp\VMS62_2GB_20261108.zip` | `VMS62_2GB.img` (`a6191d114003ab2ff5508da1c52f90a1`) | 66,277,366 bytes, `ca23109a1bcbd40fb339a672ea334939` |
| `C:\temp\VMS73_2GB_20261108.zip` | `VMS73_2GB.img` (`04f09b5a5ec2f72308710dc80a1351ef`) | 231,326,475 bytes, `72f6d2ae775721cee8ba9ddcf873378b` |
| `C:\temp\VMS84_4GB_20261108.zip` | `VMS84_4GB.img` (`d9a6c64707e5f35d2c1a45e08f1134c2`), taken after the first boot and a clean shutdown at 19:13 (a copy made while 8.4 was running and writing was discarded) | 228,000,814 bytes, `dbf467abddcea28d8a3b4b49a19f0980` |

All the ISOs are in `/media/fat/games/DECAlphaStation200/` on .143 (`OpenVMS 7.3 Alpha.iso`, `OpenVMS 8.4
Alpha.iso`, `OpenVMS 6.2 Alpha.iso`, `Tru64 UNIX 4.0G.iso` + Associated Products 1/2 + Documentation,
`FreeBSD4.6-RELEASE_Alpha-disc1.iso`/`disc2`). 91 GB free there. NT 4.0 (`NT4_2GB.img`) and Windows 2000
(`WIN2K_2GB.img`) are installed and are the user's; `NT4TSE_2GB.img` is the Terminal Server image to
re-check later (its last state was a hang at the kernel banner, from before several CPU fixes).

The work is **the installs themselves**, in this order: Tru64, FreeBSD (OpenVMS 8.4, 7.3 and 6.2 are done; the hps_io stall behind the `MOUNTVER ... is offline` messages is fixed on both sides since `_20261108a` + Main `decalpha-writer`, `docs/FABLE_VMS73_SCSI_RESUME_PROMPT.md`), and for
each the rest of the ladder: boot from disk, log in, the disk (a copy and a checksum), the network
(EWA0: DHCP, ping the router), graphics (`set console graphics` where the OS has a TGA driver: NetBSD
and Tru64 do, OpenVMS has DECwindows on the ZLXp-E, FreeBSD 4.6 has none). `docs/gaps.md`'s OS table
records each rung; a new install image is backed up as `<name>.installed-<yyyymmdd>.img.bak` right after
the install. Licence PAKs (OpenVMS past the basic login, Tru64) are the user's: ask.

## 2. The board procedure (.143, core `_Unstable/DECAlphaStation200_20261107l.rbf` = `d65633c`)

Check first that the user isn't using .143 (`ls -la` on the images; `ps | grep MiSTer` shows the
running rbf). Tools from this Windows machine, all in `scratch/` (they are not in git, they are in the
tree): `scratch/ms.sh 'cmd'` = ssh to .143 (works from WSL only: `wsl.exe -d Ubuntu-24.04 -- bash -lc "cd
/mnt/c/Temp/mistercore/DECAlphaStation200_MiSTer && sh scratch/ms.sh 'cmd'"`; from Git Bash the same
script works when ssh and the key are in Git Bash's `~/.ssh` — try it), `scratch/k.sh OUT.png KEY...`
sends keys through misterkvms-cli and takes a screenshot, `scratch/vmsboot.sh N` = from the OSD main
page's first row: Apply and reset, wait 28 s, then N `boot dka400` tries 50 s apart with a screenshot
each (`$TEMP/tN.png`). misterkvms-cli itself: `C:\Temp\mistercore\MiSTerKVMS\target\release\misterkvms-cli.exe
--mister 192.168.99.143 {status|screenshot OUT.png|key K|type TEXT|wait-for-change}`.

1. **Create the disk image** on the board: `dd if=/dev/zero of=/media/fat/games/DECAlphaStation200/VMS84_4GB.img
   bs=1M count=4096` (exFAT: no sparse files, so dd, about 1 min per GB). Never reuse a blank image for
   two OSes; never overwrite an installed one.
2. **Load the core if needed**: `echo load_core /media/fat/_Unstable/DECAlphaStation200_20261107l.rbf >
   /dev/MiSTer_cmd` over ssh (misterkvms-cli `load-core` from Git Bash mangles the path). It comes up in
   the *saved* configuration (ARC, for NT), so:
3. **OSD** (F12; screenshot before every Enter — the OSD reopens on the page it was closed on, and
   Enter opens a selector on a file row but cycles the value on an option row). Main page rows from the
   top: Pri. disk (ID 0), Disk ID 1, CD-ROM (ID 4), Floppy, Load ROM, Memory, Network, Machine, Video,
   Input, Advanced, Apply and reset. Mount the image on Pri. disk and the ISO on CD-ROM; Memory 128 MB
   (8.4 wants it); Machine page: Console = SRM (needs Apply and reset); Video page: Display = Serial
   console (applies live; the TGA takes over HDMI once an OS driver attaches it and stays black while
   the console is on COM1 — that was NetBSD's "hang"). Then Apply and reset.
4. **Wait ~30 s** for `>>>` (typing earlier drops characters: `bootdka400`), then `boot dka400`. **The SRM
   P0 failure** ("halt code 5, PC 180000020", or `***` garbage and "kernel stack not valid halt", or
   "cb_open: failed , Can't open /boot") hits about every other boot *from a running SRM*; the first boot
   right after an OSD reset passes nearly always. So: boot right after a reset, and on failure reset
   again (OSD, Apply and reset) rather than retrying at the prompt. gaps.md has the diagnosis so far
   (SRM's packed stack frame, the UNALIGN trap inside a callback); it is not this session's job unless it
   blocks the installs.
5. **Watch the screen**: `screenshot` every minute or so, or `wait-for-change`. The serial console shows
   on HDMI (the vterm). Type answers with `type` + `key Enter`.
6. After an install: shut the OS down cleanly, `boot dka0` (VMS: also `set bootdef_dev dka0` so a plain
   `boot` works; NetBSD multi-user: `boot dka0 -fl a`), then the backup copy with `cp` on the board.

ARC is **not** involved: it is NT's firmware. Everything in the table boots from SRM.

## 3. Per-OS notes

**OpenVMS 7.3** (first). `boot dka400` → banner → the date prompt (`DD-MMM-YYYY HH:MM`, e.g. `08-NOV-2026
10:00`) → "Installing required known files", "Configuring devices" → the menu. Option 1 (Upgrade,
install or reconfigure), INITIALIZE (not PRESERVE) on DKA0, a volume label (e.g. `ALPHASYS`), the
SYSTEM password, SCSNODE/SCSSYSTEMID (any; `AS200`, `1025`), no DECnet unless asked, register PAKs: no
(later), time zone, the product list: take the minimum (say NO to DECwindows/DECnet options unless the
user wants them), then it copies for a long time (the disk runs about 1 MB/s through hps_io; a real
AS200 installed 7.3 in ~1 h, so expect a few hours: keep a screenshot every 10 min to see it move).
When it ends it offers to shut down; then `boot dka0`, the AUTOGEN reboot(s), `Username: SYSTEM`.
The install itself has never been run on this core: a hang or a %SYSTEM-F error here is new ground
(section 5).

**OpenVMS 8.4**: the same, 4 GB image, 128 MB (it checked out to its menu on 2026-11-07 with 128 MB).
Its menu has options 1-9. Expect it to be slower than 7.3 (more to copy).

**OpenVMS 6.2**: the same, 2 GB, menu options 1-5. Its DKDRIVER is the one that checked the CD-ROM's
mode pages at unit init (fixed 2026-11-08); the *disk's* mode pages at install time run through the
same check with the direct-access values (page 1 default 12 bytes, write-protect bit allowed in the
header for disks: left as is on purpose). If 6.2 loops on dka0 the way it looped on dka400, the fix is
the same kind (`rtl/scsi/scsi_targets.v` mode page store; OS_SWEEP_RESUME_PROMPT section 2c says how
the wanted values were read out of DKDRIVER).

**Tru64 UNIX 4.0G**: `boot dka400` boots the installation kernel (its console messages; a TGA driver is
in the kernel, so the console goes to the HDMI picture when Display = TGA, or stays on COM1 with
Display = Serial console). Minimum install, one disk, `dsk0`; swap on the same disk is what it insists
on (the fewest partitions it allows: a, b swap, g). 2 GB may be too small for the base system with
the mandatory subsets: make it 4 GB if the installer says so. It will want the Associated Products CDs
only for optional subsets: skip them. Licence PAKs for the OS: ask the user (the OSF-BASE PAK). Not
booted on any core since the SIGP fix (`2925f2b`), so the first run is a plain "does the CD boot".

**FreeBSD 4.6**: `boot dka400` (SRM); sysinstall, 2 GB, one root slice plus swap. Disc 2 only if asked.
The alpha port's kernel has siop/ncr, de (21040 as `de0`), no TGA driver (console stays on COM1).

**NetBSD 10.2** (installed): re-check on the current core: `boot dka0 -fl a`, login, a copy and a
checksum on the disk, DHCP + ping; then `set console graphics` and the TGA console (gaps.md: not tried).

## 4. If an OS boots from disk but the picture is wrong, or the TGA console

The TGA method (traces, replay, `tools/tgareplay.py --ideal`, the OSD Serial port = TGA trace) is in
`docs/FABLE_RESUME_PROMPT.md` and the TGA rows of gaps.md. The TGA is 8 bpp only (the ZLXp-E1); 32 bpp is
the user's open wish, not this session's work.

## 5. If an install hangs or faults: the method that found the last two bugs

The board tells you where (OSD Advanced page: the "CPU state line" shows PCs and instructions/s; the
Serial port setting selects a trace onto the vterm/ttyS1: TGA trace, CPU exceptions, with
`scratch/trace_start.sh`/`trace_stop.sh OUT.log`), the simulator tells you why. Both OpenVMS bugs were
driver-visible SCSI behaviour, found by a retire trace of the OS driver: `make -C verilator
obj_sys_fastN/Vas200_sys` (a fresh N keeps a binary that can load its own checkpoints), `scratch/simN.sh
TAG --mem 2 +ccstep=16 --cd ../scratch/isos/vms73.iso --cd-ua --type 'boot dka400\n' --type-at
3400000000 --save-every 1000000000 --ckpt ../scratch/simruns/TAG.ck --cycles N` in WSL (about 0.6
Mcycles/s: the VMS banner at ~4.4e9 is 2 h in; a 7.3 install in the simulator is days — the simulator is
for the first minutes after a reproducible event, from a checkpoint, with `--restore F --trace FILE
--trace-from N`, then `tools/tracedis.py`, `tools/alphadis.py`, `tools/ncrdis.py`, and `tools/ods2.py`
to pull a driver image off a VMS CD or disk image). Checkpoints that exist: `scratch/simruns/v9.ck`
(7.3 at its menu, `obj_sys_fast5`), `v62x_5e9.ck` (6.2 before its drivers load, `obj_sys_fast8` =
the current RTL), `v6.ck` (`obj_sys_fast4`). A checkpoint loads only into the binary that wrote it;
`scratch/simps.sh` lists running sims. The simulator can mount a disk image too (`--disk0 IMG`, `--disk1`; the option list is in
`verilator/system/tb_sys.cpp`), so an install's first minutes against a blank image are
reproducible there if the board shows a deterministic early failure.

Fixes go with a bench case (`verilator/tb/tb_ncr810.cpp`, `tb_scsi`, or a T3 CPU test in `tests/cpu/`),
a gaps.md row, then a fit: Quartus 17.0 on this Windows machine in `../DECAlphaStation200_fit` (`git -C
../DECAlphaStation200_fit checkout --detach <commit>`, then `quartus_sh --flow compile
DECAlphaStation200` from PowerShell, ~40 min, one fit at a time; the last fit: 36.5k ALMs (87%),
−1.47 ns at 100 MHz, runs regardless), the rbf to both boards as `_Unstable/DECAlphaStation200_<yyyymmdd><letter>.rbf`
(copy of `scratch/push_j.sh`, bump the letter; at most two DEC rbfs in `_Unstable`, older to
`/media/fat/rbf_old/`), loaded on .143 only (the user loads .92 themself).

## 6. State at hand-off (2026-11-08, early morning)

- .143: `_20261107l.rbf` running, OSD (unsaved) Console SRM, Display Serial console, CD = `OpenVMS 6.2
  Alpha.iso`, Pri. disk = `VMS73_2GB.img` (blank), 128 MB, eth0; sitting at 6.2's installation menu
  since ~01:00. `_Unstable` holds `_20261107k` and `_20261107l` (.92 the same, not loaded there).
  Swap the CD to 7.3 and reset before starting the 7.3 install; do not take option 1 from 6.2's menu
  onto `VMS73_2GB.img`.
- Tree: `master` at `8224233` (`d65633c` is the RTL), all local, nothing pushed. Simulator: `v9.log`
  (7.3 to its menu on the fixed targets, no regression) and `v62x.log` (6.2 to the date prompt on
  `d65633c`, 3 MODE SENSEs instead of a loop) both finished; nothing running.
- Open bugs touching this work: the SRM P0 boot failure (intermittent; reset before each boot); the
  TGA console `boot dka0` after a clean NetBSD halt (gaps.md NetBSD row); `ERROR: scancode 0xfa/0xaa not
  supported on PCXAL` after a failed boot (cosmetic).
