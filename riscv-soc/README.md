# riscv-soc — AXI4-Lite SoC (RTL / µarch track)

Interview-grade SoC built around the shared RV32IM core (`../rtl/cpu_riscv`).
Constraints: synthesizable SystemVerilog-2017, **one module per file**, every block gets a
timing/CDC note in [`../DESIGN_DECISIONS.md`](../DESIGN_DECISIONS.md).

## Deliverables & status
- [ ] AXI4-Lite interconnect: wrap the core; boot ROM, SRAM controller, UART, timer as AXI peripherals
- [ ] Parameterized **async FIFO** (Gray-code pointers, 2-flop synchronizers) — CDC showcase, formal-friendly
- [ ] Round-robin arbiter + 2-channel DMA engine on the bus
- [ ] Stretch: 2-way set-associative I$/D$ and a gshare predictor
- [ ] Verilator `--lint-only` clean; CI smoke sims on every push
- [ ] Synthesis: Yosys + sky130 (CI) **and** a Design Compiler script (run at CMU); clock gating + dynamic-power Δ

## Results (filled from measured runs)
| Metric | Value | Provenance |
|--------|-------|-----------|
| fmax (sky130, Yosys/OpenSTA) | — | ⬜ CI |
| cell count / area | — | ⬜ CI |
| dynamic power Δ (clock gating, DC) | — | ⏳ pending-CMU |

First architectural decisions (logged in DESIGN_DECISIONS): fabric topology
(shared-bus+decoder vs crossbar); gshare vs existing BTB+BHT.
