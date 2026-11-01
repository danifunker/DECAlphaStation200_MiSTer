// T3: interrupt delivery (docs/design/cpu.md 7) with a software interrupt:
// SIER[4] and SIRR[4] set in PALmode, then HW_REI to native kernel code (an
// ITB mapping: VA 0x10000000 -> PA 0x6000). The CPU must take INTERRUPT
// (0xE0) before native code runs on: EXC_ADDR = the native PC, HIRR shows
// SIRR[4]; the handler clears SIRR and returns; native code then finishes.
// Pass/fail to TOHOST as in T0 (step 1: no interrupt taken; 2: HIRR SIRR
// bit; 3: EXC_ADDR; 4: native code did not finish).

	.set noreorder
	.set noat
	.set nomacro

	.macro	CHECK n
	cmpeq	$4, $3, $5
	lda	$0, \n($31)
	beq	$5, fail
	.endm

	.text
	.globl	_start
_start:
	br	$31, init

	.org	0x00E0				// INTERRUPT
	addq	$20, 1, $20			// count it
	hw_mfpr	$22, 0x2c			// HIRR
	hw_mfpr	$23, 0x24			// EXC_ADDR
	hw_mtpr	$31, 0x2d			// SIRR = 0
	hw_rei

	.org	0x03E0				// ITB_MISS: unexpected
	lda	$0, 90($31)
	br	$31, fail
	.org	0x13E0				// OPCDEC: unexpected
	lda	$0, 92($31)
	br	$31, fail

	.org	0x3640				// CALL_PAL 0x99: native code done
	bis	$20, $31, $4			// one interrupt taken
	lda	$3, 1($31)
	CHECK	1
	srl	$22, 17, $4			// HIRR SIRR[15:1] at [28:14]: SIRR[4] = bit 13 + 4
	and	$4, 1, $4
	lda	$3, 1($31)
	CHECK	2
	bis	$23, $31, $4			// EXC_ADDR: the first native instruction
	lda	$3, 0x1000($31)
	sll	$3, 16, $3
	CHECK	3
	bis	$21, $31, $4
	lda	$3, 0x77($31)
	CHECK	4
	br	$31, pass

	.org	0x4000
init:
	hw_mtpr	$31, 0x29			// PS = kernel
	hw_mtpr	$31, 0x26			// ITBZAP
	bis	$31, $31, $20
	bis	$31, $31, $21
	lda	$12, 0x1000($31)
	sll	$12, 16, $12			// VA 0x10000000
	hw_mtpr	$12, 0x20			// TB_TAG
	lda	$2, 0x6000($31)
	sll	$2, 19, $2
	lda	$2, 0x100($2)			// KRE
	hw_mtpr	$2, 0x21			// ITB_PTE
	lda	$1, 1($31)
	sll	$1, 36, $1			// SIER[15:1] / SIRR[15:1] write at [47:33]: n = 4 at bit 32 + 4
	hw_mtpr	$1, 0x31			// SIER: SIER[4]
	hw_mtpr	$1, 0x2d			// SIRR: SIRR[4]
	hw_mtpr	$12, 0x24			// EXC_ADDR = VA 0x10000000, native
	bis	$31, $31, $31
	bis	$31, $31, $31
	hw_rei

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

	.org	0x6000
	lda	$21, 0x77($31)
	call_pal 0x99
1:	br	$31, 1b
