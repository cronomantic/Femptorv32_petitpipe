/* SPDX-License-Identifier: BSD-3-Clause
 * Test SUB instruction.
 * (RISC-V has no SUBI; use ADDI with a negative immediate instead.)
 *
 * Error codes:
 *   2  – SUB basic wrong
 *   3  – SUB result is zero wrong
 *   4  – SUB with negative operand wrong
 *   5  – SUB underflow (wraps) wrong
 *   6  – SUB into x0 wrong
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* Test 2: SUB basic */
    li      t0, 10
    li      t1, 3
    sub     t2, t0, t1
    CHECK_EQ(t2, 7, 2)

    /* Test 3: SUB result is zero (same operands) */
    li      t0, 42
    sub     t2, t0, t0
    CHECK_EQ(t2, 0, 3)

    /* Test 4: SUB with negative second operand (equivalent to addition) */
    li      t0, 5
    li      t1, -3
    sub     t2, t0, t1
    CHECK_EQ(t2, 8, 4)

    /* Test 5: SUB underflow wraps (two's complement) */
    li      t0, 0x80000000
    li      t1, 1
    sub     t2, t0, t1
    CHECK_EQ(t2, 0x7fffffff, 5)

    /* Test 6: SUB into x0 – x0 must remain 0 */
    li      t0, 5
    li      t1, 3
    sub     zero, t0, t1
    CHECK_EQ(zero, 0, 6)

    TEST_PASS
