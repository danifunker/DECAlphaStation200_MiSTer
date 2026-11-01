// T3: the ITB and DTB (docs/design/cpu.md 4.2, 4.3, 6). A PALmode image at
// PA 0 that checks itself; pass/fail to TOHOST (PA 0x800000) like T0:
// 1 = pass, (n << 1) | 1 = step n failed (+8 = got, +16 = expected).
//
//   1  DTB fill (TB_TAG, TB_CTL, DTB_PTE): a load through VA 0x200008 reads
//      PA 0x100008
//   2  a store through the mapping lands at the physical address
//   3  a DTB miss (VA 0x400010) enters DTB_MISS PAL (0x9E0) with VA in the VA IPR
//   4  ... and MM_CSR = opcode LDQ (0x29) << 9 | Ra << 4, WR = 0
//   5  an ACV: PS = user, the mapping has KRE only -> D_FAULT (0x1E0), MM_CSR.ACV
//   6  DTB_PTE read -> DTB_PTE_TEMP has the PFN and KRE/KWE of entry 0
//   7  DTBIS of VA 0x200000, then the load misses again (DTB_MISS)
//   8  the ITB: VA 0x10000000 -> PA 0x6000 (KRE), HW_REI into it in kernel
//      mode (MAP off): the code there runs and CALL_PALs back with r21 = 0x77
//
// Only the pipelined core has TBs: make -C verilator t3

	.set noreorder
	.set noat
	.set nomacro

#define TOHOST_HI	0x80			// TOHOST = 0x80 << 16

	// report: step n failed, got r4, expected r3 (PALmode: physical stores)
	.macro	CHECK n
	cmpeq	$4, $3, $5
	lda	$0, \n($31)
	beq	$5, fail
	.endm

	.text
	.globl	_start
_start:
	br	$31, init

	.org	0x01E0				// D_FAULT
	hw_mfpr	$22, 0x44			// MM_CSR
	hw_mfpr	$23, 0x45			// VA (unlocks)
	lda	$20, 2($31)			// fault seen: 2
	br	$31, skip
	.org	0x03E0				// ITB_MISS: unexpected
	lda	$0, 90($31)
	br	$31, fail
	.org	0x07E0				// ITB_ACV: unexpected
	lda	$0, 91($31)
	br	$31, fail
	.org	0x09E0				// DTB_MISS (PAL)
	hw_mfpr	$22, 0x44			// MM_CSR
	hw_mfpr	$23, 0x45			// VA (unlocks)
	lda	$20, 1($31)			// miss seen: 1
	br	$31, skip
	.org	0x13E0				// OPCDEC: unexpected
	lda	$0, 92($31)
	br	$31, fail

	// the exception handlers return to the instruction after the fault
skip:	hw_mfpr	$24, 0x24			// EXC_ADDR
	addq	$24, 4, $24
	hw_mtpr	$24, 0x24
	hw_rei

	.org	0x3640				// CALL_PAL 0x99 (unprivileged 0x80 + 0x19)
	lda	$4, 0($21)
	lda	$3, 0x77($31)
	CHECK	8
	br	$31, pass

	.org	0x4000
