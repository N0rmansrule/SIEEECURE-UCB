/* Minimal linker script for the simulation SoC.
 * Assumes instruction memory starts at 0x0 and RAM is also at 0x0 (simple model).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;

  .text : {
    *(.text.start)
    *(.text*)
  }

  .rodata : { *(.rodata*) }

  .data : { *(.data*) }

  .bss : {
    *(.bss*)
    *(COMMON)
  }

  /* simple stack at end of 1 MiB memory model */
  . = 0x000FF000;
  _stack_top = .;
}
