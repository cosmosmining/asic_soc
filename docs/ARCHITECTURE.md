# Architecture

A single-clock, active-low-reset RV32IM microcontroller SoC. Synthesizable
SystemVerilog (IEEE 1800-2017), no vendor IP, no black boxes.

## Block diagram

```
                         soc_top
   ┌───────────────────────────────────────────────────────────────┐
   │                                                                 │
   │   riscv_pipeline (RV32IM, 5-stage)                              │
   │   IF ─ ID ─ EX ─ MEM ─ WB                                       │
   │   • forwarding + load-use stall    • BTB + 2-bit BHT predictor  │
   │   • multi-cycle mul / div          • Zicsr + M-mode traps       │
   │   • machine interrupts (timer/sw/ext)                           │
   │        │ imem (fetch)        │ dmem (load/store)                │
   │        ▼                     ▼                                  │
   │   ┌─────────┐        ┌───────────────── address decode ──────┐ │
   │   │ soc_ram │◀───────┤  0x0000  RAM                          │ │
   │   │ 1W/2R   │        │  0x0200  CLINT  ── timer_irq/sw_irq ──┐│ │
   │   └─────────┘        │  0x1000  UART   ── uart_tx ───────────┼┼─▶ pin
   │                      │  0x1001  GPIO   ── gpio_out/in ───────┼┼─▶ pins
   │                      └──────────────────────────────────────┘│ │
   │            machine timer/sw interrupt ───────────────────────┘ │
   └───────────────────────────────────────────────────────────────┘
```

The CPU presents two simple single-cycle memory ports (combinational read,
registered write). Instruction fetches always hit RAM; data accesses are
combinationally decoded to RAM or a peripheral, with a combinational read mux
back to `dmem_rdata`. There are no bus wait states — every access completes in
its issue cycle — which is why the peripherals expose combinational reads.

## Memory map

`rtl/common/soc_map.svh` is the single source of truth.

| Region | Base          | Registers                                                        |
|--------|---------------|------------------------------------------------------------------|
| RAM    | `0x0000_0000` | 16 KiB code+data (default); on silicon a compiled SRAM macro     |
| CLINT  | `0x0200_0000` | `msip` +0x0000 · `mtimecmp` +0x4000/+0x4004 · `mtime` +0xBFF8/+0xBFFC |
| UART   | `0x1000_0000` | `TXDATA` +0x00 (W: byte / R: last) · `STATUS` +0x04 (bit0 tx_busy)|
| GPIO   | `0x1001_0000` | `OUT` +0x00 (R/W) · `IN` +0x04 (R, 2-flop synchronised)          |

Decode is by `addr[31:16]` (64 KiB pages), so the four regions are mutually
exclusive by construction.

## Interrupt model

The CLINT compares a free-running 64-bit `mtime` against `mtimecmp`; the
machine-timer interrupt is the level `mtime >= mtimecmp` (software interrupt is
`msip[0]`). In the CPU:

- `csr.sv` exposes `mip` from the live interrupt lines and raises `irq_req` when
  `mstatus.MIE` is set and an enabled (`mie`) interrupt is pending; `irq_cause`
  selects external > software > timer.
- `riscv_pipeline.sv` takes the interrupt (`int_take`) on a valid instruction in
  EX, unless it is already taking a synchronous trap (those win) or a multi-cycle
  mul/div is in flight (let it finish). The interrupted instruction is fully
  squashed — no GPR/memory/CSR commit, not retired — and re-executes after `MRET`
  because `mepc` is latched to its PC. `mepc[1:0]` is forced to 0 (IALIGN=32).

Firmware acknowledges the timer by advancing `mtimecmp` (the level drops before
`MRET` re-enables interrupts). See `fw/hello_irq.s`.

## Verification

- **Differential golden-trace** (`tb/directed`): an independent single-cycle ISS
  is the reference; the same testbench checks both the single-cycle core and the
  pipeline, over directed programs plus constrained-random streams.
- **SoC cocotb** (`sim/cocotb`): drives `soc_top` with real firmware; checks UART
  output two independent ways (accept-strobe + serial-line decode) and proves the
  interrupt path via the handler-published count and GPIO completion sentinel.
- **Formal** (`flow/formal`): exhaustive ALU equivalence and pipeline safety BMC.
