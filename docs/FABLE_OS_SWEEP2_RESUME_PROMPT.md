# Resume prompt (Fable): OS sweep 2 — FreeBSD, Tru64, NetBSD, X — state on 2026-11-09

Paste this into a new session. Read `CLAUDE.md`, then `docs/gaps.md` (the OS table, the SCSI and SIO
tables, the P0 row "SRM boots: the first console open fails"), then `docs/OS_INSTALL_RESUME_PROMPT.md`
(the board procedure). The user's rules: only report what a test showed; commit small steps locally;
never push, never delete files without asking; never overwrite an installed disk image; ask before
changing Main or the board's configuration. The user asked for this sweep with a short time box per
OS and a list of what is wrong for you; the user's main interest is **whether X works**.

## 1. Results (core `_Unstable/DECAlphaStation200_20261108c.rbf` = `3a74a68`, board .143)

| OS | Install | Boots from disk | Disk test | Network | X |
|---|---|---|---|---|---|
| FreeBSD 4.6-RELEASE | **yes** (sysinstall Express, `FREEBSD_2GB.img`) | yes (with the SRM retries, and Network = None, see 2b) | `cp -R`+`diff -r`, md5 equal | `dhclient de0` **panics** the kernel (2c) | not testable: no XFree86 on the two CDs, no TGA driver in 4.6/alpha |
| Tru64 (Digital UNIX) 4.0G | **yes** (Custom, mandatory subsets incl. CDE, `TRU64_40G_2GB.img`) | yes (SRM retries) | `cp -r`+`diff -r`, cksum equal | not configured | **no**: starting the X server wedges the machine (2a) |
| Tru64 5.1B-4 | **yes** (U.S. English, mandatory subsets incl. CDE, UFS default layout, `TRU64_51B_4GB.img`; 42/42 subsets 02:52–03:23, kernel build, its own reboot) | first boot to multi-user, then **wedged at the X start** ("Printer service started", evmpost/smsd errors, then nothing); later boots failed in SRM | not done | not configured | **no** (same wedge as 4.0G, 2a) |
| NetBSD 10.2 | (2026-11-06) | yes (SRM retries) | — | DHCP 192.168.99.142, ping 3/3 | **server runs, nothing drawn** (2f) |

ZIPs in `C:\temp` (each: image + `AS200.nvr` + `README.txt` with the OSD settings, boot command and
known problems; passwords are in `scratch/os_credentials.txt`, never in a ZIP):

| ZIP | Image md5 | ZIP size, md5 |
|---|---|---|
| `FREEBSD_2GB_20261108.zip` | `70bb96706488de0d088a45e30c94f0f0` | 103,621,272, `21bd1e0c97b43c3b5f7243160b969dab` |
| `TRU64_40G_2GB_20261109.zip` | `d4b580b4f90c2f4cda885c6bc15eb846` | 125,004,425, `50c6a2eb422ac281fc9c21d986ab82e3` |
| `NETBSD_2GB_20261109.zip` (as installed 2026-11-06, before the X sets) | `e12cdf497801ad9c47fed9b501fb3544` | 81,948,176, `d8124cf1fb846385c4c8914ba2f383a5` |

Tru64 5.1B-4 has no ZIP (no verified login): the board has `TRU64_51B_4GB.img` and the copy
`TRU64_51B_4GB.installed-20261109.img.bak`, taken after it was halted from the OSD while wedged at
the X start. To finish it: boot single user (`boot dka0 -fl s` right after an OSD Apply and reset,
with `scratch/bootcrash.sh`), `/sbin/bcheckrc`, `mv /sbin/rc3.d/S95xlogin /sbin/rc3.d/off.S95xlogin`,
then multi-user, root login (password in `os_credentials.txt`), disk test, clean shutdown, ZIP. On the board: `FREEBSD_2GB.installed-20261108.img.bak`,
`TRU64_40G_2GB.installed-20261109.img.bak`, `AS200_pretru64.nvr` (the NVRAM before Tru64 wrote its
variables; the live `AS200.nvr` now has `boot_osflags` and `kbd_hardware_type=PCXAL` too).

