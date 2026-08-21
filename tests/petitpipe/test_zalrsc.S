/* SPDX-License-Identifier: BSD-3-Clause
 * Test Zalrsc: lr.w y sc.w.
 *
 * Comprueba las reglas que hacen util a un par lr/sc, no solo que ejecuten:
 * que sc SIN reserva falle, que falle contra otra direccion, y que un segundo
 * sc despues de uno bueno falle tambien. Sin la ultima, dos secciones criticas
 * seguidas entrarian las dos.
 *
 * LIMITE CONOCIDO: el banco de pruebas es de UN nucleo, asi que aqui no se
 * puede comprobar la invalidacion cruzada -que un sc falle porque OTRO hart
 * escribio la direccion reservada-. Eso vive en res_kill, lo genera el SoC, y
 * necesita un banco de dos nucleos.
 *
 * Error codes:
 *   2  – lr.w no devuelve el valor de memoria
 *   3  – sc.w tras lr.w no devuelve 0 (deberia triunfar)
 *   4  – sc.w tras lr.w no escribio el dato
 *   5  – un segundo sc.w no falla: la reserva no se solto
 *   6  – ese segundo sc.w SI escribio: no basta con devolver 1
 *   7  – sc.w sin lr.w previo no falla
 *   8  – sc.w contra otra direccion no falla
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

/* El Makefile compila a -march=rv32i: lr/sc necesitan la extension aqui. */
.option arch, +zalrsc

_start:
    li      s0, 0x2000              /* zona de trabajo */
    li      t1, 0xA5A5A5A5
    sw      t1, 0(s0)

    /* Test 2: lr.w lee lo que hay */
    lr.w    t0, (s0)
    CHECK_EQ(t0, 0xA5A5A5A5, 2)

    /* Test 3 y 4: sc.w con la reserva viva triunfa y escribe */
    li      t2, 0x12345678
    sc.w    t3, t2, (s0)
    CHECK_EQ(t3, 0, 3)
    lw      t4, 0(s0)
    CHECK_EQ(t4, 0x12345678, 4)

    /* Test 5 y 6: el sc bueno SOLTO la reserva, asi que otro falla y no toca
       la memoria */
    li      t2, 0xDEADBEEF
    sc.w    t3, t2, (s0)
    CHECK_EQ(t3, 1, 5)
    lw      t4, 0(s0)
    CHECK_EQ(t4, 0x12345678, 6)

    /* Test 7: sc.w sin ninguna reserva previa falla */
    li      t2, 0xCAFEBABE
    sc.w    t3, t2, (s0)
    CHECK_EQ(t3, 1, 7)

    /* Test 8: reservar una direccion y hacer sc contra OTRA falla */
    addi    s1, s0, 16
    lr.w    t0, (s0)
    li      t2, 0x55555555
    sc.w    t3, t2, (s1)
    CHECK_EQ(t3, 1, 8)

    TEST_PASS
