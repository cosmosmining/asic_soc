# hello_irq.s - SoC bring-up firmware (assembled by tools/scripts/rvasm.py).
#
# 1. prints "HELLO SOC\n" over the UART (polling the busy flag),
# 2. arms the CLINT machine timer and enables machine-timer interrupts,
# 3. services NIRQ timer interrupts in the trap handler, counting them and
#    toggling GPIO[0] on each,
# 4. then drives gpio_out = 0x00C0FFEE as a completion sentinel and halts.
#
# Exercises the full system: instruction fetch + data load/store to RAM, UART
# MMIO, GPIO MMIO, the CLINT, and -- the point -- the asynchronous interrupt
# path through mtvec/mepc/mcause/mstatus and MRET.

    .equ NIRQ,        5         # number of timer interrupts to service
    .equ DELTA,       300       # mtime ticks between interrupts
    .equ UART,        0x10000000 # UART base (TXDATA @ +0, STATUS @ +4)
    .equ GPIO,        0x10010000 # GPIO base (OUT @ +0)
    .equ MTIME,       0x0200BFF8 # CLINT mtime    (low word)
    .equ MTIMECMP,    0x02004000 # CLINT mtimecmp (low word)
    .equ MTIMECMPH,   0x02004004 # CLINT mtimecmp (high word)
    .equ SENTINEL,    0x00C0FFEE # gpio_out value written on completion

# ---------------------------------------------------------------- reset
_start:
    li   sp, 0x4000             # stack top (16 KiB RAM, full-descending)
    la   t0, trap_vec
    csrw mtvec, t0             # install trap vector (direct mode)
    li   s0, 0                 # s0 = interrupts serviced (shared with handler)

    la   a0, msg               # print the banner
    call puts

    # arm the timer: mtimecmp = mtime + DELTA  (64-bit; high word = 0)
    li   t2, MTIME
    lw   t1, 0(t2)             # t1 = mtime low
    addi t1, t1, DELTA
    li   t2, MTIMECMP
    sw   t1, 0(t2)             # mtimecmp low
    li   t2, MTIMECMPH
    sw   zero, 0(t2)           # mtimecmp high = 0

    li   t0, 0x80             # mie.MTIE (bit 7)
    csrs mie, t0
    li   t0, 0x8              # mstatus.MIE (bit 3) -> interrupts now enabled
    csrs mstatus, t0

wait:                          # spin until the handler has serviced NIRQ
    li   t0, NIRQ
    blt  s0, t0, wait

    li   t0, GPIO              # completion sentinel on the GPIO outputs
    li   t1, SENTINEL
    sw   t1, 0(t0)
halt:
    j    halt

# ---------------------------------------------------------------- puts(a0)
# Print the NUL-terminated string at a0 over the UART, polling STATUS.busy.
puts:
    li   t2, UART
puts_next:
    lbu  t3, 0(a0)
    beqz t3, puts_done
puts_busy:
    lw   t4, 4(t2)            # UART STATUS
    andi t4, t4, 1            # bit0 = tx_busy
    bnez t4, puts_busy
    sw   t3, 0(t2)            # UART TXDATA
    addi a0, a0, 1
    j    puts_next
puts_done:
    ret

# ---------------------------------------------------------------- trap handler
    .org 0x200                 # fixed, 4-aligned handler address
trap_vec:
    addi sp, sp, -16           # save the temporaries we clobber
    sw   t0, 0(sp)
    sw   t1, 4(sp)
    sw   t2, 8(sp)
    sw   t3, 12(sp)

    csrr t0, mcause
    li   t1, 0x80000007        # machine timer interrupt
    bne  t0, t1, trap_ret      # ignore anything else

    li   t2, MTIME             # acknowledge: advance mtimecmp past mtime
    lw   t1, 0(t2)
    addi t1, t1, DELTA
    li   t2, MTIMECMP
    sw   t1, 0(t2)

    addi s0, s0, 1             # count this interrupt (visible to main)
    li   t0, GPIO              # publish the running count on the GPIO outputs
    sw   s0, 0(t0)

trap_ret:
    lw   t0, 0(sp)
    lw   t1, 4(sp)
    lw   t2, 8(sp)
    lw   t3, 12(sp)
    addi sp, sp, 16
    mret

msg:
    .asciz "HELLO SOC\n"