## 2. What is wrong, most important first

### 2a. A spurious IRQ 15 blocks every slave-8259 interrupt (X on Tru64; likely the SCSI hangs too)

**Fixed 2026-11-09 (`ca8ac64`, board `_20261109e`): X runs on Tru64 4.0G (CDE login on the TGA). The mechanism
was close to the guess below but simpler: the master held IR2 until the acknowledge, so a slave request that went
away before it was answered with the slave's IRQ15 vector and master ISR2 set; real masters give their default
IRQ7 with no ISR bit. `make -C verilator tb_isa_pic`. Details: gaps.md, the 8259 row.**

Tru64 4.0G: multi-user boot reaches "The system is ready", then dtlogin starts the X server ("Starting
Desktop Login on display :0"). Nothing is ever drawn: Display = Graphics still shows SRM's old text, and
the TGA trace on ttyS1 records **0 bytes** in 15 s. From then on the serial console takes no input and
the CPU sits in the kernel idle loop (PC `fffffc00002c6cxx`). In single user, `/var/dt/Xerrors` is empty
and `/var/dt/Xpid` was written. Running `/usr/bin/X11/X :0` by hand prints at once

    intr: stray interrupt:  present_ipl:0x3 vector:0x8f0

and the shell never returns; a few seconds later psiop0 reports "timeout on disconnected request" for
target 0: **the SCSI interrupt (IRQ 11) has stopped arriving**. Vector 0x8f0 = 0x800 + 15 × 0x10 =
ISA IRQ 15. The TGA is on IRQ 9 (NetBSD: `tga0: interrupting at isa irq 9`).

Candidate from reading `rtl/sio/isa_pic.v` (not tested): the master resolves the slave's INT through
its own three-clock pipeline, and any write, acknowledge or poll on the slave makes the slave's `pend`
"stale" (none) for two clocks. An IACK in that window takes the `via_s` path with the slave empty:
`iack_vec = s_vec` = {vbase, 7} = **IRQ 15**, `ack_m` sets the **master's ISR[2]**, `ack_s` is
suppressed. If the OS treats it as stray and sends no EOI to the master, master IR2 stays in service
and IRQ 8–15 (TGA 9, SCSI 11, mouse 12) are blocked for good. That matches the wedge exactly. A slave
IMR write (A1h) just before an IACK is what an X server does when it enables the TGA's end-of-frame
interrupt (IRQ 9). Real 8259s give the master's own IRQ7 when the cascade request has already gone.
To do: a bench case (slave IMR write, IACK 1–3 clocks later) in a `tb_isa_pic`, then make the cascade
consistent (no stale window across IR2, or answer `via_s && s_pend[3]` as the master's spurious IRQ7
without setting ISR[2]); re-test X on Tru64 4.0G (re-enable dtlogin: rename
`/sbin/rc3.d/off.S95xlogin` back to `S95xlogin`) and the SCSI hangs of 2b.

### 2b. Kernel SCSI probes that never complete (FreeBSD sym, Tru64 psiop)

- FreeBSD 4.6 from disk, 3 of 3 boots with Network = eth0 where de0 printed "enabling 10baseT port":
  an endless "sym0: unable to abort current chip operation" loop, the disk never attaches. With "AUI/BNC
  port" (Network = None always picks it) the abort message appears once and the boot goes on (4/4).
- Tru64 4.0G `boot dka0 -fl s` after an OSD halt: "timeout on disconnected request" × 3 on target 0,
  "Reached max abort count, scheduled bus reset", hang (here tu0 had not been probed yet).
- Both drivers try to abort with **ISTAT.ABRT, which the 53C810 model stores and ignores**
  (`rtl/scsi/ncr53c810.v`: `abrt_req` lands in ISTAT bit 7 and nothing else). FreeBSD's
  `sym_soft_reset` writes CABRT and polls ISTAT for DIP (with DSTAT.ABRT) for 1M reads. Implement the
  abort (stop SCRIPTS, DSTAT.ABRT, DIP; also when SCRIPTS are idle) with a `tb_ncr810` case.
- The root cause of the lost reselection is probably 2a (a lost IRQ 11): check that first.
- Seen on both Tru64s: `boot dka0 -fl s` right after an **OSD Halt** fails this way at the very first
  probe of target 0, every time; after an OSD Apply and reset the probe is fine. So the halt leaves
  the chip or the target mid-transfer, and neither SRM's init, nor the OS's chip reset, nor the SCSI
  bus reset brings target 0 back: check what SCNTL1.RST / ISTAT.SRST do to `scsi_targets.v`.
- Also: "sym0: PCI BUS clock seems too high: 69440 KHz" (sym times the SCSI clock with the general
  purpose timer; the model's timer rate is off by ~1.7x, so sym may derive wrong sync periods).

### 2c. FreeBSD: `dhclient de0` panics the kernel

Network = eth0, de0 on 10baseT: two "unaligned access" fixups in dhclient (pc 0x1200274e4/e8, `ldt`),
then "fatal kernel trap: trap entry 2 (memory management fault), pc 0, ra fffffc0000610940, curproc
0" (interrupt context), panic; a second MM fault while syncing (pc fffffc00005a9b84, ra
fffffc00005b0d28). NetBSD's tlp driver on the same chip does DHCP and ping fine, and so does NT, so look
at what de(4) does differently: the SROM/media path (10baseT vs AUI selection, SIA registers) and the
descriptor/interrupt handling when the receiver starts. Possibly 2a again (an interrupt with no
handler: pc 0).

### 2d. SRM boot failure (P0): a workaround and a lead

**Fixed 2026-11-09 (`e83766b`, board `_20261109d`): every MiSTer keystroke reached both COM1 (ps2_ascii) and
the 8242, and SRM's keyboard driver delivered the second copy too, waking the shell's wait on its boot child
47 times while the bootstrap's cb_open restarted the drivers; now a keystroke reaches one device only.
10 of 10 keyboard-typed boots pass. `scratch/bootdouble.sh`/`bootcrash.sh` are no longer needed. Details:
gaps.md, the P0 row.** The text below is the state before the fix.

Unchanged in nature (gaps.md P0 row), but much more frequent tonight: about 9 of 10 boots typed at an
idle `>>>` failed (halt 5 PC 180000020 mostly; also PC 0, PC 200135e0, "kernel stack not valid halt"
PC 111300 / 1010e420, "Can't open file /boot/loader", "can't open osf_boot", "cb_open: failed",
FreeBSD's boot1 stopping at "Boot:" until a key was pressed). NetBSD failed 18 in a row; 8 of those
were under heavy SD load on the board (a 2 GB cp + 4 GB dd), 10 with the SD idle. The NVRAM (before
or after Tru64's writes), Network eth0/None and the Serial port setting made no difference.

**Every boot that passed was typed while SRM was still restarting itself after a 180000020 crash**,
before its `>>>`: FreeBSD CD 2/2, FreeBSD disk, Tru64 CD and disk, and NetBSD first time with
`scratch/bootdouble.sh "boot dka0 -fl a" 22` (type the command, then type it again 22 s later, while
the first one's crash restarts SRM). So SRM's state after a complete start differs from its state when
it takes a command line typed during the restart. That points at the shell's `child_done` semaphore
in its packed frame and the driver restart in `cb_open` (gaps.md). Compare the two in the system
simulator: `--type` at the idle `>>>` against `--type` during a restart.

### 2f. NetBSD: the X server runs but its drawing never reaches the TGA

The board's `NETBSD_2GB.img` now has the X sets (xbase, xetc, xfont, xserver, untarred from the CD)
and `/etc/X11/xorg.conf` = `Driver "wsfb"`, `DefaultDepth 8` (the ZIP in `C:\temp` is the clean image
from before X). With the console on COM1 the TGA attaches as `wsdisplay1` without screens and Xorg
stops at "xf86OpenConsole: No console driver found". With SRM `set console graphics` + `init` and
OSD Display = Graphics, NetBSD's wscons console runs on the TGA (text fine). Xorg without a config
picks the native `tga` driver, which needs `/dev/mem` (refused at securelevel 1) and asks for depth
24/32: "Screen(s) found, but none have a usable configuration". With the wsfb config `startx` runs:
the colormap changes (the console text turns blue, its cursor red), the Bt485 hardware cursor appears
and follows the mouse, and its shape changes between I-beam (over the xterms) and arrow (root), so the
server and its clients are running. But nothing X draws shows: the old console text is never cleared
or overwritten. So wsfb's mmap of the frame buffer (NetBSD `tga_mmap`, the offset from
`WSDISPLAYIO_GET_FBINFO`) writes somewhere the model does not display, or through an alias it does not
decode. Next: the TGA trace (OSD Advanced, Serial port = TGA trace) while Xorg starts, captured to
`/media/fat` (the board's `/tmp` is full). The keyboard input into the xterm had no visible effect and
Ctrl+Alt+Backspace is off, so the image was halted from the OSD with X running (fsck on next boot).
Note: switching the OSD NVRAM file while SRM runs carries the live settings into the newly selected
file (`AS200.nvr` picked up `console graphics`; it was set back to `serial`).

### 2e. Smaller things

- Tru64 4.0G installer: "Setting console environment variables / Current Firmware: 7.0-0 / I/O
  error (errno 5) for block(0x40,0x40) on device 255,1" (writing the console variables through the
  PROM?). Its own reboot afterwards worked.
- OSD Halt, then a key at SRM's halt message, crashed SRM (180000020) instead of a clean `>>>`.
- The serial-console vterm: no DEC special graphics (VT100 line drawing shows `lqqk`/`0xB`), 128
  columns (80-column full-screen programs wrap), and `ps2_ascii.v` sends nothing for the cursor keys
  (sysinstall's menus could only be driven with letters, Tab and Enter).
- FreeBSD 4.6 install read the CD at ~100–115 KB/s (gunzip at 100 MHz plus SCSI).
- The board's `/tmp` is full (a `cat: write error: No space left on device` when starting a trace
  capture): earlier trace logs in `/tmp` (not deleted; they are the user's to clear).

## 3. Tools added this session (scratch/, not in git)

- `scratch/an.sh "TEXT" WAIT`: type, Enter, wait, screenshot to `$TEMP/a.png` (sets
  `MSYS_NO_PATHCONV=1`: Git Bash otherwise rewrites `/sbin/...` arguments into Windows paths).
- `scratch/rb.sh "CMD" WAIT OUT`: from the OSD's first row, Apply and reset, wait for `>>>`, type.
- `scratch/bootretry.sh "CMD" N`: waits for an idle `>>>` (screen still + `scratch/atprompt.py` matches
  `scratch/prompt_tpl.png`), types, and decides booted/failed. Typing at the idle prompt is what fails
  most: prefer `scratch/bootdouble.sh`.
- `scratch/bootdouble.sh "CMD" 22`: the workaround of 2d. `scratch/bootcrash.sh "CMD"` does the same
  but types the second command when the screen starts moving after a still spell (the crash can come
  later than 22 s). Neither helped on the last Tru64 5.1B-4 boots (8 failures in a row at 04:40).
- `scratch/scrdiff.py`, `scratch/atprompt.py`: screenshot comparison (the capture is lossless).
- `scratch/putiso.sh SRC NAME`: scp a file into the board's games directory (from WSL).
- `scratch/sweep2_notes.md`: the raw notes this document came from.
