# =============================================================================
# mmmc.tcl -- multi-corner library/parasitic setup for PrimeTime signoff
#
# Defines the signoff corners and a `load_corner` proc that links the matching
# sky130 liberty and back-annotates the matching SPEF. Setup is signed off at
# the SLOW corner (max delay), hold at the FAST corner (min delay), with TT as
# the reference. This is the standard PVT-corner discipline a real block uses;
# add OCV / derating (set_timing_derate) for an even more conservative signoff.
#
# Point PDK_ROOT at the sky130 PDK (the repo fetches it with volare, see
# gds_flow/README.md) and NETLIST_DIR/SPEF_DIR at your P&R outputs.
# =============================================================================

set PDK_ROOT    [expr {[info exists ::env(PDK_ROOT)] ? $::env(PDK_ROOT) : "tools/pdk"}]
set LIB_DIR     "$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib"
set NETLIST_DIR [expr {[info exists ::env(NETLIST_DIR)] ? $::env(NETLIST_DIR) : "build"}]
set SPEF_DIR    [expr {[info exists ::env(SPEF_DIR)]    ? $::env(SPEF_DIR)    : "build/spef"}]
set TOP         riscv_pipeline

# corner name -> {liberty_basename  check_type  spef_basename}
#   check_type: max => setup signoff, min => hold signoff, both => report both
array set CORNERS {
    ss_100C_1v60 {sky130_fd_sc_hd__ss_100C_1v60  max  riscv_pipeline.ss.spef}
    tt_025C_1v80 {sky130_fd_sc_hd__tt_025C_1v80  both riscv_pipeline.tt.spef}
    ff_n40C_1v95 {sky130_fd_sc_hd__ff_n40C_1v95  min  riscv_pipeline.ff.spef}
}
# Signoff order: worst-case setup first, then hold, then reference.
set CORNER_ORDER {ss_100C_1v60 ff_n40C_1v95 tt_025C_1v80}

# ---------------------------------------------------------------------------
# load_corner CORNER -- (re)link libs + netlist + parasitics for one corner.
# ---------------------------------------------------------------------------
proc load_corner {corner} {
    global CORNERS LIB_DIR NETLIST_DIR SPEF_DIR TOP
    lassign $CORNERS($corner) lib check spef

    set_app_var search_path  [list . $LIB_DIR $NETLIST_DIR]
    set_app_var link_path    [list * $lib.db $lib.lib]

    # liberty: prefer compiled .db, fall back to .lib
    if {[file exists $LIB_DIR/$lib.db]} {
        read_db $LIB_DIR/$lib.db
    } else {
        read_lib $LIB_DIR/$lib.lib
    }

    read_verilog $NETLIST_DIR/${TOP}.v
    current_design $TOP
    link_design $TOP

    # parasitics (real wire RC). Without SPEF, PT falls back to estimated nets.
    if {[file exists $SPEF_DIR/$spef]} {
        read_parasitics -format SPEF $SPEF_DIR/$spef
    } else {
        puts "WARN: $SPEF_DIR/$spef not found -- using estimated parasitics."
    }
    return $check
}
