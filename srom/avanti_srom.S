// Replacement SROM code for the AlphaStation 200 4/100 core.
// Design, register values and citations: docs/design/srom.md.
//
// The 21064 shifts this image into its I-cache at reset (tag 0, V=1, ASM=1)
// and starts here in PALmode at PC = 0 (HRM 4.5, 6.4.1; cpu.md 1.2). The
// I-stream is physical and comes from the I-cache; the D-stream is
// translated in PALmode (cpu.md 6.4), so every memory and CSR access is a
// hw_ldx/p or hw_stx/p. The D-stream cannot read this code: there are no
// data tables, every constant is built with instructions.
//
// Size limit: 7136 bytes (223 blocks: the 65,536-bit XC1765D at E23).
// PAL entry offsets inside the image (MCHK 0x20 ... FEN 0x17E0) hold a
// two-instruction "unexpected exception" stub; the code fills the gaps.
//
// Build options (cpp):
//   -DBCACHE=0          leave the Bcache disabled (BIU_CTL[BC_ENA], GCR[bc_En])
//   -DDROM_CALIBRATE    PA 0x70 = 2 (EV4: the DROM measures the speed itself)
//                       instead of 9 (the DROM V1.7 code for 100 MHz)
//   -DZERO_TOP=n        zero PA ZERO_BASE .. n-1 (default 2 MB; the DROM zeroes the rest)
//   -DZERO_BASE=n       default 0; tests/srom/emu_smoke.sh uses 0x2000 because
//                       alphaemu fetches this code from memory, not an I-cache

#ifndef BCACHE
#define BCACHE		1
#endif
#ifndef ZERO_TOP
#define ZERO_TOP	0x200000
#endif
#ifndef ZERO_BASE
#define ZERO_BASE	0
#endif
#ifdef DROM_CALIBRATE
#define SPEED_CODE	2
#else
#define SPEED_CODE	9
#endif

// --- values (docs/design/srom.md section 3) ---------------------------------
#define BIU_HI		0xE		// BIU_CTL[35:32] BC_PA_DIS: no Bcache for PA[33:32] = 1,2,3
#define BIU_LO		0x20006334	// BC_SIZE 512 KB, BC_WE_CTL[2:1], WR_SPD 3, RD_SPD 3, OE
#define ABOX_FINAL	0x400		// DC_ENA (MCHK_EN is the DROM's: it ORs in 2)
#define ICCSR_HI	0x4F8		// ICCSR write bits 42 FPE, 39 DI, 38 BHE, 37 JSE, 36 BPE, 35 PIPE
#define TIM_A		0x2695		// 21071-CA bank timing A (ours, see srom.md)
#define TIM_B		0x1352		// bank timing B
#define GTR_VAL		0x11		// global timing: tRP 3, max RAS width 2 x 128
#define RTR_VAL		0x412		// refresh: interval 8 x 64 memClk, RAS width 4, CAS-RAS 3
#define BASE8_VAL	0x4000		// bank 8 base = 1.0000.0000 (BaseAdr<33:23> in [15:5])
#define CNFG8_VAL	0x137		// bank 8: valid, 2 MB, subbanks on (PA<20>), ColSel 100
#define TAGEN_VAL	0x1FF8		// tag compare PA<28:19>: 512 KB Bcache, 512 MB cacheable
#define GCR_VAL		(0x20 * BCACHE)	// bc_En; CPU arbitration priority
#define EDSR_CLR	0xF		// lostErr, bc_TAPErr, bc_TCPErr, nxMErr (RW1C)
#define DCSR_CLR	0xFF60		// 21071-DA DCSR: every RWC error bit; control bits 0
#define DROM_LOAD	0x3FFC0		// DROM image offset 0 -> code offset 0x40 at 0x40000
#define DROM_PALBASE	0x40000
#define STUB		(DROM_LOAD + 0x10000)	// I-cache flush stub, right after the image
#define FB_DROM		0x180000	// flashbus offsets (TI Table 4-3)
#define FB_LEDS		0x140000
#define SIGNATURE	0xDECB		// PA 0x18 [31:16] (EB64+ B.1.2, PC64 Table B-1)

