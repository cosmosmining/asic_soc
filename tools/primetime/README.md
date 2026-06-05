# PrimeTime multi-corner signoff

Ready-to-run `pt_shell` scripts that sign off `riscv_pipeline` timing across PVT
corners and emit `report_timing` in the exact layout
`tools/pd/pt_report_parser.py` classifies. This is the commercial-EDA half of
the flow (the open-source half is OpenLane/OpenROAD in `gds_flow/`); PD teams at
Apple/Qualcomm run Innovus for P&R and PrimeTime for signoff, both driven by Tcl
exactly like this.

| file | role |
|------|------|
| `mmmc.tcl` | corner definitions + `load_corner` (links sky130 liberty + SPEF per corner) |
| `constraints.sdc` | signoff SDC (clock, uncertainty, I/O budgets, false paths, DRVs) |
| `report_signoff.tcl` | `report_timing` / `report_qor` / `report_constraint` per corner |
| `run_pt.tcl` | driver: loops corners (setup@slow, hold@fast, ref@typical) |

## Corner discipline

| corner | liberty | signs off | why |
|--------|---------|-----------|-----|
| `ss_100C_1v60` | slow / hot / low-V | **setup** (max delay) | longest paths are worst here |
| `ff_n40C_1v95` | fast / cold / high-V | **hold** (min delay) | shortest paths are worst here |
| `tt_025C_1v80` | typical | reference | sanity / reporting |

`set_timing_derate -early 0.95 -late 1.05` adds OCV margin; CRPR removal keeps
the pessimism honest.

## Run

```sh
# 1. produce a gate netlist + SPEF from P&R (OpenROAD/Innovus), then:
export PDK_ROOT=$PWD/tools/pdk NETLIST_DIR=$PWD/build SPEF_DIR=$PWD/build/spef
pt_shell -f tools/primetime/run_pt.tcl

# 2. classify everything that failed
python3 tools/pd/pt_report_parser.py reports/pt/*_setup.rpt reports/pt/*_hold.rpt \
    --csv reports/pt/violations.csv
```

Re-run the 250 MHz stress target by overriding the period:

```sh
pt_shell -x "set CLK_PERIOD_NS 4.0" -f tools/primetime/run_pt.tcl
```

## Open-source equivalent (no PrimeTime license)

OpenSTA takes the **same SDC** and the **same `report_timing`**, so the parser
doesn't care which produced the report:

```tcl
read_liberty sky130_fd_sc_hd__ss_100C_1v60.lib
read_verilog build/riscv_pipeline.v
link_design  riscv_pipeline
read_spef    build/spef/riscv_pipeline.ss.spef
read_sdc     tools/primetime/constraints.sdc
report_timing -path_type full_clock_expanded -slack_less_than 0.5 \
    > reports/pt/ss_100C_1v60_setup.rpt
```

## Note on execution

These are genuine scripts, not pseudo-code — but PrimeTime is commercial and is
not in this repo's CI. What *is* tested (in `tools/pd/tests/`) is the parser that
consumes their output, against representative captures of this exact format.
