# =============================================================================
# constraints.sdc -- signoff timing constraints for riscv_pipeline
#
# Single-clock 5-stage RV32IM core. Written to be corner-agnostic: the same SDC
# is applied at every MMMC corner (see mmmc.tcl); only the libraries and
# parasitics change per corner. Read by PrimeTime (read_sdc) and OpenSTA alike.
# =============================================================================

# ---- primary clock --------------------------------------------------------
# 20 ns / 50 MHz is the taped-out target this design closed at (worst setup
# slack +6.52 ns -> ~74 MHz achievable). Override CLK_PERIOD_NS on the command
# line (e.g. -x "set CLK_PERIOD_NS 4.0") to re-run the 250 MHz stress corner.
if { ![info exists CLK_PERIOD_NS] } { set CLK_PERIOD_NS 20.0 }
create_clock -name clk -period $CLK_PERIOD_NS [get_ports clk]

# ---- clock non-ideality (pre-CTS estimate; CTS replaces with propagated) ---
set_clock_uncertainty -setup 0.25 [get_clocks clk]
set_clock_uncertainty -hold  0.05 [get_clocks clk]
set_clock_transition  0.15        [get_clocks clk]
set_clock_latency     1.00        [get_clocks clk] ;# source+network estimate

# ---- reset: asynchronous, not a timed path --------------------------------
set_false_path -from [get_ports rst_n]

# ---- I/O budgets ----------------------------------------------------------
# The core talks to external IMEM/DMEM and a host; budget ~30% of the period
# for off-core logic on each side so in2reg/reg2out paths are constrained
# honestly rather than left wide open.
set in_ports  [remove_from_collection [all_inputs]  [get_ports {clk rst_n}]]
set out_ports [all_outputs]
set_input_delay  -clock clk [expr {0.30 * $CLK_PERIOD_NS}] $in_ports
set_output_delay -clock clk [expr {0.30 * $CLK_PERIOD_NS}] $out_ports

# ---- drive / load ---------------------------------------------------------
# Drive inputs with a mid-strength inverter; load outputs with a few std-cell
# input pins so transitions are realistic at signoff.
set drv_cell sky130_fd_sc_hd__inv_2
catch { set_driving_cell -lib_cell $drv_cell -pin Y $in_ports }
set_load [expr {4 * 0.002}] $out_ports ;# ~4 fanout of std-cell input cap (pF)

# ---- design rule limits ---------------------------------------------------
set_max_transition 1.50 [current_design]
set_max_capacitance 0.20 [current_design]
set_max_fanout 16 [current_design]
