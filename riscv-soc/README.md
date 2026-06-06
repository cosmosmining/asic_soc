# riscv-soc — AXI4-Lite SoC (RTL / µarch track)

Interview-grade SoC built around the shared RV32IM core (`../rtl/cpu_riscv`).
Constraints: synthesizable SystemVerilog-2017, **one module per file**, every block gets a
timing/CDC note in [`../DESIGN_DECISIONS.md`](../DESIGN_DECISIONS.md).

## Deliverables & status
- [x] AXI4-Lite interconnect + boot ROM + SRAM + UART + timer as AXI peripherals (CPU-on-bus wrap: next increment)
- [x] Parameterized **async FIFO** (Gray-code pointers, 2-flop synchronizers) — CDC showcase, formal-friendly
- [x] Round-robin arbiter + 2-channel DMA engine on the bus
- [ ] Stretch: 2-way set-associative I$/D$ and a gshare predictor
- [x] Verilator `--lint-only` clean (all blocks) — `make lint`
- [ ] Synthesis: Yosys + sky130 (CI) **and** a Design Compiler script (run at CMU); clock gating + dynamic-power Δ

## Results (measured)
| Block | Metric | Value | Provenance |
|-------|--------|-------|-----------|
| async FIFO | dual-clock self-checking sim | **PASS** — 256 words, 2 async clocks, 0 errors | `CI` — iverilog 12.0 |
| async FIFO | Gray-pointer invariants (P1 encoding, P2 1-bit transition) | **formally PROVEN** — BMC base + unbounded induction | `CI` — yosys-smtbmc + z3 (`make formal`) |
| AXI4-Lite slave | handshake + byte-strobe directed test | **PASS** | `CI` — iverilog |
| AXI4-Lite SoC | xbar + ROM/SRAM/UART/timer integration | **PASS** — ROM read, SRAM r/w, ROM-write SLVERR, UART byte decoded off serial, timer count+IRQ | `CI` — iverilog |
| DMA + arbiter | 2-channel DMA over the bus, round-robin arbiter | **PASS** — 1-ch copy + 2-ch concurrent copy verified | `CI` — iverilog |
| all blocks | Verilator lint | **0 warnings** | `CI` — verilator 5.020 |
| all blocks | Yosys synthesis | **latch-free, 0 inferred latches** | `CI` — yosys 0.33 (`make synth`) |
| SoC | sky130 fmax / area | — | ⬜ PD track (OpenLane) |
| SoC | dynamic power Δ (clock gating, DC) | — | ⏳ pending-CMU |

### Generic synthesis (Yosys, technology-independent cell count)
Fast reproducible synthesizability gate; sky130 area/fmax come from the PD track.
| block | generic cells | latch-free |
|-------|--------------:|:----------:|
| async_fifo | 1136 | ✅ |
| axil_arbiter | 152 | ✅ |
| axil_xbar | 175 | ✅ |
| dma_engine | 2376 | ✅ |
| axil_uart | 112 | ✅ |
| axil_timer | 597 | ✅ |

Run it: `make -C .. soc` or, in this dir, `make all` (lint + sim + formal).

First architectural decisions (logged in DESIGN_DECISIONS): fabric topology
(shared-bus+decoder vs crossbar); gshare vs existing BTB+BHT.
