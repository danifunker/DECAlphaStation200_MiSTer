// T3: an interrupt outranks the I-stream faults of the instruction it stops (HRM Table 4-1,
// docs/design/cpu.md 5.1). SIER[4]/SIRR[4] set in PALmode, then HW_REI to native VA 0x10000000,
// which the ITB does not map yet: the CPU must take INTERRUPT (0xE0) first, EXC_ADDR = that VA;
// the handler clears SIRR; the fetch then misses (ITB_MISS, 0x3E0), whose handler maps the page
// (PA 0x6000); the code there CALL_PALs back. NT relies on this: a new thread's first user
// instruction (kernel32!BaseProcessStart) is not mapped until the loader APC, delivered by the
// software interrupt pending at that moment, has run.
// Pass/fail to TOHOST as in T0 (step 1: the order of events in r21; 2: EXC_ADDR of the interrupt).

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

	.org	0x00E0				// INTERRUPT: r21 = r21 * 16 + 1
	sll	$21, 4, $21
	addq	$21, 1, $21
	hw_mfpr	$23, 0x24			// EXC_ADDR
	hw_mtpr	$31, 0x2d			// SIRR = 0
	hw_rei

	.org	0x03E0				// ITB_MISS: r21 = r21 * 16 + 2, then map VA 0x10000000 -> PA 0x6000
	sll	$21, 4, $21
	addq	$21, 2, $21
	hw_mtpr	$12, 0x20			// TB_TAG
	lda	$2, 0x6000($31)
	sll	$2, 19, $2
	lda	$2, 0x100($2)			// KRE
	hw_mtpr	$2, 0x21			// ITB_PTE
	bis	$31, $31, $31
	bis	$31, $31, $31
	hw_rei

	.org	0x07E0				// ITB_ACV: unexpected
	lda	$0, 91($31)
	br	$31, fail
	.org	0x13E0				// OPCDEC: unexpected
	lda	$0, 92($31)
	br	$31, fail

	.org	0x3640				// CALL_PAL 0x99: native code done
	bis	$21, $31, $4			// interrupt, then the miss: 0x12
	lda	$3, 0x12($31)
	CHECK	1
	bis	$23, $31, $4			// the interrupt's EXC_ADDR: the unmapped VA
	lda	$3, 0x1000($31)
	sll	$3, 16, $3
	CHECK	2
	br	$31, pass

	.org	0x4000
init:
	hw_mtpr	$31, 0x29			// PS = kernel
	hw_mtpr	$31, 0x26			// ITBZAP
	bis	$31, $31, $21
	lda	$12, 0x1000($31)
	sll	$12, 16, $12			// VA 0x10000000, not in the ITB
	lda	$1, 1($31)
	sll	$1, 36, $1			// SIER[4] / SIRR[4]
	hw_mtpr	$1, 0x31			// SIER
	hw_mtpr	$1, 0x2d			// SIRR
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
	call_pal 0x99
1:	br	$31, 1b
