/* SPDX-License-Identifier: BSD-3-Clause
 * Test ADD and ADDI instructions.
 *
 * Error codes:
 *   2  – ADDI positive immediate wrong
 *   3  – ADDI negative immediate wrong
 *   4  – ADDI accumulate wrong
 *   5  – ADD basic wrong
 *   6  – ADD with negative operand wrong
 *   7  – ADD signed overflow (wraps) wrong
 *   8  – ADD x0 operand wrong
 *   9  – ADDI zero register wrong
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* ---- ADDI ---- */

    /* Test 2: ADDI with positive immediate */
    addi    t0, zero, 42
    CHECK_EQ(t0, 42, 2)

    /* Test 3: ADDI with negative immediate (sign-extends to 32 bits) */
    addi    t0, zero, -1
    CHECK_EQ(t0, -1, 3)

    /* Test 4: ADDI accumulate */
    li      t0, 100
    addi    t0, t0, 50
    CHECK_EQ(t0, 150, 4)

    /* ---- ADD ---- */

    /* Test 5: ADD basic */
    li      t0, 7
    li      t1, 3
    add     t2, t0, t1
    CHECK_EQ(t2, 10, 5)

    /* Test 6: ADD with negative operand */
    li      t0, 5
    li      t1, -3
    add     t2, t0, t1
    CHECK_EQ(t2, 2, 6)

    /* Test 7: ADD signed overflow wraps (two's complement) */
    li      t0, 0x7fffffff
    li      t1, 1
    add     t2, t0, t1
    CHECK_EQ(t2, 0x80000000, 7)

    /* Test 8: ADD with x0 source – result equals the other operand */
    li      t0, 0xdeadbeef
    add     t2, t0, zero
    CHECK_EQ(t2, 0xdeadbeef, 8)

    /* Test 9: ADDI into x0 – x0 stays 0 */
    addi    zero, zero, 99
    CHECK_EQ(zero, 0, 9)

    TEST_PASS
