# riscv_pipeline.sdc - timing constraints for sky130 signoff.
# Single clock; conservative IO budget. Override CLK_PERIOD_NS from the flow.
set clk_period $::env(CLK_PERIOD_NS)
create_clock -name clk -period $clk_period [get_ports clk]

# async reset is a false path
set_false_path -from [get_ports rst_n]

# IO timing budget: 30% of the period on inputs, 30% on outputs
set io_delay [expr {0.30 * $clk_period}]
set_input_delay  -clock clk $io_delay [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -clock clk $io_delay [all_outputs]

# a light default output load (a few standard-cell input pins)
set_load 0.05 [all_outputs]
