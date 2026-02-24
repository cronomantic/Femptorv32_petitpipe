/* SPDX-License-Identifier: BSD-3-Clause
 * Test LUI (Load Upper Immediate) and AUIPC (Add Upper Immediate to PC).
 *
 * Error codes:
 *   2  – LUI basic wrong
 *   3  – LUI low 12 bits must be zero wrong
 *   4  – LUI with x0 (x0 stays 0) wrong
 *   5  – AUIPC result wrong (PC + upper immediate)
 *   6  – AUIPC with zero upper immediate equals current PC wrong
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* ---- LUI ---- */

    /* Test 2: LUI loads bits [31:12]; low 12 bits are 0 */
    lui     t0, 0xabcde
    CHECK_EQ(t0, 0xabcde000, 2)

    /* Test 3: LUI with 1 – only bit 12 set */
    lui     t0, 1
    CHECK_EQ(t0, 0x00001000, 3)

    /* Test 4: LUI into x0 – x0 must stay 0 */
    lui     zero, 0xfffff
    CHECK_EQ(zero, 0, 4)

    /* ---- AUIPC ---- */

    /* Test 5: AUIPC adds upper immediate to the current PC.
               We compute the expected value by using 'la' and arithmetic. */
auipc_test5:
    auipc   t0, 0x10000         /* t0 = PC + (0x10000 << 12) */
    la      t1, auipc_test5     /* t1 = address of the AUIPC instruction */
    li      t2, 0x10000000      /* 0x10000 << 12 */
    add     t1, t1, t2          /* expected = PC_of_auipc + upper_imm */
    CHECK_EQ_REG(t0, t1, 5)

    /* Test 6: AUIPC with 0 upper immediate gives the instruction's own PC */
auipc_test6:
    auipc   t0, 0               /* t0 = PC of this instruction + 0 */
    la      t1, auipc_test6
    CHECK_EQ_REG(t0, t1, 6)

    TEST_PASS
