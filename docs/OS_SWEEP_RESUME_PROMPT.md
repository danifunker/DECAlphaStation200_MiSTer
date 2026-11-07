# Resume prompt: the OS sweep after the SCSI fix — state on 2026-11-07

Paste this into a new session. Read `CLAUDE.md`, then `docs/gaps.md` (the SCSI table's SIGP row, the OS
table, the "SRM boots: the first console open fails" row), then `docs/OPUS_RESUME_PROMPT.md` (the survey
plan and its rules, still in force). `docs/SRM_BOOT_RESUME_PROMPT.md` is the previous hand-off: its
section 3 (the OpenVMS SCSI stall) is solved, its sections 2, 4 and 5 (the SRM P0 failure, the tools, what
was ruled out) still apply. The user's standing instruction: keep working on the plan independently, get
the operating systems to boot. Only report what a test showed.

## 1. What changed on 2026-11-07

**The OpenVMS 7.3 SCSI stall was the 53C810 model, not the target or the driver** (`2925f2b`,
`rtl/scsi/ncr53c810.v`): ISTAT.SIGP was cleared only by a *host* read of CTEST2. Every 53C8xx driver's
idle loop leaves `WAIT RESELECT` on SIGP and clears the signal with `MOVE CTEST2 TO SFBR` (OpenVMS PKR,
Linux ncr53c8xx/sym, NetBSD siop). With SIGP stuck, VMS's SCRIPTS went round the idle loop again the
moment the INQUIRY finished and **re-ran the finished job's table** (SELECT ATN + identify + SDTR to the
CD a second time) before the driver had queued anything; the driver found no current request at
`INT 0x31`, logged a stray interrupt, restarted the idle loop at 12D4 while still connected with ACK
held, and its real next request did SELECT while connected and hung. The "second SDTR" in the old logs
was that replay. Found with a retire trace of the driver's ISR: `scratch/simruns/vB_isr1.txt` (the good
first handling) and `vB_isr4.txt` (the stray one; the branch at FFFFFFFF8037B644 reads the port's
current-request pointer, port+0x1EC). The "selection while connected is lost" row is a consequence
(P3 now).

Board `_20261107e.rbf` (`2925f2b`, 36.1k ALMs, -1.832 ns at 100 MHz, runs regardless): **OpenVMS 7.3
`boot dka400` now reaches the installer**: banner, date/time prompt, "Installing required known
files...", then a deterministic ACCVIO (section 2). NetBSD was not re-run on this build.

Tools added: `tools/ncrdis.py` (53C810 SCRIPTS disassembler from a checkpoint's `.mem`; the `.mem` has a
16-byte header, so `--at` = PA + 16; PKR's SCRIPTS are PA 0x1056000 = PCI 0x01000000, listing in
`scratch/simruns/vms_scripts.txt`), `tools/tracedis.py` (annotates `tb_sys` retire traces with the
disassembly; `--from LINE -n N --pc LO HI --grep RE`), `make -C verilator obj_sys_fastN/Vas200_sys`
(any N: a fast build under its own name, so a checkpoint keeps a binary that loads it), and the
`NCR_TRACE` host-read log, which now actually prints (`ncr host read RR be X -> value`).

How the trace was taken (reusable for any OS bug in the simulator): run the fast model with
`--save-every 20000000 --ckpt X.ck`, watch the log for the event, kill the run; restore the last
checkpoint with `--trace T --cycles N` (a few 1e7 cycles make a 2-4 GB trace); find the event in the
trace by a store of a known value (`grep -n '=00000000010012d4/4'`), then `tracedis.py --from`.

## 2. OpenVMS 7.3's installer ACCVIO: solved later on 2026-11-07 (`4d4c728`)

The core ignored RWC (ir[13], read with write check) on HW_LD. OpenVMS's PALcode implements PROBEW
with `hw_ld/ar` (ALT mode + RWC); DCL's user-mode half probed its supervisor-stack frame for user
write, got "yes", stored, and the DTB (rightly) took ACV. Found with the simulator: `scratch/simruns/
v6.ck` (7.30e9 cycles, just before the fault, loads into `obj_sys_fast4`), the traced replay
`v7.trace`, `v7_fault.txt` / `v7_pre.txt` (tracedis output). `tests/cpu/t3_rwc.py` (`make -C verilator
t3-rwc`, alphaasm, no binutils needed) fails on the old core. **Board `_20261107j.rbf` (`4d4c728`):
`boot dka400` reaches the OpenVMS installation menu** (option 1 Upgrade/install ... 8 Shut down). The
rest of this section is the history of the diagnosis; skip to section 3.

The dbg_trace additions made on the way (all in `rtl/mister/dbg_trace.v`, OSD Serial port = CPU
exceptions): the `E01E0` D_FAULT line now carries the faulting instruction, MM_CSR and the matching DTB
entries' protection; `E3D00` lines for PAL writes of PS that enter or leave a non-kernel mode (old and
new PS byte); the ring freezes at a D_FAULT inside retire window 0 (set `RT_LO0/HI0` on the fault under
study; the next change of the OSD Serial port thaws it). The simulator remains the better tool once a
checkpoint near the event exists.

### 2a. The next step for VMS: the install itself

Mount `VMS73_2GB.img` on the OSD's Pri. disk slot (ID 0), Console SRM, Display Serial console, boot
dka400 (right after a reset: the SRM P0 failure, section 3, hits about every other boot), enter the
date, take option 1, target DKA0. Then backup `VMS73_2GB.installed-<date>.img.bak`, boot from dka0,
and the rest of the ladder (login, the SCSI disk, EWA0, the TGA). Licence PAKs: ask the user.

### 2b. History of the diagnosis (for reference)

