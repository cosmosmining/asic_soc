# OpenLane 2 (Sky130) flow

`config.json` here is an **OpenLane 2** (Python/Nix flow, aka LibreLane) port of
the validated OpenLane 1 config in `gds_flow/openlane_config.json`. Same design,
same PDK, same RTL-to-GDSII steps — floorplan → power grid → placement → CTS →
global/detailed route → fill → DRC/LVS → multi-corner STA.

## Run

```sh
# one-time: get OpenLane 2 (https://openlane2.readthedocs.io)
pip install openlane            # or use the Nix/Docker image

# stage the SystemVerilog sources next to the config
mkdir -p gds_flow/openlane2/src
cp rtl/cpu_riscv/{regfile,alu,divider,riscv_pipeline}.sv gds_flow/openlane2/src/

cd gds_flow/openlane2 && openlane config.json
# routed GDS:   runs/<tag>/final/gds/riscv_pipeline.gds
# STA reports:  runs/<tag>/**/timing/*.rpt   (report_timing -> pt_report_parser)
# metrics:      runs/<tag>/final/metrics.json (achieved util -> flow_metrics --ol-summary)
```

## Closing the loop with the PD toolkit

```sh
# classify any STA violations from the OL2 run
python3 tools/pd/pt_report_parser.py runs/*/**/timing/*.rpt --csv viol.csv

# fold the achieved utilization into the scorecard
python3 tools/pd/flow_metrics.py --ol-summary runs/<tag>/final/metrics.json
```

## Notes

- **SystemVerilog:** OL2's Yosys reads SV via the slang/synlig frontend. If your
  install lacks it, pre-elaborate with `sv2v` and point `VERILOG_FILES` at the
  generated Verilog.
- **Congestion:** the RV32IM core with its multiplier/divider cones is
  routing-bound; `FP_CORE_UTIL` is kept moderate with `GRT_ALLOW_CONGESTION`,
  matching the lesson from the OL1 run (`gds_flow/openlane_config.json`). This is
  precisely the regime where a better global router (DeepDGR) buys back area or
  closes timing — see `docs/PD_PORTFOLIO.md`.
- Exact step-variable names track the installed OL2 version; the values above are
  the portable subset.
