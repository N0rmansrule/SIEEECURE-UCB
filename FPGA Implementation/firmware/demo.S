.option norvc
.section .text.start
.globl _start

_start:
    /* set stack pointer */
    lui  sp, %hi(_stack_top)
    addi sp, sp, %lo(_stack_top)

    /* basic integer ops */
    addi x1, x0, 5
    addi x2, x0, 7
    add  x3, x1, x2    /* x3 = 12 */

    /* store/load to exercise D$ */
    lui  x4, 0
    addi x4, x4, 0x100
    sd   x3, 0(x4)
    ld   x5, 0(x4)

loop:
    /* simple branch */
    beq  x5, x3, loop
    jal  x0, loop
