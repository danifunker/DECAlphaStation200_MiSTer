# Resume prompt: FreeBSD 4.6 on the AlphaStation 200 core — network and X (2026-11-09)

Paste this into a new session. Read `CLAUDE.md` first (rules: fits in this checkout on the working branch,
one at a time, no worktrees, no queued fits; commit small steps locally; never push, never delete files or
overwrite an installed disk image without asking; ask before changing Main or a board's configuration), then
`docs/gaps.md` (the OS table's FreeBSD row, the SCSI and SIO tables) and `docs/OS_INSTALL_RESUME_PROMPT.md`
section 2 (the board procedure and OSD pitfalls). `docs/PLAN_20261109.md` is the overall order; this task is
the FreeBSD part of it, run apart from the TGA work. Only report what a test showed.

## 1. Where FreeBSD stands

- **Installed** (2026-11-08): FreeBSD 4.6-RELEASE/alpha, sysinstall "Express" (base, docs, man), on
  `FREEBSD_2GB.img` (2 GB, one root slice + swap). Boots from `dka0`, root login (password:
  `scratch/os_credentials.txt`, the FreeBSD line; never print it), disk `cp -R` + `diff -r` clean, clean
  shutdown. Backups: `C:\temp\FREEBSD_2GB_20261108.zip` (image + `AS200.nvr` + README; md5s in
  `docs/FABLE_OS_SWEEP2_RESUME_PROMPT.md`), on .143 `FREEBSD_2GB.installed-20261108.img.bak`.
- ISOs on .143 in `/media/fat/games/DECAlphaStation200/`: `FreeBSD4.6-RELEASE_Alpha-disc1.iso`, `disc2`.
  **Neither disc carries XFree86 for alpha** (checked during the install: no X distribution offered).
- The SRM boot failure that made every boot a lottery (gaps.md "SRM boots: the first console open fails")
  is **fixed** since `e83766b` (board build `_20261109d`); the 8259 cascade bug that killed slave
  interrupts (TGA 9, SCSI 11, mouse 12) is **fixed** since `ca8ac64` (`_20261109e`). Type boot commands
  normally; `scratch/bootdouble.sh` and friends are obsolete. Use `_20261109e` or later.

## 2. Open on FreeBSD (all seen on `_20261108c`, i.e. before both fixes; re-test first)

1. **Network = eth0 breaks the boot**: with `de0` on its 10baseT port, 3 of 3 boots looped on
   "sym0: unable to abort current chip operation" and the disk never attached; with Network = None (which
   selects the AUI/BNC port) the abort message came once and the boot went on. Most likely the lost
   IRQ 11 of the 8259 bug (gaps.md: ISTAT.ABRT itself is implemented since `0266a35`). Re-test with eth0
   on `_20261109e`.
2. **`dhclient de0` panics the kernel**: two "unaligned access" fixups in dhclient, then "fatal kernel trap:
   trap entry 2 (memory management fault), pc 0, ra fffffc0000610940, curproc 0" (interrupt context), a
   second MM fault while syncing. pc 0 in interrupt context smells like the same interrupt problem; if it
   survives the 8259 fix, compare `de(4)`'s receive start with NetBSD's `tlp` (DHCP and ping work there)
   and NT (TCP/IP works): the SIA/media selection (10baseT vs AUI) and the descriptor/interrupt handling
   (`rtl/net/tulip21040.v`, `docs/design/ethernet.md`). Main's Ethernet bridge is on .143
   (`support/decalpha`, branch `dec-alphastation`/`decalpha-writer`); another MiSTer needs the same Main
   (see 4).
3. "sym0: PCI BUS clock seems too high: 69440 KHz": sym times the SCSI clock with the 53C810's general
   purpose timer, whose rate in `rtl/scsi/ncr53c810.v` is off by about 1.7x. Harmless so far (sync
   periods), worth fixing with a `tb_ncr810` check.

## 3. X on FreeBSD 4.6/alpha (the goal)

- XFree86 is not on the discs. The release's packages exist in the FreeBSD archive:
  `ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/alpha/4.6-RELEASE/packages/` (XFree86-4.2.0
  packages, `x11/`, plus their dependencies); 4.6's `sysinstall` can also fetch them if the network works
  (item 2 first), or put them on an ISO and mount it on the OSD's CD-ROM slot (`mkisofs -R`, copy with
  `scratch/putiso.sh SRC NAME` from WSL), then `pkg_add` from `/cdrom`.
- The X server for the ZLXp-E1 is XFree86 4's `tga` driver (DECchip 21030, 8-plane = 8 bpp; the card is
  8 bpp only, there is no 16 bpp on a 21030). The kernel console has no TGA driver in 4.6/alpha (the
  console stays on COM1: OSD Display = Serial console to see it; set Display = Graphics to look at the TGA
  once X runs). Whether XFree86's `tga` driver needs a syscons VT on alpha, or runs with the console on the
  serial line, is not known: try `XFree86 -configure`, set `Driver "tga"`, `DefaultDepth 8`, and
  `startx`; keyboard and mouse reach the 8242 only while the TGA is the picture (OSD Display = Graphics),
  the keyboard goes to COM1 otherwise (a keystroke reaches one device only since `e83766b`).
