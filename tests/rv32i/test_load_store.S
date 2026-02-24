/* SPDX-License-Identifier: BSD-3-Clause
 * Test load and store instructions:
 *   SW, SH, SB (store word / half-word / byte)
 *   LW, LH, LHU, LB, LBU (load word / half-word signed+unsigned / byte signed+unsigned)
 *
 * Data area is placed in .data to keep it separate from code.
 *
 * Error codes:
 *   2  – SW/LW round-trip wrong
 *   3  – SW then LW of different word wrong
 *   4  – SH/LH signed half-word wrong
 *   5  – SH/LHU unsigned half-word wrong
 *   6  – SH does not corrupt adjacent bytes wrong
 *   7  – SB/LB signed byte wrong
 *   8  – SB/LBU unsigned byte wrong
 *   9  – SB does not corrupt adjacent bytes wrong
 *  10  – LH sign-extends negative half-word wrong
 *  11  – LB sign-extends negative byte wrong
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* Load address of data buffer */
    la      s0, data_buf

    /* ---- SW / LW ---- */

    /* Test 2: store and reload a 32-bit word */
    li      t0, 0xdeadbeef
    sw      t0, 0(s0)
    lw      t1, 0(s0)
    CHECK_EQ(t1, 0xdeadbeef, 2)

    /* Test 3: store two words and reload each */
    li      t0, 0x12345678
    li      t1, 0x9abcdef0
    sw      t0, 0(s0)
    sw      t1, 4(s0)
    lw      t2, 0(s0)
    CHECK_EQ(t2, 0x12345678, 3)
    lw      t2, 4(s0)
    CHECK_EQ(t2, 0x9abcdef0, 3)

    /* ---- SH / LH / LHU ---- */

    /* Test 4: store and reload signed half-word (positive) */
    li      t0, 0x00001234
    sw      zero, 0(s0)         /* clear buffer */
    sh      t0, 0(s0)
    lh      t1, 0(s0)
    CHECK_EQ(t1, 0x1234, 4)

    /* Test 5: LHU on same value – no sign extension */
    lhu     t1, 0(s0)
    CHECK_EQ(t1, 0x1234, 5)

    /* Test 6: SH must not corrupt adjacent bytes */
    li      t0, 0xdeadbeef
    sw      t0, 0(s0)           /* fill word with known pattern */
    li      t1, 0x1234
    sh      t1, 0(s0)           /* overwrite low half-word only */
    lw      t2, 0(s0)
    CHECK_EQ(t2, 0xdead1234, 6)

    /* ---- SB / LB / LBU ---- */

    /* Test 7: store and reload signed byte (positive) */
    sw      zero, 0(s0)
    li      t0, 0x42
    sb      t0, 0(s0)
    lb      t1, 0(s0)
    CHECK_EQ(t1, 0x42, 7)

    /* Test 8: LBU on same value */
    lbu     t1, 0(s0)
    CHECK_EQ(t1, 0x42, 8)

    /* Test 9: SB must not corrupt adjacent bytes */
    li      t0, 0xdeadbeef
    sw      t0, 0(s0)
    li      t1, 0x12
    sb      t1, 0(s0)           /* overwrite lowest byte only */
    lw      t2, 0(s0)
    CHECK_EQ(t2, 0xdeadbe12, 9)

    /* Test 10: LH sign-extends negative half-word (bit 15 set) */
    li      t0, 0x8000
    sw      zero, 0(s0)
    sh      t0, 0(s0)
    lh      t1, 0(s0)
    CHECK_EQ(t1, 0xffff8000, 10)

    /* Test 11: LB sign-extends negative byte (bit 7 set) */
    li      t0, 0x80
    sw      zero, 0(s0)
    sb      t0, 0(s0)
    lb      t1, 0(s0)
    CHECK_EQ(t1, 0xffffff80, 11)

    TEST_PASS

/* ---- Data buffer ---- */
.section .data
.align 4
data_buf:
    .word 0, 0, 0, 0    /* 16 bytes of scratch space */
