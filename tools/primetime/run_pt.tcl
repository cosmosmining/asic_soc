# =============================================================================
# run_pt.tcl -- PrimeTime multi-corner timing signoff driver for riscv_pipeline
#
#   pt_shell -f tools/primetime/run_pt.tcl
#
# Loops the signoff corners (slow=setup, fast=hold, typical=reference), applies
# the same SDC at each, and writes report_timing dumps in the layout that
# tools/pd/pt_report_parser.py classifies. Mirrors the Innovus/PrimeTime loop a
# PD team runs at Apple/Qualcomm; the open-source equivalent (OpenSTA) takes the
# same SDC and the same report_timing -- see tools/primetime/README.md.
#
# This is a real, ready-to-run pt_shell script. It is NOT executed in CI here
# (PrimeTime is a commercial tool); the parser it feeds IS unit-tested against
# representative captures of its output (tools/pd/tests/).
# =============================================================================

set SCRIPT_DIR [file dirname [info script]]
set REPORT_DIR [expr {[info exists ::env(REPORT_DIR)] ? $::env(REPORT_DIR) : "reports/pt"}]

# Conservative signoff analysis settings.
set_app_var timing_enable_preset_clock_uncertainty true
set_app_var timing_remove_clock_reconvergence_pessimism true   ;# CRPR/PBA-lite
set_app_var report_default_significant_digits 4

source $SCRIPT_DIR/mmmc.tcl
source $SCRIPT_DIR/report_signoff.tcl

foreach corner $CORNER_ORDER {
    puts "============================================================"
    puts " corner: $corner"
    puts "============================================================"
    remove_design -all
    set check [load_corner $corner]

    # On-chip variation: derate cells/nets so signoff carries margin.
    set_timing_derate -early 0.95 -late 1.05

    read_sdc $SCRIPT_DIR/constraints.sdc

    report_signoff $corner $check $REPORT_DIR
}

puts ""
puts "Signoff reports in $REPORT_DIR/. Classify violations with:"
puts "  python3 tools/pd/pt_report_parser.py $REPORT_DIR/*_setup.rpt $REPORT_DIR/*_hold.rpt --csv $REPORT_DIR/violations.csv"
exit
