# Open-source RTL → GDSII flow

Every stage of a commercial ASIC flow has an open-source counterpart that runs on
a laptop, license-free. This repo wires them into one `make`-driven, agent-driven
pipeline. Stages 0–9 run in this environment today; the physical stages need the
sky130 PDK and the heavier tools (run them in the IIC-OSIC-TOOLS docker image, or
use the proven OpenLane run already in `gds_flow/`).

| # | Stage              | Open-source tool        | `make` target      | Local? | Commercial analog        |
|---|--------------------|-------------------------|--------------------|--------|--------------------------|
| 0 | Golden model       | independent SV ISS      | (in `make regress`)| ✅     | C/SystemC reference      |
| 1 | RTL + lint         | Verilator `--lint-only` | `make lint`        | ✅     | SpyGlass lint            |
| 2 | Registers/CSRs     | PeakRDL (SystemRDL)     | `make regs`        | ✅     | Agnisys / Semifore       |
| 3 | Directed sim       | Icarus Verilog          | `make sim`         | ✅     | VCS / Xcelium            |
| 4 | Regression (rand)  | Icarus + golden ISS     | `make regress`     | ✅     | UVM + vManager           |
| 5 | SoC sim            | cocotb + Icarus         | `make sim-soc`     | ✅     | UVM system testbench     |
| 6 | Formal             | SymbiYosys + z3         | `make formal`      | ✅     | JasperGold / VC Formal   |
| 7 | Synthesis          | Yosys + ABC             | `make synth-soc`   | ✅     | Design Compiler / Genus  |
| 8 | sky130 mapping     | Yosys + sky130 libs     | `make synth-sky130`| PDK    | DC with foundry libs     |
| 9 | Metrics            | `scripts/metrics.py`    | `make metrics`     | ✅     | QoR dashboards           |
|10 | STA                | OpenSTA                 | `make sta`         | host   | PrimeTime                |
|11 | Place & route      | OpenROAD / ORFS         | `make pnr`         | host   | ICC2 / Innovus           |
|12 | DRC                | Magic / KLayout         | `make drc`         | host   | IC Validator / Calibre   |
|13 | LVS                | Netgen                  | `make lvs`         | host   | IC Validator / Calibre   |
|14 | GDSII              | OpenLane (see gds_flow) | (host pipeline)    | host   | full signoff             |

`make all` runs the local gate: lint + regress + sim-soc + formal.

## Honest gaps vs. a commercial flow

These are real and worth knowing (they are also good interview material):

- **CDC/RDC**: there is no open-source SpyGlass-CDC equivalent. We enforce
  synchroniser conventions by review (the `rtl-reviewer` agent checks for them)
  and keep the design single-clock; GPIO inputs use an explicit 2-flop sync.
- **SI/crosstalk STA**: OpenSTA is not crosstalk-aware. Setup/hold are signed off
  without SI margining — fine at 130 nm, not at advanced nodes.
- **Power/IR**: coarser than PrimePower/RedHawk.
- **UVM**: not supported on the open Icarus/Verilator path, so functional DV uses
  cocotb (Python) plus the differential golden-trace harness. A PeakRDL-generated
  UVM register model is emitted for when a commercial simulator is available.

## Toolchain

`make tools` installs everything (Debian/Ubuntu):

```
apt:  iverilog  verilator  yosys
pip:  cocotb  peakrdl peakrdl-regblock peakrdl-uvm peakrdl-c-header peakrdl-html  z3-solver
src:  SymbiYosys (github.com/YosysHQ/sby)
```

Validated here with Verilator 5.020, Yosys 0.33, Icarus 12.0, cocotb 2.0.1,
PeakRDL 1.5, z3 4.16. Physical stages: sky130 PDK via `volare`, OpenLane/ORFS and
Magic/Netgen/KLayout via the IIC-OSIC-TOOLS image.

## Physical signoff already achieved

`gds_flow/` carries a real routed sky130 GDSII of the pipeline built with OpenLane
(`gds_flow/signoff/`): router DRC 0, Magic DRC 0, LVS 0. `make metrics` surfaces
those numbers. Post-route timing closure and the full SoC harden are the open
items (see `PROGRESS.md`).
