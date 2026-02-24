/* SPDX-License-Identifier: BSD-3-Clause
 * Linker script for FemptorV32_petitpipe bare-metal test programs.
 *
 * The processor boots from address 0x00000000, so .text starts there.
 * The full 512 KB RAM window matches the mem_model.v address map.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 512K
}

SECTIONS {
    . = 0x00000000;

    /* Executable code – .text.init must come first so _start lands at 0x0 */
    .text : {
        *(.text.init)
        *(.text*)
        *(.rodata*)
    } > RAM

    /* Initialised data */
    .data : {
        *(.data*)
        *(.sdata*)
    } > RAM

    /* Zeroed BSS */
    .bss : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* Stack grows down from the top of RAM */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /* Discard debug/attribute sections to keep the image small */
    /DISCARD/ : {
        *(.riscv.attributes)
        *(.comment)
        *(.eh_frame)
    }
}