// --- macros -----------------------------------------------------------------
	// \r = \v for 0 <= v < 0x7FFF8000
	.macro	LI32 r, v
	ldah	\r, ((\v + 0x8000) >> 16)($31)
	lda	\r, (\v - (((\v + 0x8000) >> 16) << 16))(\r)
	.endm

	// \r = (\hi << 32) | \lo, both < 0x7FFF8000
	.macro	LI64 r, hi, lo, tmp
	LI32	\r, \hi
	sll	\r, 32, \r
	LI32	\tmp, \lo
	bis	\r, \tmp, \r
	.endm

	.macro	LED code
	lda	$1, \code($31)
	bsr	$25, led
	.endm

	// IPR spacing for the real chip (HRM 4.6; our core interlocks, cpu.md 3.4)
	.macro	PAD3
	hw_mtpr	$31, 0
	hw_mtpr	$31, 0
	hw_mtpr	$31, 0
	.endm

	// unexpected exception: PAL_TEMP1 = entry offset, then report
	.macro	VEC off
	.org	\off
	lda	$27, \off($31)
	br	$31, trap
	.endm

// Registers kept across the whole run:
//   r8  = 1.8000.0800 (21071-CA bank CSRs)  r9  = 1.8000.0000 (21071-CA)
//   r10 = memory size (bytes)                r11-r13 = bank 0-2 sizes
//   r14 = BIU_CTL value                      r15 = 1.0000.0000 (flashbus index)
//   r24 = 1.0010.0000 (flashbus data)        r22/r23 = bank timing A/B
// Links: r25 leaf (led, fbrd), r26 one level up (probe, assign, memtest).

	.text
	.globl	_start
_start:					// 0x0000 RESET
	// BIU_CTL first, as DEC's EV4 SROMs do: OE set, Bcache off
	LI64	$14, BIU_HI, BIU_LO, $1
	hw_mtpr/pa $14, 0x12		// BIU_CTL + PAL_TEMP18
	br	$31, init

	VEC	0x0020			// MCHK
// 0x0028: led (r1 = code): flashbus write of offset 14.0000 (TI 4, Table 4-3)
led:
	lda	$2, 0x94($31)
	sll	$2, 24, $2		// index: write harbinger <31> | 0x140000 << 8
	hw_stl/p $2, 0($15)
	mb
	hw_ldl/p $2, 0($15)		// read the index back (TI 4 note)
	hw_stl/p $1, 0($24)
	mb
	hw_ldl/p $2, 0($24)		// and the data register after a write
	ret	$31, ($25)

	VEC	0x0060			// ARITH
// 0x0068: fbrd (r1 = flashbus offset) -> r0 = byte
fbrd:
#ifdef TEST_FLASH_RAM
	// tests/srom/emu_smoke.sh only: alphaemu has no flashbus, so the
	// flashbus image sits in plain memory at 1.1000.0000 + offset
	lda	$2, 0x11($31)
	sll	$2, 28, $2
	addq	$2, $1, $2
	bic	$2, 7, $1
	hw_ldq/p $0, 0($1)
	extbl	$0, $2, $0
	ret	$31, ($25)
#endif
	sll	$1, 8, $2		// offset in index <28:8>, <31> = 0: read
	hw_stl/p $2, 0($15)
	mb
	hw_ldl/p $2, 0($15)
	hw_ldl/p $0, 0($24)
	and	$0, 0xff, $0
	ret	$31, ($25)

// trap: unexpected exception. PAL_TEMP0 = EXC_ADDR, PAL_TEMP1 = entry
// offset; LED F5 (reserved in TI Table 8-1); spin.
trap:
	hw_mfpr	$26, 0x24		// EXC_ADDR (raw byte form: Ibox 4)
	hw_mtpr	$26, 0x80		// PAL_TEMP0
	hw_mtpr	$27, 0x81		// PAL_TEMP1
	lda	$1, 0xF5($31)
	bsr	$25, led
1:	br	$31, 1b

	VEC	0x00E0			// INTERRUPT
