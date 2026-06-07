---
description: Run the full local gate (lint, regression, SoC cocotb, formal) and report a pass/fail table with the first failure root-caused.
allowed-tools: Bash(make lint), Bash(make regress:*), Bash(make sim-soc), Bash(make formal), Bash(make metrics)
---
Run the complete open-source verification gate and report results, in this order:

1. `make lint`        — Verilator, 0 warnings.
2. `make regress`     — differential regression on both cores.
3. `make sim-soc`     — cocotb SoC test (UART + machine-timer interrupts).
4. `make formal`      — ALU equivalence + pipeline safety BMC.
5. `make metrics`     — refresh `reports/summary.json`.

Then print a compact table: stage | PASS/FAIL | key number (warnings / seeds / tests / proof status / cells). If anything fails, stop at the first failure, show the relevant log excerpt, and give your best root-cause hypothesis. Do NOT change any files unless I ask — this command only reports.
