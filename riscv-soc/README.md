# riscv-soc — AXI4-Lite SoC (RTL / µarch track)

Interview-grade SoC built around the shared RV32IM core (`../rtl/cpu_riscv`).
Constraints: synthesizable SystemVerilog-2017, **one module per file**, every block gets a
timing/CDC note in [`../DESIGN_DECISIONS.md`](../DESIGN_DECISIONS.md).

## Deliverables & status
- [ ] AXI4-Lite interconnect: wrap the core; boot ROM, SRAM controller, UART, timer as AXI peripherals
- [x] Parameterized **async FIFO** (Gray-code pointers, 2-flop synchronizers) — CDC showcase, formal-friendly
- [ ] Round-robin arbiter + 2-channel DMA engine on the bus
- [ ] Stretch: 2-way set-associative I$/D$ and a gshare predictor
- [x] Verilator `--lint-only` clean (per-block) — `make lint`
- [ ] Synthesis: Yosys + sky130 (CI) **and** a Design Compiler script (run at CMU); clock gating + dynamic-power Δ

## Results (measured)
| Block | Metric | Value | Provenance |
|-------|--------|-------|-----------|
| async FIFO | dual-clock self-checking sim | **PASS** — 256 words, 2 async clocks, 0 errors | `CI` — iverilog 12.0 |
| async FIFO | Verilator lint | **0 warnings** | `CI` — verilator 5.020 |
| async FIFO | Gray-pointer invariants (P1 encoding, P2 1-bit transition) | **formally PROVEN** — BMC base + unbounded induction | `CI` — yosys-smtbmc + z3 (`make formal`) |
| SoC | fmax / cell count / area (sky130) | — | ⬜ CI (after integration) |
| SoC | dynamic power Δ (clock gating, DC) | — | ⏳ pending-CMU |

Run it: `make -C .. soc` or, in this dir, `make all` (lint + sim + formal).

First architectural decisions (logged in DESIGN_DECISIONS): fabric topology
(shared-bus+decoder vs crossbar); gshare vs existing BTB+BHT.