init:
	hw_mtpr	$31, 0x29			// PS = kernel
	hw_mtpr	$31, 0x46			// DTBZAP
	hw_mtpr	$31, 0x26			// ITBZAP
	lda	$10, 0x10($31)
	sll	$10, 16, $10			// r10 = PA 0x100000 (the data page)
	lda	$11, 0x20($31)
	sll	$11, 16, $11			// r11 = VA 0x200000

	// test data at PA 0x100008
	lda	$1, 0x1234($31)
	sll	$1, 16, $1
	lda	$1, 0x5678($1)
	hw_stq/p $1, 8($10)

	// ---- 1: a DTB entry VA 0x200000 -> PA 0x100000, KRE | KWE, 8 KB pages
	hw_mtpr	$31, 0x40			// TB_CTL: GH = 0
	hw_mtpr	$11, 0x20			// TB_TAG
	sll	$10, 19, $2			// PFN (PA >> 13) in [52:32]: PA << 19
	lda	$3, 0x1100($31)			// KWE (12) | KRE (8)
	bis	$2, $3, $2
	hw_mtpr	$2, 0x42			// DTB_PTE
	ldq	$4, 8($11)			// through the DTB
	bis	$1, $31, $3
	CHECK	1

	// ---- 2: a store through it, read back physically
	lda	$5, 0x4242($31)
	stq	$5, 16($11)
	mb
	hw_ldq/p $4, 16($10)
	bis	$5, $31, $3
	CHECK	2

	// ---- 3, 4: a DTB miss at VA 0x400010
	bis	$31, $31, $20
	lda	$6, 0x40($31)
	sll	$6, 16, $6
	ldq	$7, 16($6)			// misses -> 0x9E0, which sets r20 = 1
	bis	$20, $31, $4
	lda	$3, 1($31)
	CHECK	3
	bis	$23, $31, $4			// the VA
	lda	$3, 16($6)
	CHECK	3
	bis	$22, $31, $4			// MM_CSR: opcode 0x29, Ra 7, not a write
	lda	$3, (0x29 << 9) | (7 << 4)($31)
	CHECK	4

	// ---- 5: an ACV: user mode, the mapping has no URE
	bis	$31, $31, $20
	lda	$1, 0x18($31)
	hw_mtpr	$1, 0x29			// PS = user (CM = 3)
	ldq	$7, 8($11)			// -> D_FAULT (0x1E0), r20 = 2
	hw_mtpr	$31, 0x29			// PS = kernel
	bis	$20, $31, $4
	lda	$3, 2($31)
	CHECK	5
	and	$22, 2, $4			// MM_CSR.ACV
	lda	$3, 2($31)
	CHECK	5

	// ---- 6: DTB_PTE read: entry 0 (the pointer wrapped? no: it is at 1 -
	// zap and refill so the read sees entry 0)
	hw_mtpr	$31, 0x46			// DTBZAP: pointer 0
	hw_mtpr	$11, 0x20			// TB_TAG
	sll	$10, 19, $2
	lda	$3, 0x1100($31)
	bis	$2, $3, $2
	hw_mtpr	$2, 0x42			// DTB_PTE -> entry 0, pointer 1
	lda	$8, 31($31)			// advance the pointer to 0 again: 31 reads
1:	hw_mfpr	$31, 0x42
	subq	$8, 1, $8
	bne	$8, 1b
	hw_mfpr	$31, 0x42			// entry 0 -> DTB_PTE_TEMP
	hw_mfpr	$4, 0x43			// DTB_PTE_TEMP: [33:13] PFN, [9] KRE, [5] KWE
	srl	$10, 13, $3			// PFN
	sll	$3, 13, $3
	lda	$3, 0x220($3)
	CHECK	6

	// ---- 7: DTBIS, then a miss
	hw_mtpr	$11, 0x48			// DTBIS VA 0x200000
	bis	$31, $31, $20
	ldq	$7, 8($11)			// misses now
	bis	$20, $31, $4
	lda	$3, 1($31)
	CHECK	7

	// ---- 8: the ITB: VA 0x10000000 -> PA 0x6000, KRE
	hw_mtpr	$31, 0x40			// TB_CTL: small page
	lda	$12, 0x1000($31)
	sll	$12, 16, $12			// VA 0x10000000
	hw_mtpr	$12, 0x20			// TB_TAG
	lda	$2, 0x6000($31)
	sll	$2, 19, $2			// PFN of PA 0x6000
	lda	$2, 0x100($2)			// KRE
	hw_mtpr	$2, 0x21			// ITB_PTE
	bis	$31, $31, $21
	hw_mtpr	$12, 0x24			// EXC_ADDR = VA 0x10000000, native
	bis	$31, $31, $31
	bis	$31, $31, $31
	hw_rei					// -> PA 0x6000 through the ITB

pass:	lda	$6, TOHOST_HI($31)
	sll	$6, 16, $6
	lda	$1, 1($31)
	hw_stq/p $1, 0($6)
1:	br	$31, 1b

fail:	lda	$6, TOHOST_HI($31)
	sll	$6, 16, $6
	hw_stq/p $4, 8($6)
	hw_stq/p $3, 16($6)
	sll	$0, 1, $1
	bis	$1, 1, $1
	hw_stq/p $1, 0($6)
1:	br	$31, 1b

	// the code the ITB maps (PA 0x6000), run in kernel mode
	.org	0x6000
	lda	$21, 0x77($31)
	call_pal 0x99
1:	br	$31, 1b
