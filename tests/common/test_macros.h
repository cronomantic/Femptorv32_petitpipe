/* SPDX-License-Identifier: BSD-3-Clause
 * Common macros for RV32I assembly test programs.
 *
 * Tests communicate results to the testbench by writing to EXIT_ADDR:
 *   1       → PASS
 *   other   → FAIL (error code identifies the failing check; use 2+ per test)
 *
 * UART output is available by writing a byte to UART_ADDR.
 *
 * Scratch registers used internally by these macros: t4, t5.
 * The processor test should avoid relying on t4/t5 across macro calls.
 */

#ifndef TEST_MACROS_H
#define TEST_MACROS_H

/* Memory-mapped I/O addresses (must match tb/mem_model.v) */
#define EXIT_ADDR  0x10000000
#define UART_ADDR  0x10000004

/* -------------------------------------------------------------------------
 * TEST_PASS – signal that all checks passed; loops forever.
 * ------------------------------------------------------------------------- */
#define TEST_PASS               \
    li   t4, EXIT_ADDR;         \
    li   t5, 1;                 \
    sw   t5, 0(t4);             \
    j    .;

/* -------------------------------------------------------------------------
 * TEST_FAIL(code) – signal failure with a non-zero error code; loops forever.
 *   code : immediate integer (2-255 recommended; 0 and 1 are reserved)
 * ------------------------------------------------------------------------- */
#define TEST_FAIL(code)         \
    li   t4, EXIT_ADDR;         \
    li   t5, (code);            \
    sw   t5, 0(t4);             \
    j    .;

/* -------------------------------------------------------------------------
 * CHECK_EQ(reg, val, err) – assert reg == val, else TEST_FAIL(err).
 *   reg  : any register
 *   val  : immediate or register-compatible value (passed through li)
 *   err  : failure error code (>= 2)
 * Clobbers t4 and t5.
 * ------------------------------------------------------------------------- */
#define CHECK_EQ(reg, val, err)     \
    li   t4, (val);                 \
    beq  reg, t4, 9998f;            \
    TEST_FAIL(err)                  \
9998:

/* -------------------------------------------------------------------------
 * CHECK_NE(reg, val, err) – assert reg != val, else TEST_FAIL(err).
 * Clobbers t4 and t5.
 * ------------------------------------------------------------------------- */
#define CHECK_NE(reg, val, err)     \
    li   t4, (val);                 \
    bne  reg, t4, 9998f;            \
    TEST_FAIL(err)                  \
9998:

/* -------------------------------------------------------------------------
 * CHECK_EQ_REG(reg1, reg2, err) – assert reg1 == reg2, else TEST_FAIL(err).
 * Uses only t4 and t5 (via TEST_FAIL).
 * ------------------------------------------------------------------------- */
#define CHECK_EQ_REG(reg1, reg2, err)   \
    beq  reg1, reg2, 9998f;             \
    TEST_FAIL(err)                      \
9998:

#endif /* TEST_MACROS_H */
