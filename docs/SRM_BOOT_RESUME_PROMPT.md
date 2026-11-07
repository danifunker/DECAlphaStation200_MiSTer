# Resume prompt: SRM OS boots (NetBSD, OpenVMS, FreeBSD) — state on 2026-11-07

Paste this into a new session. Read `CLAUDE.md`, then `docs/gaps.md` (rows "SRM boots: the first
console open fails", "SCSI target: a selection ... lost", the OS table), then
`docs/OPUS_RESUME_PROMPT.md` (the survey plan and its rules, still in force). The user's standing
instruction: keep working on the plan independently, get the operating systems to boot.

Only report what a test showed. The previous session announced and then retracted many causes
(listed in section 5); don't repeat them.

## 1. Where things stand

| OS | Media | State |
|---|---|---|
| Windows NT 4.0 / TSE | ARC | Installs and runs; sound works (`0640b37`). Not affected by any of this. |
| NetBSD 10.2 | `NETBSD_2GB.img` on .143 (installed, DHCP and ping checked) | `boot dka0 -fl a` from SRM fails in long runs of bad boots; it booted to multi-user earlier. **P0 below.** |
| OpenVMS 7.3 | `vms73.iso` CD | Same SRM failure on the board. When it gets past it: banner, then a SCSI stall (section 3). Reproduced in simulation. |
| OpenVMS 6.2 | CD | Access violation in the bootstrap: PC 20005034, R16 20115FF9, R18 20115FFF. Not looked at again. |
| FreeBSD 4.6 | `FreeBSD4.6-RELEASE_Alpha-disc1.iso` CD | Same SRM failure (halt, PC 180000020 after "Memory: 131072 k"). |
| OpenVMS 8.4, Tru64 4.0G | | Not tried. |

## 2. P0: the SRM boot failure (first console open)

**Symptom.** After "jumping to bootstrap code", the bootstrap's first `prom_open` comes back with no
error flag and the caller's stale R0 as the channel (0x1604); the next read takes it for a file
(fread 4AF58, UNALIGN at 4AFA4/4AFB8 on VA 1634), then a run through memory ending in
"halt code 5, PC = 180000020". A second mode: cb_open returns its failure properly
("cb_open: failed , / Can't open /boot. / PRIMARY BOOTSTRAP FAILED!"); seen after `sleep 100000 &`.

**What the board traces showed (builds `8e21772` .. `3d4a006`, OSD Serial port = CPU exceptions).**
- SRM's cb_open is 3F430 (callback table CF408 + 4 x (code-1), 32-bit PDs, PD+8 = entry; open 0x10
  PD E3900, read 0x13 PD E3840 entry 3FB48). With no channel open it restarts the drivers
  (bsr 49910(2,0), 77F88, 55458, 49910(3,0), 86868(2)); then fopen("vmem","sr") to read the name, then
  fopen(name,"psr") up to 4 times with 500 ms sleeps.
- In failing runs cb_open goes into the driver restart (bsr 49910 at 3F4C4) and never returns to cb_open.
  During the restart SRM's `remque` (6B920) takes an unaligned trap at 6B92C on VA 29A96; the next
  thing that runs is the bootstrap calling the read callback (fopen called from 3FBB0).
- 0x00029A92 is **not** a corruption (write watch `a5a6645`): SRM's shell (function 78620, PD EF0B8,
  strings "child_done", ">>>") runs `boot` as a child process (78D40 path, krn$ create at 68688) and
  waits on a `child_done` semaphore in its own stack frame at gp+170, 2 bytes off alignment (DEC's
  packed struct: ldq_u/extll at gp+146/150/153). Semaphore init is 71418 (called from 78DA8 with
  a0 = 0x29A8A); its queue links at +8 (0x29A92) go on SRM's global semaphore queue (insque 6B870,
  remque 6B920).
- DEC's PALcode (PAL_BASE 0x8000, UNALIGN entry 91E0) fixes unaligned loads and stores itself. After
  the fixup it tests PAL_TEMP2 (IPR 0x82) bit 46: set (console context) → `hw_rei`, silent; clear
  → D300: also reports through SCB vector 0x280. On the board the trap at 6B92C inside the callback is
  followed by the bootstrap resuming (the callback aborted).
- The entry removed by the faulting remque sits just before `child_done` in the queue. The sleep test
  (`sleep 100000 &` before `boot`) did not cure it and gave the second mode.
