# RISC-V SoC — interview portfolio (RTL · DV · DFT · PD)

A single verified **RV32IM 5-stage core** carried across the four digital-design
disciplines an Apple / NVIDIA / Qualcomm loop probes: **RTL / microarchitecture,
design verification, design-for-test, and physical design**. Each discipline is
its own directory with its own results. Everything reproducible is pinned and run
in CI; every number below is traceable to *how* it was measured.

> **Honesty policy (non-negotiable).** Each result is tagged by provenance:
> `CI` = reproduced in this repo on open-source tools (re-runnable here),
> `prior` = measured in an earlier run and logged in [`PROGRESS.md`](PROGRESS.md)
> but not yet re-run in CI, `pending-CMU` = needs a commercial tool
> (Design Compiler / PrimeTime / Innovus / VCS+Verdi / DFT Compiler+TestMAX) and
> will be filled from a **real report**, never estimated. Nothing here is fabricated.

Legend: ✅ built & reproduced · 🟡 in progress · ⬜ planned · ⏳ pending commercial-tool run

## Portfolio tracks
| Track | Dir | Goal (interview angle) | Status |
|-------|-----|------------------------|--------|
| RTL / SoC | [`riscv-soc/`](riscv-soc/) | AXI4-Lite SoC around the core — interconnect, boot ROM, SRAM ctrl, UART, timer; async FIFO (CDC showcase), round-robin arbiter + 2-ch DMA; Verilator-lint-clean; clock-gating dynamic-power story | 🟡 Phase 1 |
| Verification | [`riscv-soc-dv/`](riscv-soc-dv/) | Real UVM evidence — agent/scoreboard/RAL, covergroups, SVA, riscv-dv + Spike co-sim, SymbiYosys formal; **closes the UVM résumé gap** | ⬜ Phase 2 |
| DFT | [`riscv-soc-dft/`](riscv-soc-dft/) | Scan + ATPG, March C− MBIST, IEEE-1149.1 JTAG TAP, C++ PPSFP fault simulator; pairs with ACTL research | ⬜ Phase 2 |
| Physical design | [`riscv-soc-pd/`](riscv-soc-pd/) | OpenLane2 / OpenROAD sky130 PPA sweep, PrimeTime/Innovus mirror scripts, pip-installable timing-report CLI, DeepDGR congestion tie-in | ⬜ Phase 2 |

## Headline results (résumé table — only measured numbers)
| Metric | Result | Track | Provenance |
|--------|--------|-------|-----------|
| Functional smoke (directed) | **PASS 10/10** | core | `CI` — iverilog 12.0, this repo |
| Differential regression (golden ISS) | directed + **20 random seeds × 2 cores, 0 mismatches** | core | `CI` — scalable via `make regress`; history cites ~260 programs |
| Branch-predictor CPI (loop_sum100) | 1.66 → **1.02 (−38%)** | core | `prior` — PROGRESS Iter-4 (reproduce target: Phase 1) |
| sky130 synthesis | 20,789 cells / **0.201 mm²** | core | `prior` — PROGRESS Iter-7 (Yosys+sky130; PD track reproduces) |
| Routed GDSII (sky130) | die 2.03 mm², **0 router DRC**, post-CTS timing MET @50 MHz | core | `prior` — Iter-8 OpenLane; post-route timing NOT closed, LVS not run (see [`gds_flow/RESULTS.md`](gds_flow/RESULTS.md)) |
| Verilator lint (core) | 51 warnings, 0 errors — **not yet clean** | core | `CI` — baseline; lint-clean is a Phase-1 task |
| Async FIFO (CDC showcase) | sim 256 words/2 clocks 0 err; **Gray invariants formally proven** | riscv-soc | `CI` — iverilog + yosys-smtbmc/z3 |
| AXI4-Lite SoC fabric | xbar + ROM/SRAM/UART/timer integration **PASS**; lint-clean | riscv-soc | `CI` — iverilog + verilator |
| 2-ch DMA + round-robin arbiter | concurrent dual-channel copy over the bus **PASS** | riscv-soc | `CI` — iverilog |
| Arbiter formal safety | grant mutual-exclusion + stability **PROVEN**; **2 real RTL bugs** found+fixed | riscv-soc-dv | `CI` — yosys-smtbmc/z3 |
| C++ stuck-at fault simulator | c17 **100%** (22/22); redundancy case **62.5%** (flags 3 untestable) | riscv-soc-dft | `CI` — g++ |
| STA timing-violation classifier | 3/3 causes classified; **pip-installable** CLI | riscv-soc-pd | `CI` — python |
| DC dynamic power Δ (clock gating) | — | riscv-soc | ⏳ `pending-CMU` |
| UVM functional coverage ≥95% | — | riscv-soc-dv | ⏳ pending (DV track) |
| ATPG stuck-at coverage ≥98% | — | riscv-soc-dft | ⏳ pending (DFT track) |
| P&R util/clock sweep (WNS/TNS/fmax) | — | riscv-soc-pd | ⏳ pending (PD track) |

## The shared core (DUT)
`rtl/cpu_riscv/` — RV32IM, 5-stage IF/ID/EX/MEM/WB pipeline: full EX forwarding,
load-use stall, branch flush, direct-mapped **BTB + 2-bit BHT** predictor,
multi-cycle sequential divider. Verified by an **independent golden-model
differential test** (`tb/directed/`). This one core is the DUT for all four tracks
(no duplication); see [`PROGRESS.md`](PROGRESS.md) for its build history.

## Repo layout
```
rtl/ tb/ formal/ tools/ gds_flow/   # shared verified core + its native flow (the DUT)
riscv-soc/        # RTL track   — AXI4-Lite SoC, FIFO, arbiter, DMA
riscv-soc-dv/     # DV track    — UVM + cocotb + riscv-dv/Spike + formal
riscv-soc-dft/    # DFT track   — scan/ATPG, MBIST, JTAG, fault sim
riscv-soc-pd/     # PD track    — OpenLane2/OpenROAD sweep, PT/Innovus, CLI
DESIGN_DECISIONS.md  INTERVIEW_PREP.md  PROGRESS.md
.github/workflows/ci.yml  Makefile  tools/versions.env
```

## Reproduce it
```sh
make smoke      # directed smoke + 20-seed differential regression (iverilog)
make regress    # directed + 100-seed regression, both cores
make lint       # Verilator --lint-only on the core (advisory until Phase 1)
make help       # all targets
```
Pinned toolchain in [`tools/versions.env`](tools/versions.env); CI runs `make smoke`
(blocking) and `make lint` (advisory) on every push — see `.github/workflows/ci.yml`.

## Roadmap — explicitly *not yet* built
An earlier README advertised an ARM-like core, a SIMD GPU, and an AXI crossbar.
**Only the RV32IM core was ever built**; those modules are not in this repo. The RTL
track below *does* build a real AXI4-Lite SoC. The honest current scope is exactly the
four tracks above — this section exists so the README never overstates what exists.
