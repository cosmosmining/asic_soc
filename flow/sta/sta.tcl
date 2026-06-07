# sta.tcl - OpenSTA timing signoff on the sky130-mapped netlist.
#
# Reads the Liberty, the gate netlist (from `make synth-sky130`) and the SDC,
# then reports worst setup/hold slack and the critical path. OpenSTA's command
# language deliberately mirrors PrimeTime, so this transfers to pt_shell.
#
# Env: LIB (liberty), NETLIST (gate verilog), TOP (top module), SDC.
read_liberty $env(LIB)
read_verilog $env(NETLIST)
link_design $env(TOP)
read_sdc $env(SDC)

puts "==== setup (max) ===="
report_wns
report_tns
report_worst_slack -max

puts "==== hold (min) ===="
report_worst_slack -min

puts "==== critical path ===="
report_checks -path_delay max -fields {slew cap input_pins} -format full_clock_expanded

exit
