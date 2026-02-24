/* SPDX-License-Identifier: BSD-3-Clause
 * Test shift instructions: SLL, SRL, SRA and their immediate variants
 * SLLI, SRLI, SRAI.
 *
 * Error codes:
 *   2  – SLL basic wrong
 *   3  – SLL by zero wrong
 *   4  – SLLI wrong
 *   5  – SRL basic (logical, fills with 0) wrong
 *   6  – SRL of signed value (high bits 0) wrong
 *   7  – SRLI wrong
 *   8  – SRA basic (arithmetic, fills with sign bit) wrong
 *   9  – SRA of positive value (same as SRL) wrong
 *  10  – SRAI wrong
 *  11  – Shift amount uses only low 5 bits
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* ---- SLL / SLLI ---- */

    /* Test 2: SLL basic */
    li      t0, 1
    li      t1, 4
    sll     t2, t0, t1
    CHECK_EQ(t2, 16, 2)

    /* Test 3: SLL by zero – value unchanged */
    li      t0, 0xdeadbeef
    li      t1, 0
    sll     t2, t0, t1
    CHECK_EQ(t2, 0xdeadbeef, 3)

    /* Test 4: SLLI by 1 */
    li      t0, 0x00000001
    slli    t2, t0, 31
    CHECK_EQ(t2, 0x80000000, 4)

    /* ---- SRL / SRLI ---- */

    /* Test 5: SRL basic (logical right shift, zero-fills) */
    li      t0, 0x80000000
    li      t1, 1
    srl     t2, t0, t1
    CHECK_EQ(t2, 0x40000000, 5)

    /* Test 6: SRL of negative value – high bits become 0 */
    li      t0, 0xffffffff
    li      t1, 4
    srl     t2, t0, t1
    CHECK_EQ(t2, 0x0fffffff, 6)

    /* Test 7: SRLI */
    li      t0, 0x000000f0
    srli    t2, t0, 4
    CHECK_EQ(t2, 0x0000000f, 7)

    /* ---- SRA / SRAI ---- */

    /* Test 8: SRA of negative value – high bits sign-extend (fill with 1) */
    li      t0, 0x80000000
    li      t1, 4
    sra     t2, t0, t1
    CHECK_EQ(t2, 0xf8000000, 8)

    /* Test 9: SRA of positive value – high bits fill with 0 (same as SRL) */
    li      t0, 0x7fffffff
    li      t1, 4
    sra     t2, t0, t1
    CHECK_EQ(t2, 0x07ffffff, 9)

    /* Test 10: SRAI sign-extending */
    li      t0, 0xfffffff0
    srai    t2, t0, 4
    CHECK_EQ(t2, 0xffffffff, 10)

    /* Test 11: Shift amount is masked to low 5 bits (rv32i spec §2.4) */
    li      t0, 1
    li      t1, 32          /* 32 & 0x1f == 0, so SLL by 0 */
    sll     t2, t0, t1
    CHECK_EQ(t2, 1, 11)

    TEST_PASS
