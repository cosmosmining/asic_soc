# asic_soc — agent flow brain

A from-scratch, **open-source** RV32IM SoC taken RTL → GDSII, built to be driven
by Claude Code. This file is the operating manual: how to run each stage, what
"pass" means, and the rules that keep the design honest. Reports are the only
eyes the agent has into the design, so every stage is batch-mode and emits a
pass/fail exit code plus a machine-readable summary.

## What it is

- **CPU**: 5-stage in-order RV32IM pipeline (`rtl/cpu_riscv/riscv_pipeline.sv`) —
  forwarding, load-use stall, BTB+BHT branch prediction, multi-cycle mul/div,
  machine-mode CSRs/traps, **and machine interrupts** (timer/software/external).
  A single-cycle core (`riscv_core.sv`) is the independent golden reference.
- **SoC** (`rtl/soc/soc_top.sv`): CPU + single-cycle RAM + CLINT machine timer +
  UART + GPIO, integrated over a combinational address-decoded bus.
- **Firmware**: assembled by `tools/scripts/rvasm.py` (no external GCC needed).

## Memory map (`rtl/common/soc_map.svh` is the source of truth)

| Region | Base          | Notes                                            |
|--------|---------------|--------------------------------------------------|
| RAM    | `0x0000_0000` | code + data, single-cycle (page `0x0000`)        |
| CLINT  | `0x0200_0000` | `msip` +0x0, `mtimecmp` +0x4000, `mtime` +0xBFF8 |
| UART   | `0x1000_0000` | `TXDATA` +0x0, `STATUS` +0x4 (bit0 = tx_busy)    |
| GPIO   | `0x1001_0000` | `OUT` +0x0, `IN` +0x4                             |

## Interrupt model

The CLINT `mtime>=mtimecmp` level drives the machine-timer interrupt. The CPU
takes it on a valid instruction in EX (`int_take`) when `mstatus.MIE & mie.MTIE`,
unless that instruction already takes a synchronous trap or a multi-cycle op is
in flight. The interrupted instruction is fully squashed and re-executes after
`MRET` (mepc points at it). `mepc[1:0]` is forced to 0 (IALIGN=32).

## Flow stages (one `make` target each, real exit codes)

| Stage              | Command            | Pass criterion                          | Runs locally? |
|--------------------|--------------------|-----------------------------------------|---------------|
| Lint               | `make lint`        | 0 Verilator warnings                    | yes           |
| Register gen       | `make regs`        | PeakRDL emits RTL/header/UVM/HTML        | yes           |
| Directed sim       | `make sim`         | golden-trace match                      | yes           |
| Regression         | `make regress`     | directed + N random, both cores         | yes           |
| SoC sim (cocotb)   | `make sim-soc`     | UART banner + NIRQ interrupts serviced  | yes           |
| Formal             | `make formal`      | ALU equiv + pipeline safety BMC pass    | yes           |
| Synthesis          | `make synth-soc`   | elaborates, `check -assert` clean       | yes           |
| sky130 map         | `make synth-sky130`| maps to std cells                       | needs PDK     |
| STA                | `make sta`         | WNS ≥ 0                                 | host stage    |
| PnR → GDSII        | `make pnr`         | routed, 0 router DRC                     | host stage    |
| DRC / LVS          | `make drc` `make lvs` | 0 DRC, 0 LVS                         | host stage    |
| Metrics            | `make metrics`     | writes `reports/summary.json`           | yes           |

`make all` = lint + regress + sim-soc + formal (the CI gate). Host stages need
the sky130 PDK and the heavy tools; they degrade with guidance (see docs/FLOW.md
and gds_flow/ for the proven OpenLane GDSII).

## Reading results

`make metrics` distils everything into `reports/summary.json` — synth cells/flops,
formal task status, cocotb pass count, and physical signoff (DRC/LVS/slack from
`gds_flow/signoff/`). Drill into the full logs only when the summary flags a fail.

## House rules (do not break these)

- **Lint stays clean.** New intentional waivers go in `tools/verilator/lint_waivers.vlt`
  *with a justification comment*, never blanket `lint_off`.
- **Never weaken a check to make a number green.** Do not relax the SDC, mask an
  assertion, or widen a tolerance to "close" timing/verification — fix the design
  or flag the tradeoff.
- **The single-cycle core is the golden model.** Any architectural change must
  keep the differential regression green on *both* cores.
- **Don't edit generated or vendor trees**: `rtl/generated/` (regenerate with
  `make regs`), `gds_flow/` artifacts, anything under a PDK.
- **Memory map lives in `soc_map.svh`**; update it there and let consumers follow.
- Firmware is assembled, not hand-edited as hex — edit `fw/*.s`, rebuild.

## Layout

```
rtl/cpu_riscv/   CPU (pipeline + single-cycle golden + alu/csr/div/mul/regfile)
rtl/soc/         soc_top + ram/mtimer/uart/gpio
rtl/common/      shared headers (riscv_defs.svh, soc_map.svh)
rtl/generated/   PeakRDL output (gitignored)
fw/              firmware (.s) + assembled .hex
tb/directed/     golden-trace differential testbench + golden ISS
sim/cocotb/      SoC cocotb testbench (UART + interrupts)
flow/formal/     SymbiYosys proofs   flow/sta|pnr/  signoff stage scripts
tools/           rvasm.py, yosys/ scripts, verilator waivers, sim helpers
scripts/         metrics.py, gen_regs.sh, hooks
gds_flow/        proven sky130 GDSII (OpenLane) + signoff reports
```