// 0x00E8: probe (r7 = bank CSR pointer: base at 0, cnfg 0x200, timing
// 0x400/0x600) -> r0 = bank size in bytes, 0 if empty. The bank is set to
// 128 MB at base 0 alone; a smaller bank aliases, an empty one does not hold
// a pattern (docs/design/srom.md 4).
probe:
	hw_stl/p $22, 0x400($7)		// timing A
	hw_stl/p $23, 0x600($7)		// timing B
	hw_stl/p $31, 0($7)		// base 0
	lda	$2, 0x07($31)		// valid, 128 MB, ColSel 12,12
	hw_stl/p $2, 0x200($7)
	mb
	LI32	$3, 0x5A5AA5A5
	ornot	$31, $3, $4
	hw_stq/p $3, 0($31)
	hw_stq/p $4, 8($31)		// drive the bus to the complement
	mb
	hw_ldq/p $5, 0($31)
	clr	$0
	cmpeq	$5, $3, $5
	beq	$5, 3f			// empty bank
	ldah	$0, 0x80($31)		// 8 MB
	ldah	$6, 0x800($31)		// 128 MB
1:	hw_stq/p $0, 0($0)
	mb
	hw_ldq/p $5, 0($31)
	cmpeq	$5, $0, $5
	bne	$5, 3f			// PA s aliases PA 0: size s
	addq	$0, $0, $0
	cmpult	$0, $6, $5
	bne	$5, 1b
3:	hw_stl/p $31, 0x200($7)		// invalid again until configured
	mb
	ret	$31, ($26)

// assign (r7 = bank pointer, r1 = its size, r6 = size class, r5 = cnfg
// value, r10 = next base): place the bank at r10 if it is of class r6
assign:
	cmpeq	$1, $6, $2
	beq	$2, 1f
	srl	$10, 18, $2		// BaseAdr<33:23> in [15:5]
	hw_stl/p $2, 0($7)
	hw_stl/p $5, 0x200($7)
	mb
	addq	$10, $1, $10
1:	ret	$31, ($26)

	VEC	0x01E0			// D_FAULT
// 0x01E8: memtest (r1 = pattern): sparse test of all memory, one quadword
// every 64 KB: write addr ^ r1, read back, then leave 0 there.
memtest:
	clr	$3
	ldah	$4, 1($31)		// 64 KB step
1:	xor	$3, $1, $2
	hw_stq/p $2, 0($3)
	addq	$3, $4, $3
	cmpult	$3, $10, $2
	bne	$2, 1b
	mb
	clr	$3
2:	hw_ldq/p $2, 0($3)
	xor	$2, $1, $2
	cmpeq	$2, $3, $2
	beq	$2, memfail
	hw_stq/p $31, 0($3)
	addq	$3, $4, $3
	cmpult	$3, $10, $2
	bne	$2, 2b
	mb
	ret	$31, ($26)
memfail:				// PAL_TEMP0 = failing address; LED stays; spin
	hw_mtpr	$3, 0x80
1:	br	$31, 1b

	// BIU_CTL with or without the Bcache enabled, + PAL_TEMP18
setbiu_on:
	bis	$14, BCACHE, $14
	br	$31, 1f
setbiu_off:
	bic	$14, 1, $14
1:	hw_mtpr/pa $14, 0x12
	PAD3
	ret	$31, ($26)

	// ABOX_CTL + PAL_TEMP14 = r1
setabox:
	hw_mtpr/pa $1, 0xe
	PAD3
	ret	$31, ($26)

	VEC	0x03E0			// ITB_MISS
