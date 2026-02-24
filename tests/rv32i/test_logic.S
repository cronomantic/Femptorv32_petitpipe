/* SPDX-License-Identifier: BSD-3-Clause
 * Test logical instructions: AND, OR, XOR and their immediate variants
 * ANDI, ORI, XORI.
 *
 * Error codes:
 *   2  – AND wrong
 *   3  – AND with zero wrong
 *   4  – ANDI wrong
 *   5  – OR wrong
 *   6  – OR with zero wrong
 *   7  – ORI wrong
 *   8  – XOR wrong
 *   9  – XOR self-clear wrong
 *  10  – XORI wrong
 *  11  – XORI bitwise-not (XOR with -1) wrong
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* ---- AND / ANDI ---- */

    /* Test 2: AND basic */
    li      t0, 0xff00ff00
    li      t1, 0x0f0f0f0f
    and     t2, t0, t1
    CHECK_EQ(t2, 0x0f000f00, 2)

    /* Test 3: AND with zero produces zero */
    li      t0, 0xdeadbeef
    and     t2, t0, zero
    CHECK_EQ(t2, 0, 3)

    /* Test 4: ANDI with sign-extended immediate */
    li      t0, 0x000000ff
    andi    t2, t0, 0x0f
    CHECK_EQ(t2, 0x0f, 4)

    /* ---- OR / ORI ---- */

    /* Test 5: OR basic */
    li      t0, 0xf0f0f0f0
    li      t1, 0x0f0f0f0f
    or      t2, t0, t1
    CHECK_EQ(t2, 0xffffffff, 5)

    /* Test 6: OR with zero leaves value unchanged */
    li      t0, 0xdeadbeef
    or      t2, t0, zero
    CHECK_EQ(t2, 0xdeadbeef, 6)

    /* Test 7: ORI */
    li      t0, 0x00000000
    ori     t2, t0, 0x7ff
    CHECK_EQ(t2, 0x7ff, 7)

    /* ---- XOR / XORI ---- */

    /* Test 8: XOR basic */
    li      t0, 0xaaaaaaaa
    li      t1, 0x55555555
    xor     t2, t0, t1
    CHECK_EQ(t2, 0xffffffff, 8)

    /* Test 9: XOR self-clear (x ^ x == 0) */
    li      t0, 0xdeadbeef
    xor     t2, t0, t0
    CHECK_EQ(t2, 0, 9)

    /* Test 10: XORI */
    li      t0, 0x0000000f
    xori    t2, t0, 0x0f
    CHECK_EQ(t2, 0, 10)

    /* Test 11: XORI with -1 is bitwise NOT */
    li      t0, 0xdeadbeef
    xori    t2, t0, -1
    CHECK_EQ(t2, 0x21524110, 11)

    TEST_PASS
