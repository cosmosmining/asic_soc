# riscv_pipeline.sdc - timing constraints for post-synthesis STA.
# 50 MHz baseline (20 ns), matching the sky130 GDS flow; tighten as timing
# closes. Inputs/outputs given generous external delay for a block-level run.
set clk_period 20.0
create_clock -name clk -period $clk_period [get_ports clk]

set_clock_uncertainty 0.25 [get_clocks clk]
set_input_delay  [expr 0.30 * $clk_period] -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay [expr 0.30 * $clk_period] -clock clk [all_outputs]
