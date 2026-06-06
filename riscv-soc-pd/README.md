# riscv-soc-pd — physical design (PD track)

Hands-on P&R to complement DeepDGR (which is ML-*on*-PD, not flow experience).

> **Process gate (your rule):** you write the SDC constraints. I review/critique them
> rather than write them for you.

## Deliverables & status
- [x] Python CLI (`timing_cli/`): parse OpenSTA/PrimeTime timing reports, classify violations
      (logic depth vs RC vs clock skew), emit a fix-suggestion table; **pip-installable + tested**
- [ ] OpenLane2 / OpenROAD on sky130: floorplan, PDN, placement, CTS, routing, signoff
      (DRC/LVS clean). Sweep **3 utilization/clock-target combos**; record WNS/TNS,
      utilization, total wirelength, achieved fmax per run
- [ ] Mirror-image Innovus + PrimeTime script set (CMU); you author the SDC, I critique
- [ ] Tie-in: observed routing-congestion hotspots vs DeepDGR predictions on the same design — one plot

## Tiering (honesty)
Runnable here: the **Python timing CLI** (pip-installable, tested); OpenLane2/OpenROAD sweep
(next). `pending-CMU`: Innovus + PrimeTime. DeepDGR tie-in needs your model's predictions for
this design (or a documented stub until then).

## Results
| Deliverable | Value | Provenance |
|-------------|-------|-----------|
| timing CLI — classifier | **PASS** — 3 causes (logic-depth / RC / skew) correctly classified | `CI` — `python tests/test_classify.py` |
| timing CLI — packaging | **pip-installable** (`timing-report` console script) | `CI` — `pip install -e .` |
| sky130 P&R sweep (WNS/TNS/util/WL/fmax) | — | ⬜ OpenLane (next) |
| Innovus + PrimeTime | — | ⏳ `pending-CMU` (you author SDC, I critique) |