// 0x03E8: CPU initialisation (TI Table 8-1 FF; DEC 3000 SROM V6.1 image 0)
init:
	hw_mtpr/pa $31, 0xe		// ABOX_CTL + PAL_TEMP14 = 0: D-cache, MCHK off
	lda	$1, ICCSR_HI($31)
	sll	$1, 32, $1
	hw_mtpr/pi $1, 2		// ICCSR + PAL_TEMP2
	hw_mtpr/i $31, 0xb		// PAL_BASE = 0
	hw_mtpr/i $31, 9		// PS = kernel
	hw_mtpr/i $31, 0xe		// ASTRR
	hw_mtpr/i $31, 0x12		// ASTER
	hw_mtpr/i $31, 0x10		// HIER
	hw_mtpr/i $31, 0x11		// SIER
	hw_mtpr/i $31, 0xd		// SIRR
	hw_mtpr/i $31, 0x13		// SL_CLR
	hw_mtpr/ai $31, 6		// ITBZAP + DTBZAP
	hw_mtpr/a $31, 0		// TB_CTL
	hw_mtpr/a $31, 0xf		// ALT_MODE
	hw_mtpr/i $31, 0xa		// EXC_SUM (any write clears it)
	hw_mtpr/a $31, 0x14		// BC_TAG write: unlock
	PAD3
	hw_mfpr/a $2, 5			// VA: unlock VA, MM_CSR
	hw_mfpr/a $2, 9			// BIU_ADDR: unlock BIU_ADDR, BIU_STAT[7:0]
	hw_mfpr/a $2, 0xd		// FILL_ADDR: unlock FILL_*, BIU_STAT[14:8]
	hw_mtpr/a $31, 0x10		// CC offset 0
	lda	$1, 1($31)
	sll	$1, 32, $1
	hw_mtpr/a $1, 0x11		// CC_CTL: count from 0, enabled
	PAD3

	// constant registers
	lda	$9, 0x18($31)
	sll	$9, 28, $9		// 1.8000.0000
	lda	$8, 0x800($9)
	lda	$15, 1($31)
	sll	$15, 32, $15		// 1.0000.0000
	ldah	$24, 0x10($15)		// 1.0010.0000
	lda	$22, TIM_A($31)
	lda	$23, TIM_B($31)

	// bank 8 = flashbus (TI 4 "Accessing Flashbus Devices"); timing A/B
	// keep their reset (maximum) values
	lda	$2, BASE8_VAL($31)
	hw_stl/p $2, 0x100($8)
	lda	$2, CNFG8_VAL($31)
	hw_stl/p $2, 0x300($8)
	mb
	LED	0xFF			// CPU initialised (BIU_CTL, ABOX_CTL)
	LED	0xFE			// bank 8 done; memory sizing

	// memory sizing (TI F E; HARDWARE.md 2 "The SROM sizes the banks")
	lda	$2, GTR_VAL($31)
	hw_stl/p $2, 0x200($9)
	lda	$2, RTR_VAL($31)
	hw_stl/p $2, 0x220($9)
	hw_stl/p $31, 0x200($8)		// banks 0-2 invalid
	hw_stl/p $31, 0x220($8)
	hw_stl/p $31, 0x240($8)
	mb
	lda	$7, 0($8)
	bsr	$26, probe
	mov	$0, $11
	lda	$7, 0x20($8)
	bsr	$26, probe
	mov	$0, $12
	lda	$7, 0x40($8)
	bsr	$26, probe
	mov	$0, $13
	LED	0xFD			// sizing done; configuring

	// largest bank lowest, the next one after it (21071 4.3.4 note)
	clr	$10
	.irp	cls, 0, 1, 2, 3, 4
	.if	\cls == 0
	ldah	$6, 0x800($31)		// 128 MB: size 0011, ColSel 000
	lda	$5, 0x07($31)
	.elseif	\cls == 1
	ldah	$6, 0x400($31)		// 64 MB (split): size 0100, SubEna, ColSel 001
	lda	$5, 0x69($31)
	.elseif	\cls == 2
	ldah	$6, 0x200($31)		// 32 MB: size 0101, ColSel 001
	lda	$5, 0x4B($31)
	.elseif	\cls == 3
	ldah	$6, 0x100($31)		// 16 MB (split): size 0110, SubEna, ColSel 011
	lda	$5, 0xED($31)
	.else
	ldah	$6, 0x80($31)		// 8 MB: size 0111, ColSel 011
	lda	$5, 0xCF($31)
	.endif
	mov	$11, $1
	lda	$7, 0($8)
	bsr	$26, assign
	mov	$12, $1
	lda	$7, 0x20($8)
	bsr	$26, assign
	mov	$13, $1
	lda	$7, 0x40($8)
	bsr	$26, assign
	.endr
	ldah	$2, 0x20($31)		// at least 2 MB (TI Table 8-2, beep 1-3-3)
	cmpult	$10, $2, $2
	bne	$2, nomem
	br	$31, bcinit

nomem:	hw_mtpr	$10, 0x80		// PAL_TEMP0 = size found; LED stays FD
1:	br	$31, 1b

	VEC	0x07E0			// ITB_ACV
