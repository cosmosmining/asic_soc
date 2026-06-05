# RTL → GDSII flow (sky130)

Honest status of physical implementation for this project.

## What runs *here* (macOS, no Docker)

- **Real-PDK standard-cell synthesis.** `tools/scripts/synth_sky130.sh` maps the
  RTL onto the actual **SkyWater sky130 `sky130_fd_sc_hd`** standard cells using
  Yosys + ABC and reports **true cell count and silicon area (µm²)** plus a
  technology-mapped gate netlist (`build/<top>_sky130.v`). This is genuine ASIC
  synthesis against a real foundry library — the step immediately before P&R.
- PDK fetched with `volare` into `tools/pdk` (see below).

## What needs a Docker host (not available here)

Full place-and-route to a routed **GDSII** needs **OpenROAD/OpenLane**, which run
as Linux containers. The complete, ready-to-run config is in
`tools/openlane/config.json`. On any machine with Docker:

```sh
# 1. get OpenLane (v1)
git clone https://github.com/The-OpenROAD-Project/OpenLane
cd OpenLane && make            # pulls the sky130 PDK + tool image

# 2. point it at this design and run the full flow
./flow.tcl -design /path/to/asic_soc/tools/openlane

# outputs: floorplan -> placement -> CTS -> routing -> GDSII
#          + DRC (magic/klayout) + LVS (netgen) + timing (OpenSTA)
# GDS lands in runs/<tag>/results/final/gds/riscv_pipeline.gds
```

## Getting the PDK locally (for std-cell synthesis)

```sh
python3 -m venv tools/.venv
tools/.venv/bin/pip install volare
PDK_ROOT=$PWD/tools/pdk tools/.venv/bin/volare enable --pdk sky130 \
    c6d73a35f524070e85faff4a6a9eef49553ebc2b
PDK_ROOT=$PWD/tools/pdk tools/scripts/synth_sky130.sh riscv_pipeline
```

## Is it "ready to fab"? — No (and what that would take)

A GDSII alone is **not** a tapeout. Fab-readiness requires, on top of the routed GDS:

1. **DRC clean** (design-rule check) and **LVS clean** (layout-vs-schematic).
2. **Timing signoff** (setup/hold across PVT corners with OpenSTA).
3. **Antenna / fill / IO** handling and a **packaging/pad** plan.
4. A **foundry shuttle slot** (e.g., Tiny Tapeout for small designs) — real money
   and a real queue.

What we have today: RTL **functionally verified** (independent golden-model
differential test over directed + ~260 randomized programs) and **synthesizable
against the real sky130 library with area numbers**. That is a solid, honest
pre-physical milestone — not silicon.
