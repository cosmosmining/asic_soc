# timing-cli — STA timing-violation classifier

Parses OpenSTA / PrimeTime `report_timing` text and classifies each violating path by its
**dominant cause** — logic depth, RC/interconnect, or clock skew — with a concrete fix
suggestion. Doubles as a PD-automation résumé bullet.

## Install & run
```sh
pip install -e .
timing-report samples/rc_dominated.rpt
```
```
endpoint                           slack  depth  net%   skew  cause
--------------------------------------------------------------------------------------------
u_mem/wr_reg                       -0.60      5   69%   0.01  RC/interconnect-dominated
                                        -> buffer/upsize long nets; improve placement to shorten wirelength
```

## How it classifies (heuristics, tunable)
- **RC/interconnect-dominated** — net delay > 45% of the path → buffer/upsize, fix placement.
- **logic-depth-dominated** — > 12 cell arcs between flops → pipeline / restructure.
- **clock-skew-dominated** — |capture − launch clock-network delay| > 0.30 → rebalance CTS.
- else **marginal/mixed**.

## Test
```sh
python tests/test_classify.py     # 3 sample reports, one per cause -> RESULT: PASS
```
The samples are synthetic but in real OpenSTA/PrimeTime `report_timing` format, so the same
CLI runs on reports from the PD track's OpenLane/OpenROAD runs (and PrimeTime at CMU).
