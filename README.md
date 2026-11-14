# DEC AlphaStation 200 4/100 for MiSTer

The DEC AlphaStation 200 4/100 ("Avanti"), an Alpha workstation from 1995, on the MiSTer. It runs DEC's own
firmware (the SRM and ARC consoles) and the operating systems of its day.

## What runs

| Operating system | Console | Works |
|---|---|---|
| OpenVMS 6.2, 7.3, 8.4 | SRM | boot from disk, DECwindows Motif on the TGA, TCP/IP. Needs your licence PAKs |
| Tru64 UNIX 4.0G, 5.1B-4 | SRM | boot from disk, CDE on the TGA. The C compiler needs the OSF-DEV licence |
| NetBSD 10.2 | SRM | boot from CD and disk, networking |
| FreeBSD 5.2.1 | SRM | boot from disk, X with XFree86's accelerated `tga` driver |
| Windows NT 4.0 Workstation, Terminal Server | ARC | install, boot from disk, desktop, sound, CD audio, networking |
| Windows 2000 (build 2072) | ARC | boot from disk, desktop |

## Downloads

Everything is in `releases/`:

| File | What it is |
|---|---|
| `DECAlphaStation200_<date>.rbf` | the core. Use the newest one |
| `boot0.rom` | the 1 MB flash: SRM V7.0-9 and ARC 4.58, DEC's firmware |
| `boot1.rom` | the DROM V1.7 (power-up tests and the flash loader) |
| `AS200.nvr` | a blank NVRAM file to start from |

## Setting up

1. Copy the core to `_Unstable/` (or `_Computer/`) on the SD card and rename it `DECAlphaStation200.rbf`.
   Main's support for the core goes by that name.
2. Copy `boot0.rom` and `boot1.rom` to `games/DECAlphaStation200/`.
3. Put disk images, CD images, diskettes and NVRAM files in `games/DECAlphaStation200/`.
4. Set Memory to 128 MB (needs a 128 MB SDRAM module; 32 and 64 MB work too).

A blank 2 GB hard disk and a blank NVRAM file, made on a PC or on the MiSTer over ssh:

```bash
dd if=/dev/zero of=VMS.img bs=1M count=2048
```

```bash
cp AS200.nvr VMS.nvr
```

Networking, CUE/BIN and CHD CD images, CD audio and fast disk writes need a Main_MiSTer with DECAlphaStation200
support (`support/decalpha`). Without it, plain ISO images and disks still work.

## One NVRAM file per OS

The NVRAM file holds SRM's environment (boot device, boot flags, `os_type`), ARC's boot entries, and the
machine's CMOS: which console starts (SRM or ARC) and whether SRM uses the graphics screen or the serial port.
Give each OS its own file and pick it under Advanced > NVRAM image before starting that OS. Changes are saved to
the SD card a few seconds after the firmware makes them.

- OpenVMS, Tru64, NetBSD, FreeBSD: SRM, a copy of `AS200.nvr`.
- Windows NT and Windows 2000: ARC. Start from a copy of `AS200.nvr`, then at the SRM prompt type
  `set os_type nt` and Apply and reset: the machine starts ARC from then on. ARC's "Switch to OpenVMS or Digital
  UNIX console" goes back to SRM.

Leave Machine > Console and SRM console on NVRAM file: the file chooses. The other settings force a console
without changing the file.

## The SRM console

SRM is the `>>>` prompt. Useful commands:

```
show device
boot dka0
boot dka400
set auto_action boot
set console serial
```

`dka0` is the Pri. disk, `dka100` the second disk, `dka400` the CD-ROM, `dva0` the floppy, `ewa0` the network.
`init` restarts the console after a `set`.

## Installing OpenVMS

A blank disk as Pri. disk, the OpenVMS CD as CD-ROM, a copy of `AS200.nvr`. Apply and reset, then
`boot dka400` at `>>>`. Choose 1 (Install or upgrade) and install onto DKA0. Unmount the CD afterwards and boot
with `boot dka0`. Load your licence PAKs before DECwindows. Shut down with `@sys$system:shutdown`.

## Installing Tru64 UNIX

A blank disk as Pri. disk, the Tru64 CD as CD-ROM, a copy of `AS200.nvr`. Apply and reset, then `boot dka400`
and install onto `rz0` (4.0G) or `dsk0` (5.1B). Afterwards boot with `boot dka0`. Shut down with `shutdown -h now`.

## Installing Windows NT 4.0

NT needs ARC and a small FAT system partition on the disk for its boot loader.

1. Advanced > NVRAM image: a file of NT's own (a copy of `AS200.nvr`), switched to ARC as described above.
2. Pri. disk: a blank image of 2 GB. CD-ROM: the NT 4.0 CD (it needs the `\ALPHA` folder).
3. Apply and reset. The ARC menu comes up.
4. Run a program: `cd:\alpha\arcinst`. Create a system partition of a few MB and leave.
5. Run a program: `cd:\alpha\setupldr`.
6. Install onto the free space on the disk (NTFS or FAT). Setup reboots through ARC into NT.

