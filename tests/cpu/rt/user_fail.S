// The T0 failure report for the qemu-alpha user build (rt/t0.h, T0_USER):
// "T0 FAIL <test> got <result> exp <expected>" on stderr, then exit(1).
// Byte stores are built from quadwords: EV4 has no BWX.

	.set noreorder
	.set noat
	.set nomacro

// \q = eight hex digits of \v, bits <\sh+31:\sh>, first digit in byte 0
	.macro	HEX8 v, sh, q
	bis	$31, $31, \q
	bis	$31, $31, $22		// byte shift
	lda	$23, \sh+28($31)	// bit shift of the digit
1:	srl	\v, $23, $24
	and	$24, 15, $24
	cmpult	$24, 10, $25
	addq	$24, 0x30, $24		// '0'
	bne	$25, 2f
	addq	$24, 0x27, $24		// 'a' - '0' - 10
2:	sll	$24, $22, $24
	bis	\q, $24, \q
	addq	$22, 8, $22
	subq	$23, 4, $23
	cmplt	$22, 64, $25
	bne	$25, 1b
	.endm

	.text
	.globl	fail
fail:
	bis	$0, $0, $9
	bis	$4, $4, $10
	bis	$3, $3, $11
	lda	$30, -80($30)
	.align	3
	nop
	br	$1, 1f
	.ascii	"T0 FAIL "
	.ascii	" got    "
	.ascii	" exp    "
1:	ldq	$2, 0($1)
	stq	$2, 0($30)
	HEX8	$9, 32, $2
	stq	$2, 8($30)
	HEX8	$9, 0, $2
	stq	$2, 16($30)
	ldq	$2, 8($1)
	stq	$2, 24($30)
	HEX8	$10, 32, $2
	stq	$2, 32($30)
	HEX8	$10, 0, $2
	stq	$2, 40($30)
	ldq	$2, 16($1)
	stq	$2, 48($30)
	HEX8	$11, 32, $2
	stq	$2, 56($30)
	HEX8	$11, 0, $2
	stq	$2, 64($30)
	lda	$2, 10($31)		// "\n"
	stq	$2, 72($30)
	lda	$0, 4($31)		// write(2, buf, 73)
	lda	$16, 2($31)
	bis	$30, $30, $17
	lda	$18, 73($31)
	call_pal 0x83
	lda	$0, 1($31)		// exit(1)
	lda	$16, 1($31)
	call_pal 0x83
