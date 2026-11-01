# CD-ROM: Main_MiSTer's CD layer, the track table, CD audio

The CD-ROM drive at SCSI ID 4 (`dka400`, an RRD45 by its INQUIRY strings) is `rtl/scsi/scsi_targets.v`
on hps_io block-device slot 2. Its audio player is `rtl/scsi/cd_audio.v`. Main_MiSTer serves the disc
through `support/decalpha` on the branch `dec-alphastation`. The design follows the user's HP 9000/715
core (`rtl/scsi/cd_audio.sv`, Main `support/hp9k`) and the RS/6000 7248 core (Main `support/ibmrs6k`).
`docs/design/scsi.md` covers the SCSI side.

## 1. Main_MiSTer: `support/decalpha`

Branch `dec-alphastation` (from `master` 88d2d10), commit `3520ddd`, in the worktree
`../Main_MiSTer-decalpha`. Never check this branch out in `../Main_MiSTer` itself.

| File | What |
|---|---|
| `decalpha.cpp/.h` | The hooks. `is_decalpha()` matches the RBF name `DECAlphaStation200`. The CD is slot 2; slots 0 and 1 go through the write buffer |
| `decalpha_cdrom.cpp/.h` | ISO, CUE/BIN and CHD images; the track-table and audio windows |
| `decalpha_disk.cpp/.h` | The hard-disk write buffer (support/ibmrs6k's, itself support/hp9k's) |

`user_io.cpp` calls the hooks beside the Sun family's:

- `decalpha_mount_hook` in `user_io_file_mount`;
- `decalpha_unmount` on eject;
- `decalpha_poll` in `user_io_poll`;
- `decalpha_sd_service` in the block-device loop, before the generic path.

`support.h` includes `decalpha.h`. Every hook returns at once unless the core is DECAlphaStation200.

**Build**:

```
PATH=~/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:$PATH make -C ../Main_MiSTer-decalpha
```

This gives `bin/MiSTer` with no warnings. It goes to `/media/fat/MiSTer` on the board. It has not
been tested on the board yet.

### Disks (slots 0, 1)

- Writes are gathered into runs of up to 64 KB (8 runs per slot).
- A run is flushed 20 ms after the slot's last write, or 500 ms after the run started.
- Everything is flushed on unmount or remount.
- A read flushes the runs it overlaps, so a read after a write always returns the new data.
- The file is reopened by path if Main's handle has changed.
- Reads go through the generic path.

### CD (slot 2)

| Image | How it is served |
|---|---|
| `.iso`, or a flat 2048-byte image | The generic path (passthrough). The hook still answers the windows (a one-track table) |
| A raw 2352-byte or MODE2 2336-byte image | Found by its PVD or sync pattern; served as 2048-byte user data |
| `.cue` + `.bin` | One or more BINARY FILEs; TRACK AUDIO, MODE1/2352, MODE1/2048, MODE2/2352, MODE2/2336; INDEX 00/01, PREGAP; **REM SESSION n** (new) |
| `.chd` | Through `support/chd` (libchdr). CD-DA is byte-swapped back to the bin's order |

- **Whole-disc LBAs** (new compared with the HP/RS6K layers): slot byte 2048·n is disc LBA n.
  - Every data track is served at its own TOC address. A second-session data track (CD-Extra,
    multi-session) is therefore where ISO 9660 expects it.
  - Audio sectors and gaps read as zeros.
  - The image size given to the core is the lead-out × 2048.
- If the first track of an image starts above 0 (a CHD with its pregap stored), every LBA is
  moved back by that amount.

### The windows

Both windows are on the CD slot, above any real disc.

**Block `C000_0000`, 2 blocks: the track table**

| Byte | Contents |
|---|---|
| 0 | First track number |
| 1 | Number of tracks n (0 = no table) |
| 2 | n + 1 (as in support/hp9k) |
| 3 | 1 |
| 4 | **The first track of the last session** (new; 0 from an older Main: taken as the first track) |
| 5 | **The number of sessions** (new; 0 = 1) |
| 8 + 8k | Entry k for k = 0..n: {ADR/control (0x14 data, 0x10 audio), track, M, S, F (absolute, LBA + 150), LBA[23:16], LBA[15:8], LBA[7:0]}. The lead-out (track 0xAA) is last |

**Block `8000_0000` + 5f, 5 blocks: audio frame f**

- 2352 bytes: 588 stereo samples, 16-bit little-endian, left first.
- Then 208 zero bytes.
- A frame outside every audio track reads as zeros.

