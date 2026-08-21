/* SPDX-License-Identifier: BSD-3-Clause
 * Test mhartid (CSR 0xF14).
 *
 * El banco de pruebas instancia el nucleo con HARTID por defecto, que es 0.
 * Lo que se comprueba es que el CSR existe, que devuelve ese valor y que es
 * de SOLO LECTURA: escribirlo no debe tener efecto. Sin esta ultima parte, un
 * mhartid escribible pasaria el test y romperia el arranque de un sistema de
 * varios nucleos, donde cada hart tiene que poder fiarse de su propio ID.
 *
 * LIMITE CONOCIDO: con HARTID = 0, este test tambien pasa en un nucleo que NO
 * implemente mhartid, porque un CSR no implementado lee 0. Comprobado: gracilis
 * y pipedream lo pasan sin tener el registro. Lo que si distingue de verdad es
 * la parte de solo lectura. Para verificar el valor haria falta instanciar el
 * nucleo con HARTID != 0, y eso pide tocar el banco de pruebas.
 *
 * Error codes:
 *   2  – mhartid no devuelve HARTID (0 por defecto)
 *   3  – csrw sobre mhartid tuvo efecto: no es de solo lectura
 *   4  – csrs sobre mhartid tuvo efecto
 */

#include "../common/test_macros.h"

.section .text.init
.global _start

/* El Makefile compila a -march=rv32i, sin zicsr. Este test es el unico que
   necesita instrucciones de CSR, asi que la extension se habilita aqui en vez
   de cambiar los flags comunes de todos los demas. */
.option arch, +zicsr

_start:
    /* Test 2: mhartid se lee y vale 0 */
    csrr    t0, mhartid
    CHECK_EQ(t0, 0, 2)

    /* Test 3: escribirlo no cambia nada */
    li      t1, 0x5A5A5A5A
    csrw    mhartid, t1
    csrr    t0, mhartid
    CHECK_EQ(t0, 0, 3)

    /* Test 4: poner bits tampoco */
    li      t1, 0x0000FFFF
    csrs    mhartid, t1
    csrr    t0, mhartid
    CHECK_EQ(t0, 0, 4)

    TEST_PASS
