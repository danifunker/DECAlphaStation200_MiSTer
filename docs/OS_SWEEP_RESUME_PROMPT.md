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

### 2c. The other two OpenVMS CDs on `_20261107j` (2026-11-07, later)

**8.4 boots to its installation menu** (V8.4 banner, date, known files, devices, EWA0, options 1-9;
`scratch/vms84_menu.png`), on the first boot after an OSD reset; the three tries before it from one SRM
session all failed in the P0 way (two "halt code 5, PC 180000020", one "halt code 5, PC 0" right after
"reading 1230 blocks", a variant not seen before). So the install ladder of 2a applies to 8.4 too
(a second blank 2 GB image for it).

**6.2 hangs after its banner**: the old bootstrap ACCVIO was the P0 failure and is gone; now "OpenVMS
(TM) Alpha Operating System, Version V6.2" prints and nothing follows (5 min, no key reaction;
`scratch/vms62_hang.png`). The exec is alive (OSD Advanced "CPU state line": PCs in S0 80015xxx..
800394BC, 13 M instr/s; the CPU exceptions trace shows interrupts, IPL changes, queue CALL_PALs,
MTPR_SIRR). The SCRIPTS trace (OSD Serial port = TGA trace, `scratch/vms62_trace2.log`, tag lines
`E3F01` fetch / `E3F02` interrupt / `E3F03` host write / `E3F04` bus change `{sfbr, bus, state, CDB
opcode}`) shows 6.2's PKR driver cycling the CD through INQUIRY, MODE SENSE(6), READ CAPACITY and TEST
UNIT READY a couple of times a second for ever: SIGP kick, job start (DSP = 1204), a phase-mismatch
interrupt at 54C restarted by the host (a short DATA IN), INT at 11F4, next command. A unit-init retry
loop: one of the four answers (status, sense, or the MODE SENSE page bytes) is one 6.2 rejects and
7.3/8.4 accept. The board ring drops most fetches, so the simulator is the tool: `scratch/simruns/
v62.log` (started 17:45 on 2026-11-07: `sh scratch/sim5.sh v62 --mem 2 +ccstep=16 --cd
../scratch/isos/vms62.iso --cd-ua --type 'boot dka400\n' --type-at 3400000000 --save-every 1000000000
--ckpt ../scratch/simruns/v62.ck --cycles 9000000000`; the banner at ~4.5e9, 2.5 h in) prints every
CDB (`tgt 2 lun 0 cdb ...`) and status (`tgt 2 status xx`): look at the first command whose status is
02 (CHECK CONDITION) or whose answer differs from what 7.3's driver got (`scratch/simruns/v8.log`,
same build, same CD model), fix it in `rtl/scsi/scsi_targets.v` (the CD-ROM command set), bench it
in `verilator/tb/tb_ncr810.cpp` or the SCSI bench, refit. Likely suspects from 6.2-era DKDRIVER: MODE
SENSE(6) page 3F / page 0 with DBD clear (the block descriptor), READ CAPACITY on a CD, INQUIRY's
version/ANSI bytes, or a UNIT ATTENTION that is never cleared.

**Resolved on 2026-11-08 (see gaps.md's OpenVMS row for the full story).** The loop is TUR, INQUIRY,
READ CAPACITY, MODE SENSE page 1 twice and page 1 changeable, all GOOD. 6.2's DKDRIVER (pulled off the
CD with `tools/ods2.py`, read with `tools/alphadis.py`, then a retire trace of it: `scratch/simruns/
v62t_win.txt`, DKDRIVER at FFFFFFFF80230000, its mode-parameter routine at +A5C0, extract +C0D0,
compare +C728) checks mode parameter fields against DEC's wanted values and requires a differing one
to be changeable: page 1 byte 2 wants TB, PER and DTE set (ours 0, nothing changeable) and the
header's device-specific byte 0 (ours 0x80). Fixes `1dd6c4e`, `84789fd` (a mode page store: MODE
SELECTed pages come back as current, all bytes changeable), `d65633c` (device-specific 0 on the CD). **Verified: `_20261107l.rbf` (= `d65633c`) boots 6.2 to its installation menu (`scratch/vms62_menu.png`).**
Two things that were *not* it, proven with DKDRIVER patched in ISO copies run from the 5e9
checkpoint (`scratch/isos/vms62_inqff.iso`, `vms62_rrd45.iso`): the 53C810's phase-mismatch
(underrun) handling and the device table. If a later build still loops: trace again (`--trace FILE
--trace-from N` on a restore, then `grep ' 2000de14'` finds the routine, `awk` the PC range) and look
at which field's compare (OTS routine at FFFFFFFF80017180, called from +C78C) differs.

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
Tru64 4.0G, FreeBSD 4.6 (OpenVMS 6.2, 7.3 and 8.4 all boot to their installation menus, section 2c:
the installs themselves are next, section 2a). Each failure: a bench or T3 case, a fix, `docs/gaps.md`.

## 5. Board and tree state at hand-off

.143 runs `_Unstable/DECAlphaStation200_20261107l.rbf` (`d65633c`: the 6.2 mode page fixes on top of
`4d4c728`), the OSD set (not saved) to Console SRM, Display Serial console, CD = `OpenVMS 6.2
Alpha.iso`, Pri. disk `VMS73_2GB.img` (blank), 128 MB, eth0; it sits at 6.2's installation menu
(2026-11-08). `_Unstable` also has `_20261107k.rbf` (`1dd6c4e`, the 8-byte page 1 alone: still
looped); .92 has `_20261107k` and `_20261107l`. A core load through `/dev/MiSTer_cmd` (`echo load_core
PATH > /dev/MiSTer_cmd` over ssh) comes up in the saved (ARC/NT) configuration: set Console SRM and
Display Serial console in the OSD again before booting.
The OSD's Advanced page: Right does not change a setting, Enter cycles it; from the main page's first
row 11 Downs reach "Apply and reset" (`scratch/vmsboot.sh N` does that and N boot tries).
Simulator: `scratch/simruns/v8.log`/`v9.log` = a VMS boot from reset in
`obj_sys_fast5` (the fixed core; stage 2 types the date from the 7e9 checkpoint), started 15:50 on
2026-11-07, for a regression check and as a base for later checkpoints; `v62.log` = the 6.2 boot with the loop, `v62x.log` (`obj_sys_fast8` = `d65633c`, started 00:35 on
2026-11-08, `--save-at 5e9 --ckpt v62x_5e9.ck`) = the same boot on the fixed core, for a checkpoint
past the loop. The simulator helpers: `scratch/simN.sh TAG ARGS` (N = the obj_sys_fastN binary),
`scratch/simps.sh` lists the running ones. Core loads: OSD only (`scratch/k.sh OUT.png
keys...` sends keys over misterkvms-cli and screenshots; System page → Core → the rbf list). Fits: Quartus
17.0 on this Windows machine in `../DECAlphaStation200_fit` (`git -C ../DECAlphaStation200_fit checkout
--detach <commit>`, then `quartus_sh --flow compile DECAlphaStation200` from PowerShell; ~40 min), the
rbf to the boards with a copy of `scratch/push_e.sh` (bump the letter; at most two DEC rbfs in
`_Unstable`, older ones to `rbf_old`). Verilator runs in WSL (`wsl.exe -d Ubuntu-24.04 -- bash -lc "cd
/mnt/c/... && sh scratch/sim4.sh TAG ARGS"`; `sim3.sh` = the old `obj_sys_fast3`, which still loads
`v3_6e9.ck`/`vA.ck`). All commits local (`183e772` at hand-off); nothing pushed.
