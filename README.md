# asic_soc — Autonomous ASIC SoC

A from-scratch, fully open-source SoC: RV32IM CPU, an ARM-like educational core,
a SIMD GPU, an AXI interconnect, and a memory subsystem, taken from RTL to GDSII
with Yosys + OpenROAD.

## System Architecture (text diagram)

```
                              +-------------------------------+
                              |          asic_soc top         |
                              +-------------------------------+
                                          |  clk / rst_n
        +------------------+  +------------------+  +------------------+
        |  cpu_riscv       |  |  cpu_arm_like    |  |  gpu_simd        |
        |  RV32IM          |  |  educational ISA |  |  8-32 lanes      |
        |  5-stage pipe    |  |  (synth subset)  |  |  warp execution  |
        |  IF ID EX MEM WB |  |                  |  |  vec ALU add/mul |
        |  fwd + hazard    |  |                  |  |  /dot            |
        +--------+---------+  +--------+---------+  +--------+---------+
                 | AXI-lite M          | AXI-lite M          | AXI-lite M
                 v                     v                     v
        +-------------------------------------------------------------+
        |                  interconnect (AXI-lite crossbar)           |
        |                  address decode + round-robin arbitration   |
        +------------------------------+------------------------------+
                                       | AXI-lite S
                                       v
                              +------------------+
                              |  memory          |
                              |  shared SRAM mdl |
                              +------------------+
```

## Repo layout

```
rtl/
  cpu_riscv/     RV32IM core (currently: single-cycle RV32I, pipeline WIP)
  cpu_arm_like/  educational ARM-like core (planned)
  gpu_simd/      SIMD/SIMT vector processor (planned)
  interconnect/  AXI-lite crossbar (planned)
  memory/        SRAM model + AXI-lite slave (planned)
  common/        shared headers / packages
tb/
  directed/      lightweight SV testbenches
  uvm/           UVM environment (planned)
formal/
  assertions/    SVA properties
tools/
  yosys/         synthesis scripts
  openroad/      P&R scripts
  scripts/       sim / build helpers
gds_flow/        flow driver + reports
```

## Conventions

- Language: SystemVerilog (IEEE 1800-2017), synthesizable subset for `rtl/`.
- Global active-low reset `rst_n`, single clock `clk`, 100 MHz baseline target.
- No vendor IP, no black boxes.

## Quick start

```sh
# run the directed RV32I smoke test
tools/scripts/run_sim.sh tb_riscv_core
```

## Status / progress log

See `PROGRESS.md` for the iteration-by-iteration agent log.
