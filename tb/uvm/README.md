# UVM verification environment

A layered UVM testbench for the RV32IM CPU.

```
riscv_program (seq item)  rand RV32IM instruction stream + halt
        │  via sequencer
   riscv_driver            backdoor-loads program, pulses reset, runs the DUT
   riscv_monitor           samples the RVFI-lite retire bus -> riscv_retire txns
        │  analysis port
   riscv_scoreboard        independent reference ISS + functional coverage;
                           checks every retire in program order
   riscv_agent / env / riscv_random_test
```

## Components
| file | role |
|------|------|
| `riscv_if.sv` | clk/reset, RVFI retire bus, backdoor memory hooks |
| `riscv_uvm_pkg.sv` | item, sequence, sequencer, driver, monitor, scoreboard (+coverage), agent, env, test |
| `tb_uvm_top.sv` | DUT + memory + vif + `run_test` |

## Running it (needs a UVM-1.2 simulator)

UVM requires a commercial simulator or EDA Playground — the open-source
Icarus/Verilator flow used elsewhere in this repo **cannot** run UVM.

```sh
# Synopsys VCS
vcs -full64 -sverilog -ntb_opts uvm-1.2 +incdir+rtl/common \
    rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/alu.sv rtl/cpu_riscv/riscv_pipeline.sv \
    tb/uvm/riscv_if.sv tb/uvm/riscv_uvm_pkg.sv tb/uvm/tb_uvm_top.sv \
    -o simv && ./simv +UVM_TESTNAME=riscv_random_test

# Siemens Questa
qrun -uvm -sv +incdir+rtl/common <same file list> -top tb_uvm_top \
    +UVM_TESTNAME=riscv_random_test

# EDA Playground: UVM 1.2, paste the three tb/uvm files + the three rtl files.
```

## Relationship to the local flow

The scoreboard's reference ISS is the **same algorithm** as
`tb/directed/riscv_golden.sv`, which *is* exercised locally by the Icarus
golden-trace differential test (directed + ~260 randomized programs, all PASS).
So the checking logic is proven; this UVM wrapper packages it in industry-standard
form (factory, config DB, analysis ports, phases, covergroup) for a commercial sim.
