// T3: a store right behind a load that misses the D-cache, into the line that
// load fills, then a load of the stored address. The store's hit was decided
// against the line's tag before the fill's tag write had landed: it missed,
// skipped the D-cache (write-through, no allocate), and the next load read the
// filled (old) data. Found in ARC 4.58's FindScsiDevices (stl, then ldl 0).
// Physical loads and stores with the D-cache on (ABOX_CTL[10]). Pass/fail to
// TOHOST as in T0 (steps 1-2: quadword, longword; 3: the line again; 4-5: SPE1 superpage).

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

	.org	0x4000
init:
	hw_mtpr	$31, 0x29			// PS = kernel
	lda	$1, 0x400($31)			// ABOX_CTL: DC_ENA
	hw_mtpr/a $1, 0xe
	lda	$2, 600($31)			// the D-cache's clearing sweep (256 cycles)
1:	subq	$2, 1, $2
	bne	$2, 1b

	// step 1: quadwords, line 0x7000
	lda	$6, 0x7000($31)
	hw_ldq/p $7, 8($6)			// miss: fills the line
	lda	$8, 0x5a5a($31)
	hw_stq/p $8, 0($6)			// into the line being filled
	hw_ldq/p $4, 0($6)
	bis	$8, $31, $3
	CHECK	1

	// step 2: longwords, line 0x7020
	lda	$6, 0x7020($31)
	hw_ldl/p $7, 8($6)
	lda	$8, 0x1234($31)
	hw_stl/p $8, 0($6)
	hw_ldl/p $4, 0($6)
	bis	$8, $31, $3
	CHECK	2

	// step 3: the line filled in step 1 still holds the store
	lda	$6, 0x7000($31)
	hw_ldq/p $4, 0($6)
	lda	$3, 0x5a5a($31)
	CHECK	3

	// steps 4-5: the same through the SPE1 superpage (VA ffffffff8xxxxxxx ->
	// PA<29:0>) with ordinary loads and stores, as ARC runs (kernel, KSEG)
	lda	$1, 0x410($31)			// ABOX_CTL: DC_ENA, SPE1
	hw_mtpr/a $1, 0xe
	lda	$2, 600($31)			// (the D-cache enable did not change: no sweep)
1:	subq	$2, 1, $2
	bne	$2, 1b
	ldah	$6, -32768($31)			// ffffffff80000000
	lda	$6, 0x7040($6)
	ldl	$7, 8($6)			// miss: fills line 0x7040
	lda	$8, 0x2468($31)
	stl	$8, 0($6)
	ldl	$4, 0($6)
	bis	$8, $31, $3
	CHECK	4
	ldah	$6, -32768($31)
	lda	$6, 0x7060($6)
	ldq	$7, 16($6)			// miss: fills line 0x7060
	lda	$8, 0x1357($31)
	stq	$8, 8($6)
	ldq	$4, 8($6)
	bis	$8, $31, $3
	CHECK	5
	br	$31, pass

pass:	lda	$6, 0x80($31)
	sll	$6, 16, $6
	lda	$1, 1($31)
	hw_stq/p $1, 0($6)
1:	br	$31, 1b

fail:	lda	$6, 0x80($31)
	sll	$6, 16, $6
	hw_stq/p $4, 8($6)
	hw_stq/p $3, 16($6)
	sll	$0, 1, $0
	addq	$0, 1, $0
	hw_stq/p $0, 0($6)
1:	br	$31, 1b

	.org	0x7000
	.quad	0x1111111111111111, 0x2222222222222222, 0x3333333333333333, 0x4444444444444444
	.quad	0x5555555555555555, 0x6666666666666666, 0x7777777777777777, 0x8888888888888888
	.quad	0x9999999999999999, 0xaaaaaaaaaaaaaaaa, 0xbbbbbbbbbbbbbbbb, 0xcccccccccccccccc
	.quad	0xdddddddddddddddd, 0xeeeeeeeeeeeeeeee, 0x0f0f0f0f0f0f0f0f, 0xf0f0f0f0f0f0f0f0
