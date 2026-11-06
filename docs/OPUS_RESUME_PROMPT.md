# Resume prompt: the Opus plan, OS survey then video (locked 2026-11-06)

Paste this into a new session (Opus). Read `CLAUDE.md` first, then `docs/gaps.md`. The ground rules and
the board notes in `docs/FABLE_RESUME_PROMPT.md` still hold (OSD-only core loads, at most two rbfs in
`_Unstable`, one fit at a time, no pushing or deleting without asking). The TGA method is there too.

The order is fixed: the OS survey first, on the current core, so that a failure can't be blamed on new
CPU or video work. The CPU work belongs to a separate Fable session (section 3), started after the survey.

## 1. OS survey (board .143, core `DECAlphaStation200_20261104h.rbf` = `90933f8`)

Install in this order; all the ISOs are already in `games/DECAlphaStation200/` on .143:

| Order | OS | Media | Disk image | Notes |
|---|---|---|---|---|
| 1 | NetBSD 10.2 | `NetBSD-10.2-alpha.iso` | 2 GB | Hung early on an old build: start by seeing if it still does |
| 2 | OpenVMS 7.3 | `OpenVMS 7.3 Alpha.iso` | 2 GB | |
| 3 | OpenVMS 6.2 | `OpenVMS 6.2 Alpha.iso` | 2 GB | |
| 4 | OpenVMS 8.4 | `OpenVMS 8.4 Alpha.iso` | 4 GB | |
| 5 | Tru64 UNIX 4.0G | `Tru64 UNIX 4.0G.iso` | 2 GB, 4 GB if the base system won't fit | |
| 6 | FreeBSD 4.6 | `FreeBSD4.6-RELEASE_Alpha-disc1.iso` | 2 GB | Disc 2 only if the install asks for it |

Skipped for now (user): Windows NT 3.51, OpenBSD. Also re-check Terminal Server 4.0 (`NT4TSE_2GB.img`).

Rules from the user:

- **Each hard disk is 2-8 GB, as small as the OS allows, with the minimum install.**
- **A single partition where possible.** VMS has no partitions. The Unixes may need swap beside the root
  file system; take the fewest the installer allows.
- **After each successful install, take a backup** on the board:
  `<name>.installed-<yyyymmdd>.img.bak`, as `NT4_2GB.installed-20261103.img.bak` was. .143 has 97 GB
  free; this whole survey needs about 32 GB with backups.
- Name the images `<OS>_<size>GB.img`, for example `NETBSD_2GB.img`, `VMS73_2GB.img`.

Before taking .143, check that the user isn't using it (`NT4_2GB.img`, `NT4TSE_2GB.img` and `AS200.nvr`
were all written on 2026-11-06). Each OS needs its own NVRAM state in mind: SRM's console, not ARC, for
everything in this table.

Each OS climbs the same ladder, and `docs/gaps.md`'s OS table records how far it got: boot from CD,
install to disk, boot from disk, log in, then disk, network and graphics. A failure is a bug to diagnose
and fix in the RTL with a bench case, before moving to the next OS, unless it blocks for long: then note
it and go on. OpenVMS and Tru64 may need licence PAKs past a basic login: ask the user for those.

## 2. Video (after the survey)

1. **Notepad++ artefacts on NT 4.0 Workstation SP6.** Trace and replay as in
   `docs/FABLE_RESUME_PROMPT.md`. Suspects, none tested: the line tie rule (a guess), mode 0E (not drawn).
2. **Colour depth. Open, needs the user's decision before any RTL.** The user asked for 16 and 12 bpp, but
   the 21030 has no 16 bpp, and 12 bpp sits inside a 32-bit pixel (`docs/gaps.md`, TGA rows). NT's
   `tga.dll` has 8 and 32 paths only. Before any RTL, read `bSupportedBpp` in `tga.dll` and `TGAModes` in
   `TGA.SYS` (`scratch/nt4drv/`), and confirm that ARC and SRM accept an E2/E3 board.
3. The compile switch for `dbg_trace`/`dbg_overlay` comes last, once the traces are no longer needed.

## 3. CPU (the Fable session, not this one)

Measure first with `ubench`, on `NT4_2GB.img` (`cd ubench`); little has changed since its last run, so
those results still stand as a baseline. Change only what the numbers point at. Every change passes the T0
suites and an NT boot. Video and CPU share the remaining ALMs (36.1k of about 41.9k) and one fit at a time.

## 4. Afterwards

The rest of `docs/gaps.md`, in this order: flash save-back (and with it the default ARC boot entry),
NVRAM and CMOS persistence, machine checks and error interrupts, anything the survey turned up, then
what was built but never proven on the board (Ethernet traffic, WSS audio, CD audio, a floppy image).