// 0x07E8: Bcache (TI FC). The core has no Bcache RAM (CORE_SPEC); the CSRs
// get their final values and there is nothing to sweep.
bcinit:
	LED	0xFC
	lda	$2, TAGEN_VAL($31)
	hw_stl/p $2, 0x60($9)		// tag enable
	lda	$2, GCR_VAL($31)
	hw_stl/p $2, 0($9)		// GCR
	mb

	// TI FB: Bcache and D-cache off; zero the low memory; test 1 of 4
	LED	0xFB
	bsr	$26, setbiu_off
	clr	$1
	bsr	$26, setabox
	LI32	$3, ZERO_BASE
	LI32	$4, ZERO_TOP
1:	hw_stq/p $31, 0($3)
	hw_stq/p $31, 8($3)
	hw_stq/p $31, 16($3)
	hw_stq/p $31, 24($3)
	lda	$3, 32($3)
	cmpult	$3, $4, $2
	bne	$2, 1b
	mb
	clr	$1
	bsr	$26, memtest
	br	$31, tests

	VEC	0x08E0			// DTB_MISS native
// 0x08E8
tests:
	LED	0xFA			// test 2: Bcache on, D-cache off
	bsr	$26, setbiu_on
	LI32	$1, 0x55555555
	bsr	$26, memtest
	LED	0xF9			// test 3: Bcache off, D-cache on
	bsr	$26, setbiu_off
	lda	$1, ABOX_FINAL($31)
	bsr	$26, setabox
	LI32	$1, 0x33333333
	bsr	$26, memtest
	LED	0xF8			// test 4: both on
	bsr	$26, setbiu_on
	ornot	$31, $31, $1
	bsr	$26, memtest
	LED	0xF7
	br	$31, corelogic

	VEC	0x09E0			// DTB_MISS PAL
// 0x09E8: core logic (TI F6)
corelogic:
	LED	0xF6
	lda	$2, EDSR_CLR($31)
	hw_stl/p $2, 0x40($9)		// 21071-CA error and diagnostic status
	mb
	lda	$3, 0x1A($31)
	sll	$3, 28, $3		// 1.A000.0000: 21071-DA
	lda	$2, DCSR_CLR($31)
	hw_stl/p $2, 0($3)		// DCSR: clear errors; TLB, prefetch off
	hw_stl/p $31, 0xC0($3)		// TBR1
	hw_stl/p $31, 0xE0($3)		// TBR2
	hw_stl/p $31, 0x100($3)		// PBR1: window off (WENB = 0)
	hw_stl/p $31, 0x120($3)		// PBR2
	hw_stl/p $31, 0x140($3)		// PMR1
	hw_stl/p $31, 0x160($3)		// PMR2
	hw_stl/p $31, 0x1A0($3)		// HAXR1
	hw_stl/p $31, 0x1C0($3)		// HAXR2
	mb
	hw_ldl/p $2, 0($3)		// read back (orders the CSR writes)

	// TI F3: copy the 64 KB DROM from flashbus 18.0000 to DROM_LOAD and
	// sum it: c = rotl8(c + byte, 1) over bytes 0..0xFFFE = byte 0xFFFF
	LED	0xF3
	LI32	$16, DROM_LOAD
	LI32	$17, FB_DROM
	LI32	$18, FB_DROM + 0x10000
	lda	$27, -1($18)		// offset of the check byte
	clr	$19			// checksum
	clr	$4			// stored check byte
2:	clr	$20			// quadword being assembled
	clr	$21			// its bit position
3:	mov	$17, $1
	bsr	$25, fbrd
	sll	$0, $21, $2
	bis	$20, $2, $20
	cmpeq	$17, $27, $2
	bne	$2, 4f
	addq	$19, $0, $19
	and	$19, 0xff, $19
	sll	$19, 1, $2
	srl	$19, 7, $19
	bis	$19, $2, $19
	and	$19, 0xff, $19
	br	$31, 5f
