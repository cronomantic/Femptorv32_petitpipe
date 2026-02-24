/* SPDX-License-Identifier: BSD-3-Clause
 * Test set-less-than instructions: SLT, SLTU, SLTI, SLTIU.
 *
 * Error codes:
 *   2  – SLT: smaller signed value gives 1 wrong
 *   3  – SLT: equal values give 0 wrong
 *   4  – SLT: larger signed value gives 0 wrong
 *   5  – SLT: sign matters (negative < positive) wrong
 *   6  – SLTI basic wrong
 *   7  – SLTI negative immediate wrong
 *   8  – SLTU: treats values as unsigned (0x80000000 > 1) wrong
 *   9  – SLTU: 0 is smallest unsigned wrong
 *  10  – SLTIU basic wrong
 *  11  – SLTIU: -1 as unsigned is 0xffffffff, larger than any signed value wrong
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* ---- SLT (signed) ---- */

    /* Test 2: 3 < 7 (signed) → 1 */
    li      t0, 3
    li      t1, 7
    slt     t2, t0, t1
    CHECK_EQ(t2, 1, 2)

    /* Test 3: equal → 0 */
    li      t0, 5
    li      t1, 5
    slt     t2, t0, t1
    CHECK_EQ(t2, 0, 3)

    /* Test 4: 7 < 3 → 0 */
    li      t0, 7
    li      t1, 3
    slt     t2, t0, t1
    CHECK_EQ(t2, 0, 4)

    /* Test 5: -1 < 0 (signed) → 1 */
    li      t0, -1
    li      t1, 0
    slt     t2, t0, t1
    CHECK_EQ(t2, 1, 5)

    /* ---- SLTI ---- */

    /* Test 6: 3 < 10 → 1 */
    li      t0, 3
    slti    t2, t0, 10
    CHECK_EQ(t2, 1, 6)

    /* Test 7: -5 < -3 → 1 */
    li      t0, -5
    slti    t2, t0, -3
    CHECK_EQ(t2, 1, 7)

    /* ---- SLTU (unsigned) ---- */

    /* Test 8: 0x80000000 > 1 when treated as unsigned → slt gives 0 */
    li      t0, 0x80000000
    li      t1, 1
    sltu    t2, t0, t1
    CHECK_EQ(t2, 0, 8)

    /* Test 9: 0 is the smallest unsigned value → 0 < 1 → 1 */
    li      t0, 0
    li      t1, 1
    sltu    t2, t0, t1
    CHECK_EQ(t2, 1, 9)

    /* ---- SLTIU ---- */

    /* Test 10: 3 < 10 (unsigned) → 1 */
    li      t0, 3
    sltiu   t2, t0, 10
    CHECK_EQ(t2, 1, 10)

    /* Test 11: -1 sign-extends to 0xffffffff (max unsigned);
                0 < 0xffffffff → 1 */
    li      t0, 0
    sltiu   t2, t0, -1
    CHECK_EQ(t2, 1, 11)

    TEST_PASS
