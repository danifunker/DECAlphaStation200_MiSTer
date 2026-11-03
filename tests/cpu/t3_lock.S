// T3: the lock flag (docs/design/cpu.md 9.1). On the AS200 the 21071-CA holds it, and any
// STx_C or any CPU write to I/O space clears it: an interrupt handler's 8259 EOI between a
// thread's LDx_L and STx_C makes the STx_C fail. Native kernel code through KSEG (T0 harness),
// an I/O write to PA 0x2_0000_0000 (needs tb_cpu --iosink). Pass/fail to TOHOST as in T0:
//   1  LDL_L / STL_C: succeeds
//   2  LDL_L, a store to other memory, STL_C: succeeds
//   3  LDL_L, an I/O write, STL_C: fails
//   4  ... and memory kept the old value
//   5  LDQ_L, STQ_C, STQ_C again: the second fails (STx_C clears the flag)

#include "t0.h"

	.macro	CHECK n
	cmpeq	$4, $3, $5
	lda	$0, \n($31)
	beq	$5, fail
	.endm

TEST_BEGIN
	lda	$9, -1($31)
	sll	$9, 42, $9			// KSEG
	ldah	$10, 0x10($9)			// PA 0x100000: the locked longword
	ldah	$11, 0x11($9)			// PA 0x110000: other memory
	lda	$12, 1($31)
	sll	$12, 33, $12
	bis	$12, $9, $12			// PA 0x2_0000_0000: I/O space
	stq	$31, 0($10)
	// 1
	ldl_l	$1, 0($10)
	lda	$1, 5($1)
	stl_c	$1, 0($10)
	bis	$1, $31, $4
	lda	$3, 1($31)
	CHECK	1
	// 2
	ldl_l	$1, 0($10)
	stq	$1, 0($11)
	lda	$1, 7($1)
	stl_c	$1, 0($10)
	bis	$1, $31, $4
	lda	$3, 1($31)
	CHECK	2
	// 3, 4
	ldl_l	$1, 0($10)
	stl	$31, 0($12)
	lda	$1, 100($1)
	stl_c	$1, 0($10)
	bis	$1, $31, $4
	bis	$31, $31, $3
	CHECK	3
	ldl	$4, 0($10)
	lda	$3, 12($31)
	CHECK	4
	// 5
	ldq_l	$1, 0($10)
	lda	$2, 1($1)
	stq_c	$2, 0($10)
	lda	$2, 2($1)
	stq_c	$2, 0($10)
	bis	$2, $31, $4
	bis	$31, $31, $3
	CHECK	5
TEST_PASS
TEST_END
