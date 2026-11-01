// T0 test runtime (tests/cpu/README.md). A suite body runs from TEST_BEGIN to
// TEST_PASS with its test number in $0; a mismatch branches to `fail` with
// the result in $4 and the expected value in $3.
//
//   T0_USER  a Linux user program for `qemu-alpha -cpu ev4`: exit status 0 on
//            pass; on failure "T0 FAIL <n> got <x> exp <y>" on stderr, status 1.
//            No libc (the distribution's glibc uses BWX, which EV4 lacks).
//   (else)   the bare-metal build for the RTL harness and alphaemu: the PAL
//            harness enters the body; pass/fail goes to TOHOST (t0_pal.h).
//
// Only EV4 instructions: no BWX (byte/word loads and stores), FIX, CIX or MVI.

	.set noreorder
	.set noat
	.set nomacro

#ifdef T0_USER

#define TEST_BEGIN		\
	.text;			\
	.globl _start;		\
_start:

#define TEST_PASS		\
	lda	$0, 1($31);	/* exit */ \
	bis	$31, $31, $16;	\
	call_pal 0x83

#define TEST_END		/* `fail` is in rt/user_fail.S */

#else
#include "t0_pal.h"
#endif
