---
description: Run STA on the sky130-mapped netlist, group the worst paths, and propose RTL/constraint fixes (without weakening the SDC).
allowed-tools: Bash(make synth-sky130), Bash(make sta), Bash(make metrics), Read, Grep
---
Close setup timing on the pipeline:

1. Ensure a mapped netlist exists (`make synth-sky130` if needed), then `make sta`.
2. From the report, list the worst 3–5 violating paths grouped by endpoint/clock,
   each with its slack and the dominant cells/stage on the path.
3. For each group, propose a concrete fix and which file to touch — e.g. retime
   or pipeline a long combinational chain in `rtl/cpu_riscv/`, split a wide mux,
   or rebalance forwarding. Note the throughput/area cost of each.

Hard rule: never close timing by relaxing `flow/sta/*.sdc` (loosening the clock
or removing constraints). If the only path to positive slack is a constraint
change, say so explicitly and stop for review. Report the plan; implement only
the fixes I approve.
