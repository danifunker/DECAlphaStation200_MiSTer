// T0 bare-metal build (rt/t0.h without T0_USER): the image is loaded at
// PA 0 and the CPU starts there in PALmode (docs/design/cpu.md 1.2, 1.4:
// icmode = 1, empty I-cache). Layout:
//
//   0x0000          reset: branch to t0_init
//   0x0020..0x17E0  the PAL entry points (cpu.md 5.1); each reports an
//                   unexpected exception
//   0x2000..0x3FC0  the CALL_PAL entries, likewise
//   0x4000          t0_init: superpages on (ICCSR.MAP, ABOX_CTL.SPE_2 +
//                   DC_ENA), PS = kernel, then HW_REI into the test body at
//                   its KSEG address 0xFFFFFC00_0000_0000 + PA (cpu.md 6.2, 6.3)
//
// TOHOST (PA 0x800000; KSEG 0xFFFFFC0000800000) gets one quadword:
//   1                          pass
//   (n << 1) | 1               test n failed; +8 = result, +16 = expected
//   (1 << 63) | (off << 1) | 1 unexpected exception at PAL offset off;
//                              +8 = EXC_ADDR
// after which the CPU spins on a branch to itself.

#define T0_TOHOST_HI	0x80		// TOHOST = T0_TOHOST_HI << 16
#define T0_IRQACK_HI	0x70		// T0_IRQ: the interrupt acknowledge, PA 0x700000

	.macro	T0_VEC off
	.org	\off
	lda	$27, \off($31)
	br	$31, t0_trap
	.endm

	// $\r = KSEG address of TOHOST
	.macro	T0_TOHOST r
	lda	\r, -1($31)
	sll	\r, 42, \r
	ldah	\r, T0_TOHOST_HI(\r)
	.endm

	.macro	TEST_BEGIN
	.text
	.globl	_start
_start:
	br	$31, t0_init
	T0_VEC	0x0020			// MCHK
	T0_VEC	0x0060			// ARITH
#ifdef T0_IRQ
	// T0_IRQ: a transparent handler for irq_h[0] (tb_cpu IRQRATE): $1 saved in
	// PAL_TEMP 0, a physical store to T0_IRQACK drops the line, nothing else changes
	.org	0x00E0
	hw_mtpr	$1, 0x80
	lda	$1, T0_IRQACK_HI($31)
	sll	$1, 16, $1
	hw_stq/p $31, 0($1)
	hw_mfpr	$1, 0x80
	hw_rei
#else
	T0_VEC	0x00E0			// INTERRUPT
#endif
	T0_VEC	0x01E0			// D_FAULT
	T0_VEC	0x03E0			// ITB_MISS
	T0_VEC	0x07E0			// ITB_ACV
#ifdef T0_DTBFILL
	// T0_DTBFILL (tests/cpu/gen_vmx.py): native DTB misses are filled from 64 PTEs at
	// PA 0x7F0000 indexed by VA<18:13>; $1, $2 saved in PAL_TEMP 1, 2
	.org	0x08E0
	hw_mtpr	$1, 0x81
	hw_mtpr	$2, 0x82
	hw_mfpr	$1, 0x45		// VA (unlocks it)
	hw_mtpr	$31, 0x40		// TB_CTL: an 8 KB page
	hw_mtpr	$1, 0x20		// TB_TAG
	srl	$1, 13, $1
	and	$1, 63, $1
	lda	$2, 0x7F($31)
	sll	$2, 16, $2
	s8addq	$1, $2, $1
	hw_ldq/p $2, 0($1)
	hw_mtpr	$2, 0x42		// DTB_PTE: the entry is written
	hw_mfpr	$1, 0x81
	hw_mfpr	$2, 0x82
	hw_rei				// the instruction runs again
#else
	T0_VEC	0x08E0			// DTB_MISS native
#endif
	T0_VEC	0x09E0			// DTB_MISS PAL
	T0_VEC	0x11E0			// UNALIGN
	T0_VEC	0x13E0			// OPCDEC
	T0_VEC	0x17E0			// FEN
	.irp	h, 0,1,2,3,4,5,6,7	// CALL_PAL 00-3F, 80-BF: 0x2000 + 0x40 n
	.irp	l, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
	T0_VEC	(0x2000+(\h*16+\l)*0x40)
	.endr
	.endr

	// PALmode: report the exception with physical stores
t0_trap:
	hw_mfpr	$26, 0x24		// EXC_ADDR
	lda	$6, T0_TOHOST_HI($31)
	sll	$6, 16, $6
	hw_stq/p $26, 8($6)
	lda	$1, 1($31)
	sll	$1, 63, $1
	sll	$27, 1, $27
	bis	$1, $27, $1
	bis	$1, 1, $1
	hw_stq/p $1, 0($6)
1:	br	$31, 1b

	.org	0x4000
t0_init:
#ifdef T0_SPE1
	lda	$1, 0x430($31)		// ABOX_CTL: DC_ENA (10) | SPE_2 (5) | SPE_1 (4)
#else
	lda	$1, 0x420($31)		// ABOX_CTL: DC_ENA (10) | SPE_2 (5)
#endif
	hw_mtpr	$1, 0x4e
	lda	$1, 1($31)
	sll	$1, 41, $1		// ICCSR: MAP (write bit 41); FP off
	hw_mtpr	$1, 0x22
	hw_mtpr	$31, 0x29		// PS: kernel
#ifdef T0_IRQ
	lda	$1, 0x200($31)		// HIER: irq_h[0] (write bit 9)
	hw_mtpr	$1, 0x30
#endif
	lda	$3, -1($31)
	sll	$3, 42, $3		// KSEG base 0xFFFFFC0000000000
	br	$2, 1f
1:	lda	$2, t0_body-1b($2)
	bis	$2, $3, $2		// bit 0 clear: leave PALmode
	hw_mtpr	$2, 0x24		// EXC_ADDR
	bis	$31, $31, $31		// the chip's IPR-to-HW_REI spacing (cpu.md 3.4)
	bis	$31, $31, $31
	bis	$31, $31, $31
	hw_rei
	.align	3
t0_body:
	.endm

	.macro	TEST_PASS
	T0_TOHOST $6
	lda	$1, 1($31)
	stq	$1, 0($6)
1:	br	$31, 1b
	.endm

	.macro	TEST_END
fail:
	T0_TOHOST $6
	stq	$4, 8($6)
	stq	$3, 16($6)
	sll	$0, 1, $1
	bis	$1, 1, $1
	stq	$1, 0($6)
1:	br	$31, 1b
	.endm
