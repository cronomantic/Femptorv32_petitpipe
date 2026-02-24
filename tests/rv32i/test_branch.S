/* SPDX-License-Identifier: BSD-3-Clause
 * Test branch instructions: BEQ, BNE, BLT, BGE, BLTU, BGEU.
 *
 * Strategy: each test verifies both the "taken" and "not-taken" paths.
 * A branch that should be taken loads a "pass" value; one that should not
 * be taken skips over a failure trap.
 *
 * Error codes:
 *   2  – BEQ taken wrong
 *   3  – BEQ not-taken wrong
 *   4  – BNE taken wrong
 *   5  – BNE not-taken wrong
 *   6  – BLT taken wrong
 *   7  – BLT not-taken wrong
 *   8  – BGE taken (greater) wrong
 *   9  – BGE taken (equal) wrong
 *  10  – BGE not-taken wrong
 *  11  – BLTU taken (unsigned) wrong
 *  12  – BLTU not-taken (large unsigned) wrong
 *  13  – BGEU taken wrong
 *  14  – BGEU not-taken wrong
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* ---- BEQ ---- */

    /* Test 2: BEQ taken when equal */
    li      t0, 42
    li      t1, 42
    beq     t0, t1, 1f
    TEST_FAIL(2)
1:
    /* Test 3: BEQ not taken when not equal */
    li      t0, 1
    li      t1, 2
    beq     t0, t1, 2f
    j       3f
2:  TEST_FAIL(3)
3:

    /* ---- BNE ---- */

    /* Test 4: BNE taken when not equal */
    li      t0, 1
    li      t1, 2
    bne     t0, t1, 4f
    TEST_FAIL(4)
4:
    /* Test 5: BNE not taken when equal */
    li      t0, 99
    li      t1, 99
    bne     t0, t1, 5f
    j       6f
5:  TEST_FAIL(5)
6:

    /* ---- BLT (signed) ---- */

    /* Test 6: BLT taken (-1 < 0) */
    li      t0, -1
    li      t1, 0
    blt     t0, t1, 7f
    TEST_FAIL(6)
7:
    /* Test 7: BLT not taken (5 >= 3) */
    li      t0, 5
    li      t1, 3
    blt     t0, t1, 8f
    j       9f
8:  TEST_FAIL(7)
9:

    /* ---- BGE (signed) ---- */

    /* Test 8: BGE taken when greater */
    li      t0, 10
    li      t1, 5
    bge     t0, t1, 10f
    TEST_FAIL(8)
10:
    /* Test 9: BGE taken when equal */
    li      t0, 7
    li      t1, 7
    bge     t0, t1, 11f
    TEST_FAIL(9)
11:
    /* Test 10: BGE not taken when less */
    li      t0, 3
    li      t1, 7
    bge     t0, t1, 12f
    j       13f
12: TEST_FAIL(10)
13:

    /* ---- BLTU (unsigned) ---- */

    /* Test 11: BLTU taken (1 < 0x80000000 unsigned) */
    li      t0, 1
    li      t1, 0x80000000
    bltu    t0, t1, 14f
    TEST_FAIL(11)
14:
    /* Test 12: BLTU not taken (0xffffffff >= 1 unsigned) */
    li      t0, 0xffffffff
    li      t1, 1
    bltu    t0, t1, 15f
    j       16f
15: TEST_FAIL(12)
16:

    /* ---- BGEU (unsigned) ---- */

    /* Test 13: BGEU taken (0x80000000 >= 1 unsigned) */
    li      t0, 0x80000000
    li      t1, 1
    bgeu    t0, t1, 17f
    TEST_FAIL(13)
17:
    /* Test 14: BGEU not taken (1 < 0x80000000 unsigned) */
    li      t0, 1
    li      t1, 0x80000000
    bgeu    t0, t1, 18f
    j       19f
18: TEST_FAIL(14)
19:

    TEST_PASS