4:	mov	$0, $4
5:	addq	$17, 1, $17
	addq	$21, 8, $21
	cmpeq	$21, 64, $2
	beq	$2, 3b
	hw_stq/p $20, 0($16)
	addq	$16, 8, $16
	cmpult	$17, $18, $2
	bne	$2, 2b
	mb
	cmpeq	$19, $4, $2
	beq	$2, dromfail
	LI32	$16, DROM_LOAD
	hw_ldq/p $2, 0($16)		// header: 0x00000101, 0xFFAA0055
	ldah	$3, -0x56($31)
	lda	$3, 0x55($3)
	sll	$3, 32, $3
	lda	$3, 0x101($3)
	cmpeq	$2, $3, $2
	beq	$2, dromfail
	LED	0xF1
	br	$31, handoff

dromfail:				// TI F2 (beep 1-1-4); no console fallback
	hw_mtpr	$19, 0x80		// PAL_TEMP0 = computed sum, PAL_TEMP1 = stored
	hw_mtpr	$4, 0x81
	LED	0xF2
1:	br	$31, 1b

// TI F0: parameter block (cpu.md 1.3; DROM V1.7 0x3634-0x3670), the flush
// stub, PAL_BASE/EXC_ADDR, HW_REI.
handoff:
	LED	0xF0
	hw_stq/p $31, 0x00($31)
	hw_stq/p $10, 0x08($31)		// memory size, bytes
	lda	$2, 10000($31)
	hw_stq/p $2, 0x10($31)		// ps per RPCC count (100 MHz)
	LI32	$3, SIGNATURE
	sll	$3, 16, $3
	hw_stq/p $3, 0x18($31)		// signature V2, system revision 0
	lda	$2, 1($31)
	hw_stq/p $2, 0x20($31)		// processor mask
	hw_stq/p $31, 0x28($31)		// system context: none
	hw_stq/p $31, 0x30($31)
	srl	$10, 20, $2
	hw_stq/p $2, 0x38($31)		// memory size in MB (DROM 0x23cc, 0x3464)
	hw_stq/p $31, 0x40($31)
	hw_stq/p $31, 0x48($31)
	hw_stq/p $31, 0x50($31)
	hw_stq/p $31, 0x58($31)
	hw_stq/p $31, 0x60($31)
	lda	$2, 100($31)
	hw_stq/p $2, 0x68($31)		// CPU MHz
	lda	$2, SPEED_CODE($31)
	hw_stq/p $2, 0x70($31)		// 9: speed known; 2: EV4, DROM calibrates
	hw_stq/p $31, 0x110($31)	// RPCC calibration count
	br	$31, stub

	VEC	0x11E0			// UNALIGN
// 0x11E8: write the EB64+ B.1.9 style flush stub after the DROM image:
//   hw_mtpr/i r0, EXC_ADDR; hw_mtpr/a r31, FLUSH_IC; 5 x nop; hw_rei
// and enter it in PALmode. It flushes the I-cache (and with it this code)
// and HW_REIs to the DROM with EXC_ADDR = (DROM_PALBASE) | 1.
stub:
	LI32	$16, STUB
	LI64	$2, 0x77FF0055, 0x74000024, $3
	hw_stq/p $2, 0($16)
	LI64	$2, 0x47FF041F, 0x47FF041F, $3
	hw_stq/p $2, 8($16)
	hw_stq/p $2, 16($16)
	LI64	$2, 0x7BFF8000, 0x47FF041F, $3
	hw_stq/p $2, 24($16)
	mb
	// registers for the next stage (PC64 Table B-1, EB64+ B.1.2)
	lda	$1, ABOX_FINAL($31)	// r1 = ABOX_CTL
	mov	$14, $2			// r2 = BIU_CTL
	mov	$10, $17		// a1 = memory size
	lda	$18, 10000($31)		// a2 = ps per cycle
	LI32	$19, SIGNATURE
	sll	$19, 16, $19		// a3 = signature | revision
	lda	$20, 1($31)		// a4 = processor mask
	clr	$21			// a5 = system context
	clr	$16
	LI32	$3, DROM_PALBASE
	hw_mtpr/i $3, 0xb		// PAL_BASE = DROM image + 0x40
	bis	$3, 1, $0		// r0 = EXC_ADDR for the stub to use
	LI32	$4, STUB + 1
	hw_mtpr/i $4, 4			// EXC_ADDR = stub, PALmode
	PAD3
	hw_rei

	VEC	0x13E0			// OPCDEC
	VEC	0x17E0			// FEN
	// the Makefile checks that the image ends at or before 0x1BE0 (7136)
