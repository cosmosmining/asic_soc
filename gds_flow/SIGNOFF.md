# RTL → GDSII signoff — riscv_pipeline (Sky130, OpenLane/OpenROAD)

Final routed layout produced by the full open-source flow (Yosys → OpenROAD
floorplan/place/CTS/route → Magic/KLayout GDS → Magic DRC + Netgen LVS).

**Artifacts**
- `signoff/riscv_pipeline.gds.gz` — final GDSII (112 MB raw, 21 MB gz)
- `signoff/drc.rpt`, `signoff/lvs.rpt`, `signoff/sta_signoff_summary.rpt`, `signoff/metrics.csv`

## Signoff results (run6)
| check | result |
|-------|--------|
| **Magic DRC** | **0 violations** ✅ |
| **Netgen LVS** | **0 mismatches** (no net/device/pin/property errors) ✅ |
| **Detailed routing (TritonRoute)** | **0 violations** — fully routed ✅ |
| **Setup (signoff, RCX typical corner)** | **+4.82 ns slack (MET)** ✅ |
| **Hold (signoff, RCX typical corner)** | **+0.24 ns slack (MET)** ✅ |
| **Die area** | 2.03 mm² (core 1.99 mm²), 16.3% utilization |
| **Target clock** | 50 MHz (20 ns) |

## Honest caveats
- **Slow (ss) corner not fully closed:** multi-corner STA shows negative slack at
  the slowest corner because the **post-route timing resizer was disabled** to work
  around an OpenROAD `repair_timing` segfault under x86 emulation (Colima on Apple
  Silicon). The nominal/typical signoff corner is clean at 50 MHz. Full multi-corner
  closure would re-enable `GLB_RESIZER_TIMING_OPTIMIZATIONS` on a native Linux host.
- Memories are flip-flop based (no SRAM macros), so area is dominated by registers.

## Reproduce
```bash
# inside the OpenLane docker (sky130A PDK via ciel/volare):
./flow.tcl -design riscv_pipeline -pdk sky130A -tag run -overwrite
# config: gds_flow/openlane_config.json
```