Board, three runs, identical (before the fix): after "Installing required known files...":
`%SYSTEM-F-ACCVIO, access violation, reason mask=04, virtual address=000000007FFAC4B0,
PC=000000007FE96B50, PS=0000001B`, "Improperly handled condition, image exit forced", the SYSTEM job
terminates. Registers in `docs/gaps.md` (OS table). VA and PC are in P1 space (7FExxxxx: the installed
images; 7FFAC4B0 near the stack/PIO area); reason mask 04 is a bit VMS sets from the PAL's MM_CSR, so
check first what our D_FAULT reports: `docs/design/cpu.md` 5.3 (VA/MM_CSR), `rtl/cpu/ev4_core.v`
(`m2_fb`, `dtb_for/dtb_fow`). VMS, unlike NT and NetBSD, uses the PTE FOR/FOW/FOE bits for its working
set and modify tracking, and its condition handler reads the reason mask; a wrong MM_CSR (e.g. FOR
reported with ACV, or the WR bit) would produce exactly an "access violation" on a legal page.

Plan:
1. Simulator: `scratch/simruns/v5.log` is a boot of VMS 7.3 from reset in the fixed `obj_sys_fast4`
   (`sh scratch/sim4.sh v5 --mem 2 +ccstep=16 --cd ../scratch/isos/vms73.iso --cd-ua --type 'boot
   dka400\n' --type-at 3400000000 --save-every 1000000000 --ckpt ../scratch/simruns/v5.ck --cycles
   12000000000`, started 10:45 on 2026-11-07, about 0.5 Mcycles/s, so the banner at ~4.4e9 is 2.5 h in and
   the installer some time after; the `v5.ck` checkpoint is the last 1e9 boundary). If it reaches the
   ACCVIO, restore the previous checkpoint with `--trace-pc 0x7FE96B00 0x7FE96B60` to catch the faulting
   retire and `--trace-pc 0x01E0 0x0280` for the PAL's D_FAULT/DTB_MISS entries (VMS PAL_BASE: read
   PAL_BASE in the trace; the SRM/VMS PALcode is DEC's), with the MM_CSR/VA values (`hw_mfpr` results).
   If the simulator doesn't reach it, the board trace is the way: `dbg_trace.v`'s retire windows
   (`RT_LO0/HI0`) on 7FE96B00..7FE96B60 and the PAL D_FAULT entry, OSD Serial port = CPU exceptions,
   `stty -F /dev/ttyS1 921600 raw -echo clocal -crtscts; cat /dev/ttyS1` on the MiSTer.
2. Fix in the RTL with a T3 CPU test (`tests/cpu/`, `make -C verilator cputest-pipe`), refit, re-run.
3. Then continue the installer: VMS asks for the date, then its menu (install to `VMS73_2GB.img` on ID 0:
   mount it on the Pri. disk slot first; the blank image exists on .143). Backup after the install
   (`VMS73_2GB.installed-<date>.img.bak`). Licence PAKs past the basic login: ask the user.

## 3. The SRM P0 failure (still open, intermittent)

Unchanged from `docs/SRM_BOOT_RESUME_PROMPT.md` section 2: in this session 3 of 5 `boot dka400` tries
from the same SRM failed (two "halt code 5, PC 180000020"; one with SRM's text garbled with `***`,
"kernel stack not valid halt, PC 1010e398" and an ACCVIO through vector 80 in the VMS bootstrap, as
OpenVMS 6.2 showed before), and the first boot after an OSD reset passed. So: **always boot right after
a reset** (OSD Apply and reset), and retry on failure. After a failed boot SRM prints `ERROR: scancode
0xfa/0xaa not supported on PCXAL` (the 8242 passes the keyboard's ACK/BAT bytes to SRM's driver): minor,
noted in gaps.md. The SIGP bug does not touch SRM (its pke SCRIPTS have no WAIT RESELECT).

## 4. Then the rest of the sweep (OPUS_RESUME_PROMPT section 1)

NetBSD 10.2 (installed, `NETBSD_2GB.img`; re-check `boot dka0 -fl a` on the new build and the P0 rate),
OpenVMS 6.2 (its bootstrap ACCVIO, PC 20005034, may be the same P0 family), OpenVMS 8.4, Tru64 4.0G,
FreeBSD 4.6. Each failure: a bench or T3 case, a fix, `docs/gaps.md`.

## 5. Board and tree state at hand-off

.143 runs `_Unstable/DECAlphaStation200_20261107e.rbf` (`2925f2b`), the OSD set (not saved) to Console
SRM, Display Serial console, CD = `OpenVMS 7.3 Alpha.iso`, Pri. disk `NETBSD_2GB.img`, 128 MB, eth0; it
sits at the installer's ACCVIO. `_Unstable` also has `_20261107d.rbf` (`3d4a006`, the debug-window
build); .92 has `_20261106.rbf` and `_20261107e.rbf`. Core loads: OSD only (`scratch/k.sh OUT.png
keys...` sends keys over misterkvms-cli and screenshots; System page → Core → the rbf list). Fits: Quartus
17.0 on this Windows machine in `../DECAlphaStation200_fit` (`git -C ../DECAlphaStation200_fit checkout
--detach <commit>`, then `quartus_sh --flow compile DECAlphaStation200` from PowerShell; ~40 min), the
rbf to the boards with a copy of `scratch/push_e.sh` (bump the letter; at most two DEC rbfs in
`_Unstable`, older ones to `rbf_old`). Verilator runs in WSL (`wsl.exe -d Ubuntu-24.04 -- bash -lc "cd
/mnt/c/... && sh scratch/sim4.sh TAG ARGS"`; `sim3.sh` = the old `obj_sys_fast3`, which still loads
`v3_6e9.ck`/`vA.ck`). All commits local (`183e772` at hand-off); nothing pushed.