- **The good simulated boot takes the same traps and survives them** (`scratch/simruns/s2.trace`,
  `--trace-pc 0x91e0 0x9200` on the UNALIGN entry; the `hw_mfpr t3,0x24` result is EXC_ADDR): 258
  unaligned traps during `boot dka0 -fl a`, 117 at 6B92C (remque), 112 at 6B888 (insque), the shell's
  71460..71480 and 6B870..6B884 once each, and NetBSD reaches its secondary bootstrap. So the misaligned
  semaphore and its traps are normal. **What differs on the board is what happens after the trap**: the
  PAL's path (PAL_TEMP2 bit 46 tested at 92CC and D2C8, then D300 → 98C0 with SCB offset 0x280) and
  where that dispatch lands. This is the strongest lead.
- The earlier memory-test lead (62D00, PD EA868) was wrong: that is SRM's power-up memory test, and
  it only showed up because the traces included the post-crash re-init.

**Simulation does not reproduce it.** NetBSD boots past the open in the system simulator with
`+ccstep=16`, with board-speed delays (`--ccstep 1` after `--restore`), and with 3 ms disk latency
(`--disk-lat 300000`).

**Next steps, in order.**
1. Follow the PAL's unaligned path after the fixup, in the simulator and on the board: retire windows
   on 9298..9300, D2C8..D330 and from 98C0 (set RT_LO/RT_HI in `dbg_trace.v` and refit; in the
   simulator `--trace-pc`). Find who sets and clears PAL_TEMP2 bit 46 (`hw_mtpr ...,0x82` in the PAL and
   in SRM's callback entry and exit) and why it is clear on the board at the trap but harmless in the
   simulator. Check our side too: PAL_TEMP2 kept as 64 bits, EXC_ADDR, MM_CSR (opcode, register) and VA
   as the 21064 reports them for these stl/ldl traps, and HW_REI.
2. If the PAL path is the same, find the board-only cause: the processes and semaphores created between
   power-up and `boot`. Candidates not yet tested: the network driver (ewa0 polling; but Network None also failed),
   the TGA/keyboard drivers (Display = Serial console on the board, graphics in the sim?), the
   NVRAM contents (the board shows "TIMER_TPS environment variable invalid" on every power-up now),
   timer/interrupt timing.
3. Decide with the user before changing any firmware behaviour; a hardware fix is preferred.

## 3. OpenVMS 7.3 SCSI stall (reproduced in simulation)

Simulation runs: `scratch/simruns/vms1.log` (stock fast build, checkpoint `vms1_6e9.ck` for that
binary only) and `v3.log` (build `obj_sys_fast3` with host register logging: `ncr host write/read`,
`ncr bus` lines). OpenVMS's banner at about 4.4e9 cycles, PKR driver from about 6e9.

What happens (CD = ID 4, target slot 2): an INQUIRY completes; then `SELECT ATN` of ID 4 with
identify + SDTR (MSG_OUT 6 bytes), the target answers with an extended message, the script stops with
`INT 0x31` and **ACK held, still connected** (ISTAT 0x28 = SIGP|CON). The driver restarts the script at
12D4 (`WAIT RESELECT`), SIGP takes the alternate path to 1578 → 0DE8 → `SELECT ATN` at 1B4 while still
connected, `JUMP WHEN MSG_OUT` at 1BC waits forever, and the driver aborts (DSTAT 0x10, ISTAT 0x88).
The board showed the same state (connected to ID 4, SBCL 67 MSG_IN with ACK held, SIGP).

The logged rerun (`v3.log`, abort at line 167544, about 7e9 cycles) adds the driver's side: after the
`INT 0x31` (DSTAT 04, ISTAT 0x28, still connected, ACK held on the last SDTR byte) the driver's next
writes are DSP = 012D4 (resume at the idle loop), ISTAT = 0x20 (SIGP: a new job), then ISTAT = 0x80
(abort) once the new SELECT hangs, then DSP = 01590. It never clears ACK or rejects the message, so it
seems to expect the chip to be free when it restarts at 12D4. The script hands the message bytes to the
driver through a store to memory (LOADSTORE to 82000034 before the INT), not through registers.
**Gap in the log:** host register reads are not logged (`ncr host read` count 0: the `$display` under
`sel && !we` in `ncr53c810.v` never fires; check where reads are decoded), so whether the driver reads
DSTAT/DSPS/SBCL before resuming is not known. A checkpoint just before the stall is kept:
`scratch/simruns/v3_6e9.ck` (cycle 6e9; loads only into `obj_sys_fast3`, e.g.
`sim3.sh TAG --restore ../scratch/simruns/v3_6e9.ck --cd ../scratch/isos/vms73.iso --cycles 1200000000`;
the abort comes about 1e9 cycles later).

Lines to look at: `grep -a -n 'dstat 10' scratch/simruns/v3.log` and the 400 lines before; the target's
SDTR reply is built in `rtl/scsi/scsi_targets.v` (extended message in), and whether a real RRD45 answers
SDTR at all (or rejects it) decides what we should send.

Questions for the 53C810 data manual (not in `scratch/refs`): what SELECT and WAIT RESELECT do while
connected; whether our SDTR reply (period/offset) is one the PKR driver accepts, or whether it should
answer async / MESSAGE REJECT.

## 4. Tools built this session

- `rtl/mister/dbg_trace.v`, OSD P5 Serial port = **CPU exceptions** (`stty -F /dev/ttyS1 921600 raw
  -echo clocal -crtscts; cat /dev/ttyS1` on the MiSTer): PAL entries except the hot ones (now also
  SRM's idle loop and scheduler: 24C0 2500 3740 3480 2300 2B80 25C0 2440 2100 20C0); **retire lines**
  `E3Cnn PC value` for PCs in RT_LO0..RT_HI0 (now 71418..714A8) and RT_LO1..RT_HI1 (fopen
  4A708..4AC58), value = the result or a store's data, nn = 20 + register; **write watch**
  `E3E0d PC address` for every DRAM write carrying WATCH (0x00029A92), d = 1 for DMA. The windows and
  WATCH are parameters: change them and refit.
- OSD Serial port = TGA trace also carries the SCRIPTS trace (`E3F0t`, `tools/ncrtrace.py`).
- Simulator (`verilator/system/tb_sys.cpp`): `--ccstep N` after `--restore`, `--disk-lat N`.
  `+define+NCR_TRACE` builds now log host register reads/writes and bus changes. A checkpoint loads only
  into the binary that wrote it.
- Scratch scripts (session scratchpad, copy what you need): `k.sh OUT.png keys...` (keys + screenshot
  over misterkvms-cli), `tr1.sh`/`tr3.sh NAME` (start/stop the 921600 capture on the MiSTer),
  `fit_after.sh` (waits for a free Quartus, fits a commit in `../DECAlphaStation200_fit`),
  `push2.sh NAME` (copy the rbf to .143 `_Unstable`, moving the previous one to `rbf_old`),
  `sim2.sh`/`sim3.sh TAG ARGS` (obj_sys_fast2 / obj_sys_fast3 runs into `scratch/simruns/TAG.log`).
- SRM disassembly: `python tools/alphadis.py scratch/roms/extracted/srm_v7.0-9.load_0x8000.bin VA
  --base 8000 -n N </dev/null`.

## 5. Ruled out (each tested)

LAN frames and the network (fails with Network None), bridge state, the write buffer, cold reset,
`init`, `scsi_poll off`, flash (byte-identical to boot0.rom), NVRAM swaps, SD latency and the file cache,
Main's write buffer, the 8 ms selection timeout (`04824f5`, kept but not a cure), a corrupted queue link
(it is SRM's own misaligned semaphore), the power-up memory test, "RAM not cleared" (SROM and DROM
zero it), PAL shadow registers (the 21064 has none).

## 6. Board state at hand-off

.143 runs `_Unstable/DECAlphaStation200_20261107d.rbf` (`3d4a006`, debug windows above); `_Unstable`
also has `_20261106c.rbf`. Core reloads reset the OSD to the saved settings (Console ARC, Display
Graphics, Serial COM1, Network eth0): the trace runs set Console SRM, Display Serial console, Serial
port CPU exceptions without saving. Mounted: `NETBSD_2GB.img` on ID 0, the FreeBSD disc 1 ISO on the
CD. Blank `VMS73_2GB.img` exists; NVRAM backup `AS200.before-survey-20261106.nvr.bak`. All commits are
local; nothing is pushed.