Ctrl+Alt+Del logs on. Shut down from the Start menu. For sound, add the Windows Sound System driver in Control
Panel > Multimedia; MIDI plays on the OPL3. CD Player plays the audio tracks of CUE/BIN and CHD images.

## The OSD

| Page | Option | What it does |
|---|---|---|
| main | Pri. disk (ID 0), Disk (ID 1) | SCSI hard disks: `dka0`, `dka100` |
| main | CD-ROM (ID 4) | the CD image: `dka400` |
| main | Floppy (A:) | the diskette image, 720 KB to 2.88 MB: `dva0` |
| main | Load ROM | another flash image in place of `boot0.rom` for this session |
| main | Memory | 32, 64 or 128 MB (128 MB needs a 128 MB SDRAM module), at the next reset |
| main | Network interface | eth0, eth1, macvlan, tap0 or None |
| main | Apply and reset | resets with the new settings |
| Machine | Console | NVRAM file (default), SRM or ARC |
| Machine | SRM console | NVRAM file (default), Graphics or Serial |
| Machine | Halt button | the front-panel halt switch |
| Video | Display | Graphics (the TGA) or Serial console (COM1 as a text terminal on the HDMI output); the keyboard types into the one shown |
| Video | Aspect ratio, Scale | 4:3 or full screen; normal or integer scaling |
| Input | Swap Alt/Win keys | swaps the two keys |
| Advanced | J1 SROM console, J2 floppy boot, J6 flash write | the board's jumpers |
| Advanced | Board cache | the 256 KB board cache, On (default) or Off |
| Advanced | TOY year | the clock's year as the RTC gives it, or 1999 for firmware that needs it |
| Advanced | Serial port | COM1 on the MiSTer's UART (`picocom -b 9600 /dev/ttyS1`) |
| Advanced | NVRAM image | the NVRAM file (see above) |

Settings marked "Changes pending" take effect at Apply and reset. Don't change a disk image while an OS is
running: the OS loses that disk.

## What the core has

- CPU: DECchip 21064 (EV4) at 100 MHz, with its FPU (IEEE and VAX formats), 8 KB I-cache and D-cache, branch
  prediction, and a 256 KB board cache.
- Chipset: 21071 (APECS): memory controller, PCI bridge, DMA windows with scatter/gather.
- Memory: up to 128 MB.
- Firmware: DEC's DROM, SRM and ARC from the flash images; the 8 KB NVRAM and the CMOS saved to the SD card. The
  serial ROM is our own replacement (no dump of the original exists).
- Video: ZLXp-E1 (DECchip 21030 TGA, 8 bits per pixel, 2 MB VRAM) with its drawing engine and the Bt485 cursor.
- SCSI: NCR 53C810, two hard disks (IDs 0 and 1) and a CD-ROM (ID 4) with CD audio.
- Network: DECchip 21040 Ethernet, bridged to the MiSTer's network.
- Floppy: one drive.
- Sound: Windows Sound System (AD1848), OPL3 FM, PC speaker.
- Keyboard and mouse: PS/2.
- Serial: COM1 on the MiSTer's UART, plus COM2. Parallel port, real-time clock, 8259 and 8254 in the 82378 SIO.

## Known limitations

- The TGA is the 8-bit ZLXp-E1 only (no 24-bit E2/E3).
- NetBSD doesn't accept the clock's date at boot; set the time from the network.
- XFree86's accelerated copies are slower than its unaccelerated ones; use `Option "XaaNoScreenToScreenCopy"`.
- COM1 can lose characters under long, fast input. Move files on an ISO image instead.
- Windows Sound System recording gives silence.
- No parallel port interrupt or EPP/ECP, no machine checks or performance counters.
- The core runs at 100 MHz, beyond the FPGA's rated timing. On some boards it may not be stable.

## For developers

Build in Quartus 17.0 from `DECAlphaStation200.qpf`; the result is `output_files/DECAlphaStation200.rbf`.

The Verilator benches in `verilator/` run the CPU and every device on its own, and the whole machine from reset
through the firmware:

```bash
make -C verilator cputest-pipe
```

```bash
make -C verilator system
```

Notes: `docs/CORE_SPEC.md` (the hardware the core implements), `docs/HARDWARE.md` (the real machine),
`docs/gaps.md` (what is missing), `docs/design/` (one document per part: `cpu.md`, `pipeline.md`, `pci.md`,
`scsi.md`, `tga.md`, `audio.md`, `srom.md`, ...). `tools/nvr_cmos.py` shows and edits an NVRAM file's console
settings. `scratch/` (not in git) holds the manuals, ROM dumps and OS media used during development.

## License

The OPL3 is Greg Taylor's opl3_fpga, LGPL v3. The rest of the core is GPL v2 (`LICENSE`). The firmware in
`boot0.rom` and `boot1.rom` is DEC's.
