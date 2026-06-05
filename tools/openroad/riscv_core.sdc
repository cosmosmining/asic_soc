# riscv_core.sdc - timing constraints for the RV32IM core.
# Baseline target: 100 MHz (10 ns). Tighten as the pipeline lands.
set CLK_PERIOD 10.0
create_clock -name clk -period $CLK_PERIOD [get_ports clk]

# async active-low reset: treat as false path for setup/hold
set_false_path -from [get_ports rst_n]

# conservative I/O budgets (single-cycle core talks to external memories)
set_input_delay  -clock clk [expr 0.30 * $CLK_PERIOD] [all_inputs]
set_output_delay -clock clk [expr 0.30 * $CLK_PERIOD] [all_outputs]

# clock uncertainty / transition guardbands
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition  0.15 [get_clocks clk]
