# soc_chip.sdc - timing constraints for the hardened SoC top.
# 50 MHz (20 ns) baseline, matching the sky130 pipeline GDS. rst_n and the GPIO
# pins are slow/quasi-static; the UART pin is a registered output.
set clk_period 20.0
create_clock -name clk -period $clk_period [get_ports clk]
set_clock_uncertainty 0.25 [get_clocks clk]

# asynchronous, quasi-static reset -- relax it from the data-path timing
set_false_path -from [get_ports rst_n]

# generic block-level IO budget
set_input_delay  [expr 0.30 * $clk_period] -clock clk [get_ports gpio_in*]
set_output_delay [expr 0.30 * $clk_period] -clock clk [get_ports {gpio_out* uart_tx}]
