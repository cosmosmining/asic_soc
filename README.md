# asic_soc — an agent-built, open-source RV32IM SoC

A from-scratch RISC-V microcontroller SoC taken **RTL → GDSII entirely with
open-source tools**, and built to be driven by Claude Code: every stage is a
batch `make` target with a real exit code, so the loop gates on pass/fail, not on
eyeballing logs. See [`CLAUDE.md`](CLAUDE.md) for the flow brain,
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design, and
[`docs/FLOW.md`](docs/FLOW.md) for the full tool flow.

## What's built

- **RV32IM 5-stage pipeline** — forwarding, load-use stall, BTB + 2-bit BHT
  branch prediction, multi-cycle mul/div, Zicsr + machine-mode traps, and
  **machine interrupts** (timer / software / external).
- **Integrated SoC** — CPU + single-cycle RAM + CLINT machine timer + UART + GPIO
  over an address-decoded bus (`rtl/soc/soc_top.sv`).
- **Independent golden model** — a single-cycle core is the differential reference
  for the pipeline; the same testbench checks both.
- **Firmware toolchain** — a dependency-free RV32IM assembler (`tools/scripts/rvasm.py`).
- **Verification** — golden-trace differential regression, a cocotb SoC testbench
  (UART + interrupts), and SymbiYosys formal proofs.
- **Physical** — a real routed sky130 GDSII of the pipeline (OpenLane, in
  `gds_flow/`): router DRC 0, Magic DRC 0, LVS 0.

```
                         soc_top
   ┌──────────────────────────────────────────────────────────┐
   │  riscv_pipeline (RV32IM)  ── imem/dmem ──┐                 │
   │   IF·ID·EX·MEM·WB, fwd, BP, mul/div, IRQ │                 │
   │                                          ▼   address decode│
   │   soc_ram ◀── 0x0000   CLINT 0x0200 ─ timer_irq ──┐        │
   │              UART 0x1000 ─ tx pin    GPIO 0x1001 ─ pins    │
   │              CLINT timer/sw interrupt ────────────┘        │
   └──────────────────────────────────────────────────────────┘
```

## Quick start

```sh
make tools        # install the open-source toolchain (apt + pip)
make all          # the gate: lint + regression + SoC cocotb + formal
make sim-soc      # run the SoC firmware (UART banner + 5 timer interrupts)
make metrics      # reports/summary.json: synth / formal / cocotb / signoff
make help         # every stage target
```

## Flow stages (all open-source)

| RTL→GDSII | tool | target |
|---|---|---|
| lint · regs · sim · regress · SoC sim · formal · synth | Verilator · PeakRDL · Icarus · cocotb · SymbiYosys · Yosys | `make lint regs sim regress sim-soc formal synth-soc` |
| sky130 map · STA · PnR · DRC · LVS | Yosys · OpenSTA · OpenROAD/ORFS · Magic · Netgen | `make synth-sky130 sta pnr drc lvs` |

Stages 0–9 run locally; the physical stages need the sky130 PDK + heavier tools
(IIC-OSIC-TOOLS image) and degrade with guidance otherwise. Full mapping and the
honest gaps vs. a commercial flow are in [`docs/FLOW.md`](docs/FLOW.md).

## Layout

```
rtl/cpu_riscv/  CPU       rtl/soc/  SoC blocks       rtl/common/  shared headers
tb/directed/    golden-trace TB     sim/cocotb/  SoC cocotb TB
flow/formal/    SymbiYosys proofs   flow/sta|pnr/  signoff stage scripts
fw/             firmware (.s)       regs/  SystemRDL    tools/ scripts/  helpers + hooks
gds_flow/       proven sky130 GDSII + signoff reports
```

## Status

The RV32IM SoC is functionally verified (regression + cocotb), formally checked
(ALU equivalence + pipeline safety BMC — which found and fixed a real `mepc`
alignment bug), synthesizes cleanly, and the pipeline has a DRC/LVS-clean sky130
GDSII. Open items and the iteration log are in [`PROGRESS.md`](PROGRESS.md);
future cores (ARM-like, SIMD GPU) and a cached AXI memory subsystem are tracked
there as backlog.