These windows are the HP 9000/715 and RS/6000 layout. Bytes 4-5 are the only addition, and the
older cores ignore them.

## 2. The core side

### Ports added to `scsi_targets`

```verilog
scsi_targets #(.DISK0_ID(3'd0), .DISK1_ID(3'd1), .CD_ID(3'd4),
               .CD_ALWAYS(1),            // the drive answers selection with no image
               .CLK_HZ(100000000))       // the system clock, for the 44.1 kHz sample clock
  ...
  input  wire        cd_change,         // a pulse when slot 2 is (re)mounted: img_mounted[2]
  output wire signed [15:0] cd_audio_l, // CD audio, port 0 of page 0E
  output wire signed [15:0] cd_audio_r, // port 1
  output wire        cd_audio_stb,      // one clock per sample, 44,100 times a second
```

- `cd_audio_stb` is a one-clock pulse, also while silent.
- `cd_audio_l` and `cd_audio_r` change only in the clock that follows a strobe.
- Between strobes the samples are held.
- They are zero unless playing, and both are registered.

Nothing else is needed from hps_io beyond slot 2's ordinary block-device signals. The frames and the
table are ordinary reads of slot 2 at the window addresses, as in the HP 9000/715 core.

### `cd_audio` (instantiated inside `scsi_targets`)

Its ports are internal: the TOC RAM's port A, play/pause/resume/stop pulses, the sub-channel
position, the frame request/go/done handshake, and the frame bytes (`fb_we/fb_addr[11:0]/fb_data[7:0]`
from the 8-bit hps_io). It is ported from the HP core's `cd_audio.sv`, with these changes:

- Bytes are packed into halfwords.
- The channel selection of page 0E is applied (port 0 = left output, port 1 = right):
  - bit 0 = audio channel 0;
  - bit 1 = audio channel 1;
  - both bits = the average of the two;
  - neither = mute.
- The output strobe. A tick that read a sample outputs it. A tick that did not:
  - holds the last sample while the play waits for a frame;
  - otherwise outputs silence.
  So a PAUSE neither drops nor repeats a sample.

**Player behaviour:**

- One frame is fetched at a time into a double buffer (two 16-bit × 2048 banks).
- 588 samples per frame.
- The track and the relative position are followed across track boundaries.
- Volume: the sample × (vol + vol[7]) / 256, so 255 is unity.
- A data READ on the CD stops a play (it shares the engine's block port), as many drives do.

## 3. What the OSes see

| Command | SRM | NT/W2K (cdrom.sys, CDFS, CD Player) | Linux (sr), Digital UNIX |
|---|---|---|---|
| INQUIRY, TUR, READ CAPACITY, READ(10), MODE SELECT (512) | yes | yes | yes |
| UNIT ATTENTION 28 after a remount | START UNIT, then a retry | media change | media change |
| NOT READY 3A with no disc | "no media" | no media | no media |
| READ TOC 0 (LBA/MSF), 1 | | yes (TOC, last session) | yes (tochdr, multisession) |
| READ TOC 2 | | READ_TOC_EX full TOC | cdrecord-type tools |
| PLAY MSF / TRACK INDEX, PAUSE/RESUME, STOP, READ SUB-CHANNEL 1, page 0E | | CD Player | xmcd/cdplay, CDROMVOLCTRL |

## 4. Limits

- **Format 2 (full TOC)** lists every track as session 1. A0/A1/A2 are given once, for the whole
  disc.
- **Format 1** gives the last session's first track from the table, so two sessions are reported
  correctly, and more sessions report the last one.
- **CHD**: images carry no session information (single session).
- **Indexes**: every track is index 1. There are no pregaps in the sub-channel and no index 0.
  PLAY TRACK/INDEX ignores the index fields.
- **No UPC/ISRC**: sub-channel formats 2/3 answer "not valid".
- **No digital audio extraction**: READ CD with sector types other than "any" or "mode 1", or with
  header/sync/EDC/C2/sub-channel fields, gives ILLEGAL REQUEST. W2K's raw-read IOCTL fails on audio
  tracks.
- **IMMED**: status always returns at once. PLAY AUDIO with IMMED off is not modelled.
- **PLAY past the lead-out**: an address beyond the table's lead-out gives ILLEGAL REQUEST 21. An
  end beyond it is clipped. Starting a play in a data track plays silence; real drives answer 64.
- **Media lock**: PREVENT/ALLOW is accepted, and the MiSTer OSD can still swap the disc.
