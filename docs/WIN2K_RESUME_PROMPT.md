# Resume prompt: Windows 2000 (NT 5.0) RC1 on the AlphaStation 200 (2026-11-03)

Paste this into a new session to pick up the Windows 2000 work. Read `CLAUDE.md`, `docs/NT5_BETAS.md`
(which builds exist, the AS200 is supported in all of them) and `docs/gaps.md` (OS table) first.

## Goal

Install Windows 2000 RC1 (build 2072, the last Alpha release) on the board, like NT 4.0, which now
installs and runs (core `a6e76de` and later, 2026-11-03).

## Where it stands

- **Media:** `scratch/isos/5.00.2072.1_alphafre_client-professional_retail_en-us-W2KPROA_USA-x04-95185.iso`
  = `games/DECAlphaStation200/W2K_RC1_Alpha.iso` on the board (md5 cf2346bb...). Target disk:
  `games/DECAlphaStation200/NT5_2GB.img` (2 GB, empty) on the OSD's Disk ID 1. NT4 stays on Disk ID 0.
- **How it's started:** OSD TOY year = 1999 (RC1's 240-day time bomb). ARC 4.58: Supplementary menu,
  then Install Windows NT from CD-ROM. SETUPLDR loads every file ("Setup is loading files ..."). The
  screen then shows **"Setup is starting Windows 2000" and nothing more**.
- **The hang:**
  - The OSD's Video debug overlay (P5) gives PCLO **0x800BFF58..0x800BFFA8** in ntoskrnl, steady.
  - It's the same at 64 MB and 128 MB, before and after the 2026-11-02/03 CPU fixes (I-fill redirect
    loss `7fafad8`, lock flag `a83a956`, interrupt vs ITB-miss priority `a5838b1`). Those fixes made
    NT 4.0 work and changed nothing here.
  - irq_h was 0 in the overlay.
- **What the loop is** (`scratch/nt_drivers/2072_rc1/disasm/ntoskrnl.exe.dis.txt`, no symbols for RC1):
  - The function is at `0x800bfdf0`, size 0x508, with 5 callers from 0x800bf0xx-0x800bf3xx. It's
    probably KiAttachProcess or KiSwapProcess; on NT4 SP1, KiAttachProcess is `0x800b2890`.
  - The loop at 0x800bff58 takes entries off a list headed at `s1+60` (the process's
    ReadyListHead), and calls `0x800c9ea0` on each (entry - 92, i.e. the thread).
  - `0x800c9ea0` looks like KiReadyThread. It reads the thread's process (`[thread+68]`) and that
    process's state byte at `+97`. When the state is not 0 (not in memory), it puts the thread back
    on that process's ReadyListHead (`+60`).
  - If that process is the one being drained, the loop never ends. So either the process's state
    byte is wrong, or the thread points at the wrong process. That points to memory corruption, or
    a CPU result that's wrong, before this point.
  - The byte fields are written with `andnot addr,3 / ldl / mskbl / insbl / or / stl`, i.e.
    longword read-modify-write. The CPU stress tests (below) cover quadword ldq_u/stq_u byte
    sequences, not this ldl/stl form.
