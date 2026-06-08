# config.mk - OpenROAD-flow-scripts (ORFS) configuration for the RV32IM pipeline.
#
# Drop this design into ORFS (designs/sky130hd/riscv_pipeline/config.mk) and run
#   make DESIGN_CONFIG=flow/pnr/config.mk
# ORFS drives Yosys -> OpenROAD (floorplan/place/CTS/route) -> OpenSTA/Magic/
# KLayout, emitting per-stage metrics that `scripts/metrics.py` can ingest. The
# repo's gds_flow/ already carries a proven sky130 GDSII via OpenLane; ORFS is
# the alternative orchestrator with the same RTL.
export PLATFORM            = sky130hd
export DESIGN_NAME         = riscv_pipeline

export VERILOG_FILES = $(sort $(wildcard ./rtl/cpu_riscv/*.sv))
export SDC_FILE      = ./flow/sta/riscv_pipeline.sdc

# floorplan: utilisation + aspect ratio (the knobs the agent sweeps)
export CORE_UTILIZATION    = 40
export CORE_ASPECT_RATIO   = 1
export CORE_MARGIN         = 2
export PLACE_DENSITY       = 0.55

export CLOCK_PORT          = clk
export CLOCK_PERIOD        = 20.0
