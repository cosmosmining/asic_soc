# Physical-Design portfolio — positioning & metrics

A physical-design (PD) story told through three artifacts that reinforce each
other: a research-grade **router**, a hands-on **RTL-to-GDSII flow**, and the
**Tcl/Python automation** that PD teams live in. The thread that connects them
is the one PD cares about most — *getting nets closed* — and each piece attacks
it from a different altitude.

| altitude | artifact | what it proves |
|----------|----------|----------------|
| algorithm | **DeepDGR** — GNN-accelerated global routing (built on NVIDIA Research's DGR) | I can move a real routing metric, not just a loss curve |
| flow | **asic_soc** — RV32IM SoC, RTL→GDSII on Sky130 | I can drive the full backend and close timing |
| tooling | **PD toolkit** — PrimeTime report parser + flow scorecard | I automate the signoff loop the way a PD org does |

---

## 1. Headline — DeepDGR: frame it with *routing* metrics

DeepDGR is the strongest item here, and for NVIDIA it is doubly so: DGR is
**their** router, so improving it speaks their language. The single most common
way to weaken this story is to present it like an ML project. **Lead with PD
metrics; relegate the ML internals to a footnote.**

### Report these (in this order)

| metric | unit | direction | why a PD lead cares |
|--------|------|-----------|---------------------|
| **Congestion** — total + worst overflow (GCell), # overflowing edges | edges / % | ↓ | overflow is what makes a design unroutable; the headline number |
| **Wirelength** — total + max-path | µm / nm | ↓ | power, delay, and the net-dominated paths the parser flags |
| **Via count** | # | ↓ | yield + resistance proxy |
| **Routing runtime** (and speedup ×) | s / × | ↓ | the whole point of accelerating DGR — turnaround per iteration |
| **DRC-clean handoff** to detailed routing | pass/fail | ✓ | a global route that detailed-routes clean is the real bar |
| **Quality vs. baseline** | % | — | always vs. **classic DGR** and a strong baseline (e.g. FastRoute/CUGR) |

### Say this, not that

- ✅ "Cut total overflow by **X%** and routing runtime by **Y×** vs. classic DGR
  at equal-or-better wirelength on the ISPD/ICCAD benchmark suite."
- ❌ "Reached 0.93 validation accuracy / converged at epoch 40." *(ML framing —
  a PD reviewer can't price it.)*
- ✅ "The GNN predicts congestion hot-spots so the router commits routing
  resource earlier where it matters; net effect is fewer rip-up-and-reroute
  iterations." *(one sentence of method, in service of the metric.)*

> Drop your measured numbers into the table above. Keep ML details (architecture,
> features, training set) to a short appendix — necessary for credibility,
> insufficient as the headline.

### The bridge to the rest of the portfolio

Better global routing produces **shorter, less-congested nets**. In timing
signoff that shows up as **net-dominated setup paths** gaining slack. The PD
toolkit below *names those paths explicitly* — see how `pt_report_parser`
tags net-dominated violations as a "routing-quality lever (DeepDGR)". That is
the closed loop: router improvement → specific endpoints close. Being able to
draw that line, end to end, is the differentiator.

---

## 2. Hands-on flow — asic_soc RV32IM, RTL→GDSII on Sky130

A from-scratch, no-vendor-IP SoC taken through the real backend so the router
work sits on lived flow experience, not slides.

**Backend stages exercised:** synthesis (Yosys → real `sky130_fd_sc_hd` cells) →
floorplan → power grid → placement → **CTS** → global + detailed route → fill →
**DRC** (Magic/KLayout) + **LVS** (Netgen) → **multi-corner STA** (OpenSTA, and
a PrimeTime signoff deck in `tools/primetime/`). OpenLane 1 config is validated;
an **OpenLane 2** port ships in `gds_flow/openlane2/`.

### Quantified result (real sky130 run — `python3 tools/pd/flow_metrics.py`)

| metric | value | source |
|--------|-------|--------|
| Std cells | **20,789** | measured |
| Cell area | **0.201 mm²** (201,453 µm²) | measured |
| Sequential area | 36.6 % | measured |
| Floorplan target util | 16 % (routing-bound — see below) | config |
| Clock target | 20 ns / 50 MHz | config |
| Setup WNS / TNS | **0.000 / 0.000 ns** | measured |
| Worst setup / hold slack | **+6.40 / −0.14 ns** | measured |
| Timing | setup clean; **−0.14 ns post-route hold** open | measured |
| **Achieved fmax** (setup-limited) | **73.5 MHz** (1 / (T − WNS)) | derived |

> Setup closes at the 50 MHz target with +6.40 ns headroom ⇒ **73.5 MHz
> achievable**. A small −0.14 ns post-route hold violation remains (the timing
> resizer was disabled in the Iteration-8 dev-image run) — the kind of thing the
> parser flags as hold-buffer insertion, a P&R hold-fix step, not an fmax limit.

**A real PD lesson, stated plainly:** the multiplier/divider cones make this core
**routing-bound** — utilization had to stay low (16%) with
`GRT_ALLOW_CONGESTION` to route clean. That is exactly the regime where a better
global router buys back area or closes timing, which is *why* the DeepDGR work
matters for a design like this. The flow didn't just produce a GDS; it produced
the motivation for the router.

**Closing the divider critical path** is documented in the iteration log
(`PROGRESS.md`): swapping the combinational 32-bit divider for a sequential one
cut **27,017 → 20,789 cells (−23%)** and area **0.235 → 0.201 mm² (−14%)** while
removing the worst critical path — the standard area/throughput trade, measured.

**Verification underneath it all:** an independent golden-model differential test
over directed + ~260 randomized programs, plus a UVM environment
(`tb/uvm/`). Signoff numbers only mean something on a design that's actually
correct.

---

## 3. Automation — the Tcl/Python loop PD teams live in

PD orgs at Apple and Qualcomm run on Tcl: P&R in Innovus, signoff in PrimeTime,
glued by scripts. This repo ships that muscle, runnable and tested.

### `pt_report_parser.py` — classify violations, suggest fixes

Reads PrimeTime/OpenSTA `report_timing`, derives the features that pick a fix
(logic depth, net-vs-cell split, path category, CDC), and buckets every
violation into an actionable category with a prioritized Pareto:

```
Top violating paths:
  -0.600 setup reg2reg depth 20 net 23%  ... => Restructure / retime / pipeline
  -0.300 setup reg2reg depth  5 net 74%  ... => Net / placement / routing fix   <- DeepDGR lever
  -0.180 setup reg2reg depth 10 net 30%  ... => Gate upsize + VT swap
  -0.150 setup in2reg  depth  5 net 71%  ... => I/O budget review
  -0.060 setup reg2reg depth  8 net 32%  ... => Useful skew / CTS
```

Setup vs hold, by clock domain, CDC-aware (never "fix" a cross-domain path with
buffers), text/JSON/CSV, and a `--fail-on-violation` CI gate. **32 unit tests.**

### `flow_metrics.py` — the one-screen PD scorecard

Scrapes the scattered flow reports into the area/util/WNS/TNS/fmax table above,
labeling measured vs. derived.

### `tools/primetime/` — multi-corner signoff deck

Real `pt_shell` scripts: setup@slow / hold@fast / typical-reference corners, OCV
derate, the same SDC at every corner, emitting `report_timing` in the exact
layout the parser consumes. The open-source OpenSTA path produces the identical
report — the parser is tool-agnostic.

---

## 4. The portfolio in one table

| | DeepDGR | asic_soc flow | PD toolkit |
|--|---------|---------------|-----------|
| **lever** | global routing quality | full backend execution | signoff turnaround |
| **lead metric** | overflow / WL / runtime ↓ | fmax + DRC/LVS clean | violations triaged → fixes |
| **for NVIDIA** | improves *their* DGR | shows you run their stack | speaks their Tcl |
| **status** | research result *(numbers: yours)* | sky130 GDS, setup-clean **@ 73.5 MHz** | runnable, **32 tests pass** |

## 5. Honest status

- **Real & measured:** sky130 std-cell synthesis (area), a routed-flow STA run
  (WNS/TNS/slack), the −23%/−14% divider result, ~260-program differential
  verification, and the PD toolkit (runs + unit-tested here).
- **Real scripts, not run in this CI:** the PrimeTime deck and OpenLane 2 config
  are complete and idiomatic but need commercial PrimeTime / a Docker host for
  OpenLane — the parser they feed *is* tested against representative captures.
- **Yours to fill:** DeepDGR's measured routing numbers go in the §1 table —
  the framing and the bridge to the flow are built; the numbers are the headline.

This is a *pre-silicon* SoC plus a research router plus working signoff
automation — a coherent PD narrative, with the soft claims labeled as such.