- **Kernel debugger: no luck so far.**
  - `tools/ntkd.py` works with NT 4.0 over COM1 (ARC OSLOADOPTIONS `/DEBUG /DEBUGPORT=COM1
    /BAUDRATE=115200`; socat on the MiSTer; see the tool's header and the board notes).
  - For Setup, the options come from TXTSETUP.SIF `[SetupData] OsLoadOptions` (line 7820, file
    offset 220559417 in the ISO, originally `"/noguiboot /nodebug"`).
  - I made patched copies, all of the same size, by editing bytes in place:
    - `W2K_RC1_Alpha_kd.iso`: `"/DEBUGPORT=COM1    "`. Boots; no COM1 bytes at 19200.
    - `_kd2.iso`: unquoted value. "Line 7820 of the INF file is invalid".
    - `_kd3.iso`: `"/DEBUGPORT=COM1 /BAUDRATE=57600"`, written over the blank lines after it. Boots;
      **zero bytes on COM1 in 280 s of capture.**
  - So either SETUPLDR doesn't pass these options to the kernel, or the RC1 kernel's KD doesn't
    talk on this COM1. Untested ideas:
    - Check how RC1 SETUPLDR builds the kernel's load options. Its disassembly is in
      `scratch/nt_drivers/2072_rc1/disasm/SETUPLDR.dis.txt`; look for "OsLoadOptions" and "DEBUG".
    - Try COM2. The superio has it, but the OSD Serial port only routes COM1 to the MiSTer UART.
    - Use the **1877 Beta 2 `alphachk` (checked) build** from archive.org: its asserts and
      DbgPrints might name the problem without a debugger.

## Suggested next steps

1. **The CPU trace (OSD P5 Serial port "CPU exceptions", `rtl/mister/dbg_trace.v` sel 3)**
   - Capture on the MiSTer: `stty -F /dev/ttyS1 921600 raw -echo; cat /dev/ttyS1 > /tmp/x.log`.
   - Look at the last rare PAL entries before the hang: machine checks, D_FAULT, unaligned,
     OPCDEC, ARITH, bugcheck CALL_PALs.
   - An arithmetic or unaligned trap the core mishandles could leave a bad value behind.
   - The plain "CPU trace" mode drops events; use "CPU exceptions" (no ITB/DTB misses, interrupts
     or hot CALL_PALs).
2. **A longword-RMW and byte-sequence stress for the CPU**
   - Extend `tests/cpu/gen_memx.py` / `gen_vmx.py` with `andnot/ldl/mskbl/insbl/stl` sequences, and
     with unaligned accesses handled by a PAL UNALIGN handler.
   - Run them under `tests/cpu/irq_sweep.sh`, which adds random interrupts and checks the retire
     trace against alphaemu.
3. **Simulation**
   - The system sim (`make -C verilator system-fast`, `verilator/system/tb_sys.cpp` options:
     --arc, --key, --nvram, --cd-ua, --trace-pc) can boot the RC1 CD with the same ARC flow. It's
     slow, but it's deterministic and has full visibility.
   - Watch writes to the process object's state byte (`+97`) and to ReadyListHead (`+60`).
   - To find the process address, put a --trace-pc window around 0x800bff58 and read s1.
4. **Hardware differences W2K might use that NT4 didn't:**
   - The 21071 scatter/gather and PCI windows, and DMA above 16 MB.
   - The HAL's performance counter / RPCC; the interval timer at IRQ4 (RTC periodic).
   - The 82378 (SIO) features.
   - Read RC1's `halavant.dll` disassembly (`scratch/nt_drivers/2072_rc1/disasm/halavant.dll.dis.txt`)
     for registers NT4's HAL doesn't touch.

## Tools and facts

- Board: MiSTer at 192.168.99.143. Load cores **only through the OSD** (F12, Right, Core).
  `~/Downloads/MiSTerKVMS-1.0.27-linux-x86_64/misterkvms-cli --mister 192.168.99.143`.
- Fits run in `../DECAlphaStation200_fit`: one at a time, about 25 min, kill at 45 min.
- RC1 binaries and disassembly: `scratch/nt_drivers/2072_rc1/{bin,disasm}`.
- NT4 symbols (no RC1 symbols): `scratch/ntkd/SUPPORT/DEBUG/ALPHA/SYMBOLS`.
- `tools/nt/`: `ntsym.py DBG ADDR..` (address -> symbol), `pedbg.py PE DBG` (dump .text + symbols for
  objdump), `regf.py HIVE KEY` (list a registry key), `regset.py HIVE KEY VALUE N` (patch a DWORD in
  place).
- NTFS on the board: busybox `losetup -o <partition offset> /dev/loopN IMG`, then ntfs-3g tools
  (`ntfsls`, `ntfscat`, `ntfscp`). The `-r --show` form ignores the offset.

## Lead: machine checks (2026-11-03)

The core never raises a machine check: the CPU has no MCHK path, and apecs answers non-existent
memory, PCI master aborts and unmapped DMA windows with all ones and no error (`docs/design/cpu.md` Q15).
NT handles an MCHK by calling the HAL's machine-check handler first. If the HAL claims it, execution
resumes; otherwise a correctable/retryable error resumes and anything else bugchecks DATA_BUS_ERROR (0x2E).
If RC1's `halavant.dll` probes hardware and expects a master abort to arrive as a machine check it
swallows, a silent all-ones answer may change what it concludes. Read its machine-check handler and
probe code (`scratch/nt_drivers/2072_rc1/disasm/halavant.dll.dis.txt`) before adding MCHK and the
21071 error registers (EDSR, DCSR, PEAR) for real.