- What X on this core already does: Tru64 4.0G's X server and the CDE desktop run on the TGA
  (`_20261109e`); known TGA gap: stale 1-pixel lines after window moves (gaps.md TGA rows), being worked
  on in the other session, so don't change `rtl/tga/` here.

## 4. Running it on another MiSTer

- Both boards have `_Unstable/DECAlphaStation200_20261109e.rbf` (.143 = 192.168.99.143, the test board;
  .92 = 192.168.99.92, the user's). Load cores through the OSD only (System page, Core, `_Unstable`),
  never with `/dev/MiSTer_cmd`. ssh works from WSL with `-i ~/.ssh/mister_only` (`scratch/ms.sh` for .143,
  `scratch/ms92.sh` for .92); misterkvms-cli: `C:\Temp\mistercore\MiSTerKVMS\target\release\misterkvms-cli.exe
  --mister <addr>` (`screenshot`, `type`, `key`, `mouse`). The scratch scripts (`scratch/an.sh`, `k.sh`,
  `slowtype.sh`, `typepw.sh "FreeBSD 4.6"`) are hard-wired to .143: copy and change the address.
- A third MiSTer needs: the rbf, `games/DECAlphaStation200/` with `boot0.rom`, `boot1.rom`, the disk image
  (from the ZIP), the ISOs, `AS200.nvr`; and **Main_MiSTer with `support/decalpha`** (the SCSI write
  buffering, CD layer and Ethernet bridge; the `decalpha-writer` build is what .143 runs, the backup of
  the stock Main is `/media/fat/MiSTer.before-decalpha`). Without it the CD-ROM slot and the network
  don't work. Ask the user before touching a board's Main.
- OSD for FreeBSD: Pri. disk = `FREEBSD_2GB.img`, CD-ROM = disc 1 (for packages later), Memory 128 MB,
  Machine: Console = SRM, Video: Display = Serial console, Network: eth0 for the network tests (None to
  reproduce the old "AUI" boot), Apply and reset, wait ~35 s for `>>>`, `boot dka0`. FreeBSD's boot1 may
  stop at "Boot:" waiting for a key (seen once; press Enter).
- Each OS boot is ~1 MB/s off the SD through hps_io; sysinstall read the CD at 100-115 KB/s.

## 5. Where the fix goes if it is the core

A failing test is a bug to reproduce on the bench first: `make -C verilator tb_tulip` (the 21040),
`tb_ncr810` (the 53C810 and targets), `tb_isa_pic` (the 8259s), `tb_sio`; the system simulator can boot
the disk image (`verilator/system/tb_sys.cpp` options; `scratch/sim10.sh` runs `obj_sys_fast10`, the
current RTL; a checkpoint at SRM's idle prompt with the NetBSD disk is `scratch/simruns/p0_srm.ck`, load
it only into `obj_sys_fast10`). Then a fix with a bench case that fails on the old RTL, a `docs/gaps.md`
row, one fit (`quartus_sh --flow compile DECAlphaStation200` in this checkout, ~40 min), the rbf to
`_Unstable` as `DECAlphaStation200_<yyyymmdd><letter>.rbf` (at most two DEC rbfs there; older ones to
`/media/fat/rbf_old/`), and the board test.
