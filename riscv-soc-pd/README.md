# riscv-soc-pd — physical design (PD track)

Hands-on P&R to complement DeepDGR (which is ML-*on*-PD, not flow experience).

> **Process gate (your rule):** you write the SDC constraints. I review/critique them
> rather than write them for you.

## Deliverables & status
- [ ] OpenLane2 / OpenROAD on sky130: floorplan, PDN, placement, CTS, routing, signoff
      (DRC/LVS clean). Sweep **3 utilization/clock-target combos**; record WNS/TNS,
      utilization, total wirelength, achieved fmax per run
- [ ] Mirror-image Innovus + PrimeTime script set (CMU); you author the SDC, I critique
- [ ] Python CLI: parse PrimeTime/OpenSTA timing reports, classify violations (logic depth
      vs RC vs clock skew), emit a fix-suggestion table; **pip-installable**
- [ ] Tie-in: observed routing-congestion hotspots vs DeepDGR predictions on the same design — one plot

## Tiering (honesty)
Runnable here: OpenLane2/OpenROAD sweep, OpenSTA, the Python CLI. `pending-CMU`:
Innovus + PrimeTime. DeepDGR tie-in needs your model's predictions for this design.

## Results — sweep table
| Run | Util | Clk target | WNS | TNS | Wirelength | fmax | DRC/LVS |
|-----|------|-----------|-----|-----|-----------|------|---------|
| 1 | — | — | — | — | — | — | ⬜ |
| 2 | — | — | — | — | — | — | ⬜ |
| 3 | — | — | — | — | — | — | ⬜ |
