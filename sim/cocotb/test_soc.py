"""cocotb tests for the integrated SoC (soc_top via tb_soc).

These drive the real RTL with the assembled `hello_irq` firmware and verify the
whole system end to end:

  * UART output is observed two independent ways -- captured on the accept
    strobe AND decoded bit-by-bit off the serial line -- and both must read the
    firmware banner "HELLO SOC\\n".
  * The CLINT machine-timer interrupt path works: the handler increments a
    counter and publishes it on the GPIO outputs, and main only writes its
    completion sentinel after the count reaches NIRQ. Seeing the count ramp
    1..NIRQ and then the sentinel proves interrupts were taken, vectored,
    counted and returned from (MRET).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

CLK_NS = 10
UART_DIV = 8                       # must match tb_soc UART_DIV
EXPECTED_BANNER = "HELLO SOC\n"
NIRQ = 5
SENTINEL = 0x00C0FFEE


def _int(sig):
    """Resolve a signal to int, or None if it carries X/Z."""
    try:
        return int(sig.value)
    except ValueError:
        return None


async def reset(dut, cycles=4):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def uart_strobe_monitor(dut, sink):
    """Capture each byte the UART accepts (the tx_strobe pulse)."""
    while True:
        await RisingEdge(dut.clk)
        if dut.uart_tx_strobe.value == 1:
            sink.append(int(dut.uart_tx_byte.value) & 0xFF)


async def uart_serial_monitor(dut, clks_per_bit, sink):
    """Independently decode the 8N1 serial line (mid-bit sampling)."""
    half = clks_per_bit // 2
    while True:
        await FallingEdge(dut.uart_tx)            # idle high -> start bit
        for _ in range(half):                     # step to the middle of the start bit
            await RisingEdge(dut.clk)
        if _int(dut.uart_tx) != 0:
            continue                              # not a real start bit
        byte = 0
        for b in range(8):
            for _ in range(clks_per_bit):         # advance to the middle of data bit b
                await RisingEdge(dut.clk)
            byte |= (_int(dut.uart_tx) & 1) << b   # LSB first
        sink.append(byte & 0xFF)


@cocotb.test()
async def test_hello_irq(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)

    strobe_bytes, serial_bytes = [], []
    cocotb.start_soon(uart_strobe_monitor(dut, strobe_bytes))
    cocotb.start_soon(uart_serial_monitor(dut, UART_DIV, serial_bytes))

    # poll the GPIO outputs: the handler publishes the running interrupt count
    # there (1..NIRQ); main then writes the completion sentinel.
    max_count = 0
    reached = False
    for _ in range(60000):
        await RisingEdge(dut.clk)
        g = _int(dut.gpio_out)
        if g is None:
            continue
        if g == SENTINEL:
            reached = True
            break
        if g <= NIRQ:
            max_count = max(max_count, g)

    banner_strobe = bytes(strobe_bytes).decode("ascii", "replace")
    banner_serial = bytes(serial_bytes).decode("ascii", "replace")
    dut._log.info(f"UART (strobe) : {banner_strobe!r}")
    dut._log.info(f"UART (serial) : {banner_serial!r}")
    dut._log.info(f"interrupt count reached: {max_count}")
    dut._log.info(f"final gpio_out = 0x{(_int(dut.gpio_out) or 0):08X}")

    assert reached, (
        "firmware never wrote the completion sentinel -- the timer interrupt "
        "path did not deliver NIRQ interrupts"
    )
    assert max_count == NIRQ, \
        f"interrupt count ramped only to {max_count}, expected NIRQ={NIRQ}"
    assert banner_strobe == EXPECTED_BANNER, \
        f"UART (strobe) {banner_strobe!r} != {EXPECTED_BANNER!r}"
    assert banner_serial == EXPECTED_BANNER, \
        f"UART (serial decode) {banner_serial!r} != {EXPECTED_BANNER!r}"


@cocotb.test()
async def test_reset_pc(dut):
    """After reset the core fetches from RESET_PC (0) and starts retiring."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)
    retired = False
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.rvfi_valid.value == 1:
            retired = True
            break
    assert retired, "core did not retire any instruction out of reset"
