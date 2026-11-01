# Windows NT 5.0 (Windows 2000) Alpha betas on the AlphaStation 200

Source: archive.org item `os-microsoft-windows-nt5.00`. I read single files from inside the ISOs through
`https://archive.org/download/os-microsoft-windows-nt5.00/<iso>/<path>`. The copies are in `scratch/refs/nt5/<build>/`:
`TXTSETUP.SIF`, a UTF-8 copy of it, and the full file list.

## Result: the AS200 is a supported machine type in every Alpha build
Each build's `TXTSETUP.SIF` has
`avanti_up = "Digital AlphaStation 200/400 Family"`, using HAL `halavant.dll`, and `ALPHA/HALAVANT.DLL` is on every disc.
The Alpha XL 233/266 entry reuses the same HAL.

| Build | Milestone | Alpha ISO (en-us unless noted) | Display drivers on disc |
|---|---|---|---|
| 1671 | Beta 1 | `5.00.1671.1_x86fre-alphafre_client-workstation_retail_en-us-NTWKS50A-99612.iso` (x86 + Alpha) | TGA, S3 Trio/ViRGE/legacy, VGA, Cirrus, ATI, Matrox, QVision |
| 1855 | pre-Beta 2 | `5.00.1855.1_alphafre_server-enterprise_retail_en-us-NTSE50A.iso` | same + ATI Rage |
| **1877** | **Beta 2** | `5.00.1877.1_alphafre_client-workstation_retail_en-us-NTWKS50A-03-87871.iso` | same + TGA2 (PowerStorm) |
| 2031 | Beta 3 (Japanese only) | `5.00.2031.1_alphafre_server_retail_ja-jp-W2KSRVA_JPN-x04-94124.iso` | in `DRIVER.CAB` (TGA, TGA2, S3 listed in SIF) |
| **2072** | **RC1** (last Alpha release) | `5.00.2072.1_alphafre_client-professional_retail_en-us-W2KPROA_USA-x04-95185.iso` | in `DRIVER.CAB` (TGA, TGA2, S3 listed in SIF) |

Checked/debug builds also exist: `1671 x86chk-alphachk` and `1877 alphachk`. Their assertions and debug output are useful when bringing the core up.
There are also DDKs: `1671 x86dev-alphadev DDK` and `1876 DDK_BETA2`.

## Other on-board hardware (RC1 / Beta 2 SIF)
- NCR 53C810 SCSI: `symc810` ("Symbios Logic C8xx PCI SCSI Host Adapter")
- 21040 Ethernet: `dc21x4.sys`
- Keyboard and mouse: `i8042prt.sys`. Floppy: `fdc.sys`/`flpydisk.sys`. Serial and parallel: `serial.sys`/`parport.sys`
- TGA: `tga.sys`/`tga.dll`, listed as "TGA 8 Plane", "TGA 24 Plane" and "TGA 24 Plane Z-buffer"

## RC1 requirements (from RC1 `ALPHA.TXT`)
- Latest firmware for the machine. For the AS200 that is ARC 4.58 (extracted in `scratch/roms/flash/arc_v4.58.img`).
- The notes give 96 MB minimum and 128 MB recommended for Server. Professional should need less, but the notes don't say.
- About 900 MB of disk, plus 100 MB per 64 MB of RAM.
- RC1 expires 240 days after install, so set the core's TOY clock to a date in 1999.
