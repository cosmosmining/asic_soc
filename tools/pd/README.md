# PD automation toolkit

Two small, dependency-free (Python 3.8+ stdlib) tools that do the unglamorous
work a physical-design engineer repeats every day: read signoff text, and turn
it into a decision.

| tool | input | output |
|------|-------|--------|
| `pt_report_parser.py` | PrimeTime / OpenSTA `report_timing` dumps | classified violations + a prioritized **fix strategy** (text / JSON / CSV) |
| `flow_metrics.py` | Yosys area + OpenSTA timing summary + config | a one-screen **PD scorecard** (area, util, WNS/TNS, fmax) |

Both are unit-tested (`pytest tools/pd/tests`, 32 cases) against representative
PrimeTime captures and the repo's real flow reports.

---

## 1. `pt_report_parser.py` — classify timing violations, suggest fixes

A real block emits thousands of `report_timing` paths across corners. Eyeballing
them doesn't scale. This parser reads the standard `-path_type
full_clock_expanded` layout (PrimeTime and OpenSTA are identical here), derives
the PD features that actually pick the fix, and buckets every violation:

- **Features per path:** check type (setup/hold), launch/capture clock,
  path group, slack, logic depth (combinational levels), net-vs-cell delay
  split, path category (reg2reg / in2reg / reg2out / in2out), cross-domain (CDC).
- **Fix classifier** (what a PD engineer would actually reach for):

  | category | triggered when | the move |
  |----------|----------------|----------|
  | Restructure / retime / pipeline | deep logic (≥18 levels) | cut depth — upsizing won't close it |
  | Net / placement / routing fix | interconnect ≥40% of the path | buffer, shorten wire, relieve congestion — **the global-routing lever (DeepDGR)** |
  | Gate upsize + VT swap | cell-dominated, moderate depth | upsize worst cells, HVT→LVT |
  | Useful skew / CTS | near-miss (\|slack\|≤0.1 ns) | borrow time at the clock |
  | I/O budget review | in2reg / reg2out | fix `set_input/output_delay`, often a constraint |
  | Hold-buffer insertion | same-clock hold | delay cells in the P&R hold step |
  | CDC / constraint review | launch ≠ capture clock | `false_path`/`multicycle` *before* optimizing |

### Run it

```sh
# classify one corner's worst paths
python3 tools/pd/pt_report_parser.py tools/pd/samples/setup_ss_corner.rpt --top 6

# many corners at once; machine-readable out for a dashboard / fix tracker
python3 tools/pd/pt_report_parser.py reports/pt/*_setup.rpt reports/pt/*_hold.rpt \
    --json viol.json --csv viol.csv

# gate CI on timing
python3 tools/pd/pt_report_parser.py reports/pt/*.rpt --quiet --fail-on-violation
```

### Example (the shipped sample, a 250 MHz stress corner)

```
paths parsed: 6      violations: 5      clean: 1
worst setup : -0.600 ns   TNS -1.290 ns   implied fmax 217.4 MHz @ 4.00 ns period

Top 5 violating paths:
  -0.600 setup reg2reg depth 20 net  23%  u_div/quotient_reg[18] -> u_alu/result_reg[7]
        => Restructure / retime / pipeline (cut logic depth)
  -0.300 setup reg2reg depth  5 net  74%  u_div/quotient_reg[18] -> u_regfile/regs_reg[27][9]
        => Net / placement / routing fix (buffer, repair-transition, shorten wire)
  -0.180 setup reg2reg depth 10 net  30%  u_idex/a_reg[12] -> u_exmem/y_reg[12]
        => Gate upsize + VT swap (HVT->LVT on critical cells)
  -0.150 setup in2reg  depth  5 net  71%  imem_rdata[17] -> u_idex/op_reg[4]
        => I/O budget review (set_input_delay / set_output_delay)
  -0.060 setup reg2reg depth  8 net  32%  u_pc/pc_reg[5] -> u_if/pc_reg[5]
        => Useful skew / CTS adjustment

Prioritized fix strategy (violating paths, worst-TNS first):
    1  Restructure / retime / pipeline (cut logic depth)
    1  Net / placement / routing fix ...                 <- routing-quality lever (DeepDGR)
    1  Gate upsize + VT swap (HVT->LVT on critical cells)
    1  I/O budget review (set_input_delay / set_output_delay)
    1  Useful skew / CTS adjustment
```

The **net-dominated** bucket is flagged as a routing-quality lever: those paths
shrink when the global router produces shorter, less-congested nets — which is
exactly what the DeepDGR work targets (see `docs/PD_PORTFOLIO.md`). The parser is
the bridge between "my router got better" and "these specific endpoints closed."

### Where the reports come from

- **PrimeTime:** `tools/primetime/run_pt.tcl` (multi-corner `pt_shell` signoff).
- **OpenSTA / OpenROAD:** the same SDC + `report_timing -path_type
  full_clock_expanded` — identical layout, parses the same way.

---

## 2. `flow_metrics.py` — the PD scorecard

Scrapes the committed flow reports (`gds_flow/`) and prints the numbers a
reviewer asks for, labeling **measured** vs **derived**:

```sh
python3 tools/pd/flow_metrics.py            # auto-discovers gds_flow/ reports
python3 tools/pd/flow_metrics.py --json -   # machine-readable
```

On this repo's real sky130 run:

```
| Std cells         | 20789                  | measured |
| Cell area         | 0.201 mm2 (201453 um2) | measured |
| Sequential area   | 36.6 %                 | measured |
| Clock target      | 20.0 ns (50.0 MHz)     | config   |
| WNS / TNS         | 0.000 / 0.000 ns       | measured |
| Worst setup slack | +6.400 ns              | measured |
| Worst hold slack  | -0.140 ns              | measured |
| Timing            | VIOLATED (hold)        | measured |
| Achieved fmax     | 73.5 MHz               | derived: 1/(T-WNS) |
```

> Setup closes at 50 MHz with +6.40 ns slack ⇒ **73.5 MHz achievable**. A small
> −0.14 ns post-route hold violation remains — which the parser classifies as
> hold-buffer insertion (a P&R hold-fix step, not an fmax limiter).

---

## Tests

```sh
pytest tools/pd/tests -q
```

The sample `report_timing` files under `samples/` are **synthetic** fixtures
(generated by `samples/_gen_samples.py`) built to exercise every fix category
with self-consistent path arithmetic. `samples/clean_signoff.rpt` is a
positive-slack example that demonstrates the "TIMING MET / implied fmax" render
path. For the *live, measured* design numbers (area, WNS/TNS, fmax) run
`flow_metrics.py`, which scrapes the real `gds_flow/` reports.
