# asic_soc — Autonomous ASIC SoC

A from-scratch, fully open-source RISC-V SoC, taken from RTL toward GDSII with
Yosys + OpenROAD/OpenLane. No vendor IP, no black boxes. Every change is proven
by an independent golden-model differential test and lints clean under Verilator.

## What exists today

```
                         +-----------------------------------------+
                         |               riscv_soc                 |
                         |                                         |
   +---------------------+--------------------+                    |
   |  cpu (riscv_pipeline)                     |                   |
   |  RV32IM, 5-stage IF/ID/EX/MEM/WB          |                   |
   |  - full forwarding + load-use stall       |                   |
   |  - dynamic branch predictor (BTB+2bit BHT)|                   |
   |  - sequential multiplier + divider        |                   |
   |  - Zicsr + M-mode traps (ECALL/EBREAK/MRET,|                  |
   |    illegal, misaligned, mcycle/minstret)  |                   |
   +------------------+-----------+------------+                   |
        imem (req/ready) |         | dmem (req/ready)              |
                 v                 v                               |
          +------------+    +------------+                         |
          |  I-cache   |    |  D-cache   |   direct-mapped         |
          | read-only  |    | write-thru |   (line fill = AXI rds) |
          +-----+------+    +-----+------+                         |
                | AXI4-Lite M     | AXI4-Lite M                    |
                v                 v                                |
          +-----------------------------------+                    |
          |   axil_arb  (2->1 AXI4-Lite xbar) |                    |
          +-----------------+-----------------+                    |
                            | AXI4-Lite                            |
                            v                                      |
                    +---------------+                              |
                    |   axi_sram    |  AXI4-Lite SRAM slave        |
                    +---------------+                              |
                         +-----------------------------------------+
```

A second, single-cycle core (`riscv_core`) is the *verification reference*: the
same golden-trace testbench validates both microarchitectures, so the simple
core cross-checks the pipeline on every test.

**Planned (not yet built):** GPU SIMD lanes and an ARM-like educational core
sharing the AXI fabric; machine-timer interrupts (CLINT).

## Measured PPA (real SkyWater sky130)

`sky130_fd_sc_hd`, typical corner (`tt_025C_1v80`), Yosys technology mapping:

| top | std cells | cell area |
|-----|-----------|-----------|
| `riscv_pipeline` (CPU core) | 15,342 | **151,693 µm² ≈ 0.152 mm²** |

Reproduce: `make synth-sky130` or `tools/scripts/ppa.sh riscv_pipeline 12`.
Timing closure (Fmax) and power are driven by `ppa.sh` via OpenSTA, and the
full RTL→GDSII backend (place/route/CTS, DRC) by the OpenROAD/OpenLane flow in
`gds_flow/` (see `gds_flow/README.md`).

## Repo layout

```
rtl/
  cpu_riscv/     regfile, alu, csr, divider, mul_seq, riscv_core (1-cycle), riscv_pipeline (5-stage)
  soc/           axi_sram, riscv_cache (I$/D$), axil_arb, riscv_soc (top)
  common/        shared headers (encodings, CSR addrs, trap causes)
tb/
  directed/      golden ISS + differential TBs (core + SoC), programs, generators
  uvm/           UVM environment (for a commercial simulator)
formal/          SVA properties
tools/           yosys / openroad / verilator / pd scripts + sky130 PDK liberty
gds_flow/        physical-flow driver + reports
```

## Quick start

```sh
make tools      # one-time: install iverilog + verilator
make lint       # Verilator -Wall, zero warnings (core + pipeline + SoC)
make regress    # differential regression: both cores + full SoC + random seeds
make sim-soc    # run a program through pipeline + I$/D$ + AXI4-Lite SRAM
make synth-sky130   # map the CPU onto sky130 and report area
```

## Conventions

- SystemVerilog (IEEE 1800-2017), synthesizable subset for `rtl/`.
- Global active-low reset `rst_n`, single clock `clk`.
- Independent golden model + constrained-random differential testing; CI gates
  every push on lint + regression (`.github/workflows/ci.yml`).

See `PROGRESS.md` for the iteration-by-iteration engineering log.
