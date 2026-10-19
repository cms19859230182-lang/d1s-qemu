/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (c) 2026 cms19859230182-lang
 *
 * Trampoline for the d1s machine.
 *
 * The D1s boot ROM loads a small chunk into DRAM and jumps to it with the
 * caches and, importantly, most peripheral clocks still gated and the UART
 * pins still muxed to their reset function.  OpenSBI assumes both are done,
 * so this trampoline does the minimum the boot ROM would have done and then
 * enters OpenSBI in the dynamic-firmware (fw_dynamic) manner:
 *
 *   1. ungate the UART3 bus clock in the CCU and mux PB6/PB7 to UART3
 *   2. configure UART3 for 115200-ish output (divisor 3 at 24 MHz) and
 *      print a banner so a silent boot can be told apart from a broken one
 *   3. build a struct fw_dynamic_info in RAM and enter OpenSBI at
 *      0x40000000 with a0 = hartid, a1 = &info, a2 = magic
 *
 * Load address: 0x40100000 (what the d1s machine uses as its reset vector).
 * OpenSBI is expected at 0x40000000, the device tree at 0x40200000 and the
 * payload at 0x40400000.
 *
 * Register use is intentionally modest: this runs before anything has been
 * initialised, so it only relies on the reset state of the hart.
 */

/* ------------------------------------------------------------------ CCU */
.equ CCU_BASE,            0x02001900
.equ CCU_BUS_CLK_GATE3,   0x0200190c   /* UART3 bus gate, bit 19 */

/* ------------------------------------------------------- PIO pin muxing */
.equ PIO_BASE,            0x02000000
.equ PIO_PB_CFG0,         0x02000124   /* PB0..PB7 select, 4 bits each */
.equ PIO_PB_MUX_UART3,    0x55         /* PB6 = 5, PB7 = 5 */

/* ----------------------------------------------------------------- UART3 */
.equ UART3_BASE,          0x02500c00
.equ UART_THR,            0x00
.equ UART_DLL,            0x00
.equ UART_DLH,            0x04
.equ UART_FCR,            0x08
.equ UART_LCR,            0x0c
.equ UART_LSR,            0x14
.equ UART_LSR_THRE,       0x20
.equ UART_LCR_8N1_DLAB,   0x83         /* 8N1, divisor latch enabled */
.equ UART_FCR_ENABLE,     0x07         /* FIFO enable, clear both FIFOs */
.equ UART_DIVISOR,        3            /* 24 MHz / 16 / 3 ~= 500 kbaud */

/* ------------------------------------------------------------ boot info */
.equ OPENSBI_BASE,        0x40000000
.equ FDT_BASE,            0x40200000
.equ PAYLOAD_BASE,        0x40400000
.equ FW_DYNAMIC_INFO,     0x402ff000   /* below the DTB, above the payload */
.equ FW_DYNAMIC_MAGIC,    0x4942534f   /* "OSBI" */
.equ FW_DYNAMIC_VERSION,  2
.equ FW_DYNAMIC_MODE_S,   1

    .section .text.start, "ax", @progbits
    .globl _start
_start:
    /* The boot ROM may hand over with a0 = hartid; keep it in s0. */
    mv      s0, a0

    /* ------------------------------------------------ 1. clocks and pins */
    li      t0, CCU_BASE
    li      t1, (1 << 19)              /* UART3 bus gate */
    lw      t2, CCU_BUS_CLK_GATE3(t0)
    or      t2, t2, t1
    sw      t2, CCU_BUS_CLK_GATE3(t0)

    li      t0, PIO_BASE
    li      t1, PIO_PB_MUX_UART3
    sw      t1, PIO_PB_CFG0(t0)

    /* ------------------------------------------------ 2. bring up UART3 */
    li      s1, UART3_BASE

    li      t0, UART_LCR_8N1_DLAB
    sw      t0, UART_LCR(s1)
    li      t0, UART_DIVISOR
    sw      t0, UART_DLL(s1)
    sw      zero, UART_DLH(s1)
    li      t0, UART_FCR_ENABLE
    sw      t0, UART_FCR(s1)
    li      t0, 0x03                   /* 8N1, divisor latch off */
    sw      t0, UART_LCR(s1)

    /* Print the banner one byte at a time, waiting for THRE. */
    la      a2, banner
1:
    lbu     a3, 0(a2)
    beqz    a3, 2f
3:
    lw      a4, UART_LSR(s1)
    andi    a4, a4, UART_LSR_THRE
    beqz    a4, 3b
    sb      a3, UART_THR(s1)
    addi    a2, a2, 1
    j       1b
2:

    /* ------------------------------------- 3. hand over to OpenSBI */
    li      t0, FW_DYNAMIC_MAGIC
    li      t1, FW_DYNAMIC_INFO
    sw      t0, 0(t1)                  /* magic */
    li      t0, FW_DYNAMIC_VERSION
    sw      t0, 4(t1)                  /* version */
    li      t0, PAYLOAD_BASE
    sw      t0, 8(t1)                  /* low part of next_addr */
    sw      zero, 12(t1)
    li      t0, FW_DYNAMIC_MODE_S
    sw      t0, 16(t1)                 /* next_mode: S-mode */
    sw      zero, 20(t1)               /* options */
    li      t0, -1
    sw      t0, 24(t1)                 /* boot_hart: not specified */
    sw      t0, 28(t1)

    /* Make sure the banner and the info struct are visible to OpenSBI. */
    fence   iorw, iorw

    mv      a0, s0
    mv      a1, t1
    li      a2, FW_DYNAMIC_MAGIC
    li      t0, OPENSBI_BASE
    jr      t0

    .section .rodata, "a", @progbits
banner:
    .asciz "\r\n[d1s-qemu] tramp -> OpenSBI fw_dynamic\r\n"
