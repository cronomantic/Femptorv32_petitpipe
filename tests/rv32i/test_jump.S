/* SPDX-License-Identifier: BSD-3-Clause
 * Test jump instructions: JAL and JALR.
 *
 * Error codes:
 *   2  – JAL did not jump to target
 *   3  – JAL link register (rd) does not hold return address
 *   4  – JALR did not jump to computed target
 *   5  – JALR link register does not hold return address
 *   6  – JALR clears bit 0 of target (alignment)
 *   7  – JAL with rd=x0 (jump-only; x0 stays 0)
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

_start:
    /* ---- JAL ---- */

    /* Test 2 & 3: JAL jumps and stores PC+4 in rd */
    jal     ra, jal_target
    TEST_FAIL(2)            /* should not be reached */

jal_return:
    /* Test 3: ra must hold the address of the instruction after JAL */
    la      t0, jal_return
    CHECK_EQ_REG(ra, t0, 3)

    /* ---- JALR ---- */

    /* Test 4 & 5: JALR jumps to rs1+offset and stores PC+4 in rd */
    la      t0, jalr_target
    jalr    ra, t0, 0
    TEST_FAIL(4)            /* should not be reached */

jalr_return:
    /* Test 5: ra holds the address of the instruction after JALR */
    la      t0, jalr_return
    CHECK_EQ_REG(ra, t0, 5)

    /* Test 6: JALR forces bit 0 of target to 0 (RISC-V spec §2.5).
               We pass a target address with bit 0 set; it should be cleared. */
    la      t0, jalr_align_target
    ori     t0, t0, 1          /* set bit 0 */
    jalr    ra, t0, 0
    TEST_FAIL(6)

jalr_align_return:
    /* If we arrived here, the jump worked (bit 0 was cleared). */

    /* Test 7: JAL with rd=x0 is a pure jump; x0 must remain 0 */
    jal     zero, jal_x0_target
    TEST_FAIL(7)

jal_x0_return:
    CHECK_EQ(zero, 0, 7)

    TEST_PASS

/* --- Jump targets --- */

jal_target:
    j       jal_return

jalr_target:
    j       jalr_return

jalr_align_target:
    j       jalr_align_return

jal_x0_target:
    j       jal_x0_return
