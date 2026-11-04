// T3: the FP register file and the FPU's non-arithmetic instructions
// (docs/design/cpu.md 8.2, 8.3, 8.5): FEN with ICCSR[FPE] = 0, LDS/LDT/STS/
// STT, LDF/LDG/STF/STG conversions, CPYS/CPYSN/CPYSE, FCMOVxx, FBxx,
// MT_FPCR/MF_FPCR, CVTLQ/CVTQL. Pass/fail to TOHOST as in T0.

	.set noreorder
	.set noat
	.set nomacro

	.macro	CHECK n
	cmpeq	$4, $3, $5
	lda	$0, \n($31)
	beq	$5, fail
	.endm

	// r3 = a 64-bit constant (built from four 16-bit pieces)
	.macro	LIQ r, a, b, c, d
	lda	\r, (((\a) ^ 0x8000) - 0x8000)($31)
	sll	\r, 16, \r
	lda	$24, (((\b) ^ 0x8000) - 0x8000)($31)
	zapnot	$24, 3, $24
	bis	\r, $24, \r
	sll	\r, 16, \r
	lda	$24, (((\c) ^ 0x8000) - 0x8000)($31)
	zapnot	$24, 3, $24
	bis	\r, $24, \r
	sll	\r, 16, \r
	lda	$24, (((\d) ^ 0x8000) - 0x8000)($31)
	zapnot	$24, 3, $24
	bis	\r, $24, \r
	.endm

	.text
	.globl	_start
_start:
	br	$31, init

	.org	0x0060				// ARITH, as NT 4.0's PALcode (A321064.PAL) does it:
	addq	$20, 1, $20
	hw_mfpr	$22, 0x2a			// EXC_SUM (its MSK bit: F31)
	hw_mtpr	$31, 0x2a			// clear the summary; the mask is not affected
	bis	$31, $31, $23
	lda	$24, 31($31)
1:	hw_mfpr	$25, 0x2a			// MSK: F30 .. F0
	addq	$23, $23, $23
	subq	$24, 1, $24
	addq	$25, $23, $23
	bne	$24, 1b
	srl	$23, 33, $23			// bit n = Fn
	hw_rei					// EXC_ADDR = the next instruction
	.org	0x13E0				// OPCDEC: unexpected
	lda	$0, 92($31)
	br	$31, fail
	.org	0x17E0				// FEN: unexpected
	lda	$0, 93($31)
	br	$31, fail

	.org	0x4000
init:
	hw_mtpr	$31, 0x29			// PS = kernel
	lda	$10, 0x10($31)
	sll	$10, 16, $10			// PA 0x100000
	lda	$11, -1($31)
	sll	$11, 42, $11
	bis	$11, $10, $11			// its KSEG address
	lda	$1, 0x20($31)
	hw_mtpr	$1, 0x4e			// ABOX_CTL: SPE_2
	lda	$1, 1($31)
	sll	$1, 42, $1
	hw_mtpr	$1, 0x22			// ICCSR: FPE
	hw_mtpr	$31, 0
	hw_mtpr	$31, 0
	hw_mtpr	$31, 0
	bis	$31, $31, $20

	LIQ	$1, 0x3FF8, 0, 0, 0		// 1.5
	hw_stq/p $1, 0($10)
	LIQ	$1, 0x4002, 0, 0, 0		// 2.25
	hw_stq/p $1, 8($10)
	LIQ	$1, 0x4008, 0, 0, 0		// 3.0
	hw_stq/p $1, 16($10)
	lda	$1, 7($31)
	hw_stq/p $1, 24($10)
	ldt	$f1, 0($11)
	ldt	$f2, 8($11)
	ldt	$f3, 16($11)
	ldt	$f4, 24($11)

	// ---- 1: ADDT 1.5 + 2.25 = 3.75
	addt	$f1, $f2, $f5
	stt	$f5, 32($11)
	mb
	hw_ldq/p $4, 32($10)
	LIQ	$3, 0x400E, 0, 0, 0
	CHECK	1
	// ---- 2: MULT 1.5 * 2.25 = 3.375, used at once by the next instruction
	mult	$f1, $f2, $f6
	addt	$f6, $f6, $f6			// 6.75
	stt	$f6, 32($11)
	mb
	hw_ldq/p $4, 32($10)
	LIQ	$3, 0x401B, 0, 0, 0
	CHECK	2
	// ---- 3: DIVT 3.0 / 2.25 = 1.333.. (rounded) ; check 3.0 / 1.5 = 2.0 exactly
	divt	$f3, $f1, $f7
	stt	$f7, 32($11)
	mb
	hw_ldq/p $4, 32($10)
	LIQ	$3, 0x4000, 0, 0, 0
	CHECK	3
	// ---- 4: CMPTLT 1.5 < 2.25 -> 2.0 (0x4000...)
	cmptlt	$f1, $f2, $f8
	stt	$f8, 32($11)
	mb
	hw_ldq/p $4, 32($10)
	LIQ	$3, 0x4000, 0, 0, 0
	CHECK	4
	// ---- 5: CVTQT 7 -> 7.0
	cvtqt	$f4, $f9
	stt	$f9, 32($11)
	mb
	hw_ldq/p $4, 32($10)
	LIQ	$3, 0x401C, 0, 0, 0
	CHECK	5
	// ---- 6: DIVT 1.5 / 0 traps (DZE): ARITH entry, EXC_SUM.DZE (bit 4)
	fclr	$f10
	divt	$f1, $f10, $f11
	trapb
	bis	$20, $31, $4
	lda	$3, 1($31)
	CHECK	6
	and	$22, 0x10, $4
	lda	$3, 0x10($31)
	CHECK	6
	bis	$23, $31, $4			// the write mask: F11 (NT's read order)
	lda	$3, 0x800($31)
	CHECK	6
	// ---- 8: a second trap reports its own destination (F2): the mask reads start at F31 again
	divt	$f1, $f10, $f2
	trapb
	bis	$23, $31, $4
	lda	$3, 4($31)
	CHECK	8
	// ---- 7: FPCR.DZE (bit 53) is set
	mf_fpcr	$f12
	stt	$f12, 32($11)
	mb
	hw_ldq/p $4, 32($10)
	srl	$4, 53, $4
	and	$4, 1, $4
	lda	$3, 1($31)
	CHECK	7

pass:	lda	$6, 0x80($31)
	sll	$6, 16, $6
	lda	$1, 1($31)
	hw_stq/p $1, 0($6)
1:	br	$31, 1b

fail:	lda	$6, 0x80($31)
	sll	$6, 16, $6
	hw_stq/p $4, 8($6)
	hw_stq/p $3, 16($6)
	sll	$0, 1, $1
	bis	$1, 1, $1
	hw_stq/p $1, 0($6)
1:	br	$31, 1b
