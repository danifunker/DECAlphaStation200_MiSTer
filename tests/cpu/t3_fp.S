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

	.org	0x13E0				// OPCDEC: unexpected
	lda	$0, 92($31)
	br	$31, fail
	.org	0x17E0				// FEN
	addq	$20, 1, $20
	hw_mfpr	$23, 0x24
	addq	$23, 4, $23
	hw_mtpr	$23, 0x24
	hw_rei

	.org	0x4000
init:
	hw_mtpr	$31, 0x29			// PS = kernel
	lda	$10, 0x10($31)
	sll	$10, 16, $10			// r10 = PA 0x100000: data
	lda	$11, -1($31)
	sll	$11, 42, $11			// 0xFFFFFC0000000000: KSEG (superpage 2)
	bis	$11, $10, $11			// r11 = the same data through KSEG
	lda	$1, 0x20($31)
	hw_mtpr	$1, 0x4e			// ABOX_CTL: SPE_2 (D-stream is translated in PALmode)
	bis	$31, $31, $20

	// ---- 1: FPE = 0: an FP load takes FEN
	hw_mtpr	$31, 0x22			// ICCSR = 0
	hw_mtpr	$31, 0
	hw_mtpr	$31, 0
	ldt	$f1, 0($11)
	bis	$20, $31, $4
	lda	$3, 1($31)
	CHECK	1
	lda	$1, 1($31)
	sll	$1, 42, $1			// ICCSR[FPE] (write bit 42)
	hw_mtpr	$1, 0x22
	hw_mtpr	$31, 0
	hw_mtpr	$31, 0
	hw_mtpr	$31, 0

	// ---- 2: LDS 1.0f (0x3F800000) -> T 1.0 (0x3FF0000000000000); STT back
	lda	$1, 0x3F80($31)
	sll	$1, 16, $1
	hw_stl/p $1, 0($10)
	lds	$f1, 0($11)
	stt	$f1, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0x3FF0, 0, 0, 0
	CHECK	2
	// ---- 3: STS back to S
	sts	$f1, 16($11)
	mb
	hw_ldl/p $4, 16($10)
	zapnot	$4, 15, $4
	zapnot	$1, 15, $3
	CHECK	3
	// ---- 4: LDS of a small exponent (0x00800000: exp 1) -> exp 0x381
	lda	$1, 0x0080($31)
	sll	$1, 16, $1
	hw_stl/p $1, 0($10)
	lds	$f2, 0($11)
	stt	$f2, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0x3810, 0, 0, 0
	CHECK	4
	// ---- 5: LDS Inf (0x7F800000) -> exp 0x7FF
	lda	$1, 0x7F80($31)
	sll	$1, 16, $1
	hw_stl/p $1, 0($10)
	lds	$f3, 0($11)
	stt	$f3, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0x7FF0, 0, 0, 0
	CHECK	5

	// ---- 6: LDT/STT and LDG/STG (word swap) round trips
	LIQ	$1, 0x0123, 0x4567, 0x89AB, 0xCDEF
	hw_stq/p $1, 0($10)
	ldg	$f4, 0($11)
	stt	$f4, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0xCDEF, 0x89AB, 0x4567, 0x0123
	CHECK	6
	stg	$f4, 16($11)
	mb
	hw_ldq/p $4, 16($10)
	bis	$1, $31, $3
	CHECK	6

	// ---- 7: LDF/STF round trip of 0x40C80000 (VAX F 1.5625...)
	lda	$1, 0x40C8($31)
	zapnot	$1, 3, $1
	hw_stl/p $1, 0($10)
	ldf	$f5, 0($11)
	stf	$f5, 16($11)
	mb
	hw_ldl/p $4, 16($10)
	zapnot	$4, 15, $4
	bis	$1, $31, $3
	CHECK	7
	stt	$f5, 8($11)			// register form: exp 0x81 -> 0x401
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0x4019, 0, 0, 0
	CHECK	7

	// ---- 8: CPYS / CPYSN / CPYSE  (f1 = 1.0, f6 = -2.5)
	LIQ	$1, 0xC004, 0, 0, 0		// -2.5
	hw_stq/p $1, 0($10)
	ldt	$f6, 0($11)
	cpys	$f6, $f1, $f7			// -1.0
	stt	$f7, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0xBFF0, 0, 0, 0
	CHECK	8
	cpysn	$f6, $f6, $f7			// +2.5
	stt	$f7, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0x4004, 0, 0, 0
	CHECK	8
	cpyse	$f6, $f1, $f7			// sign+exp of -2.5, fraction of 1.0
	stt	$f7, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0xC000, 0, 0, 0
	CHECK	8

	// ---- 9: FCMOV: f6 < 0, so FCMOVLT copies, FCMOVGE keeps
	fmov	$f31, $f8			// 0
	fcmovlt	$f6, $f1, $f8			// -> 1.0
	stt	$f8, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0x3FF0, 0, 0, 0
	CHECK	9
	fcmovge	$f6, $f6, $f8			// not taken: stays 1.0
	stt	$f8, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	CHECK	9

	// ---- 10: FBLT taken, FBEQ on -0 taken, FBGT not taken
	fblt	$f6, 1f
	lda	$0, 10($31)
	br	$31, fail
1:	LIQ	$1, 0x8000, 0, 0, 0		// -0.0
	hw_stq/p $1, 0($10)
	ldt	$f9, 0($11)
	fbeq	$f9, 2f
	lda	$0, 10($31)
	br	$31, fail
2:	fbgt	$f6, 3f
	br	$31, 4f
3:	lda	$0, 10($31)
	br	$31, fail
4:
	// ---- 11: MT_FPCR / MF_FPCR: DYN = 01, INE set -> SUM set
	LIQ	$1, 0x0500, 0, 0, 0		// [58] DYN=01, [56] INE
	hw_stq/p $1, 0($10)
	ldt	$f10, 0($11)
	mt_fpcr	$f10
	mf_fpcr	$f11
	stt	$f11, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	LIQ	$3, 0x8500, 0, 0, 0
	CHECK	11

	// ---- 12: CVTQL then CVTLQ: -5 survives the round trip
	lda	$1, -5($31)
	hw_stq/p $1, 0($10)
	ldt	$f12, 0($11)
	cvtql	$f12, $f13
	cvtlq	$f13, $f14
	stt	$f14, 8($11)
	mb
	hw_ldq/p $4, 8($10)
	lda	$3, -5($31)
	CHECK	12

	// ---- 13: only the one FEN (step 1)
	bis	$20, $31, $4
	lda	$3, 1($31)
	CHECK	13

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
