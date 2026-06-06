# riscv-soc-dft — design-for-test (DFT track)

Hands-on DFT to pair with the ACTL/EDA research context — the portfolio differentiator.

## Deliverables & status
- [x] Standalone C++ **parallel-pattern** stuck-at fault simulator (`fault_sim/`), runs on
      ISCAS'85 `.bench`; validated on a fully-testable and a redundant circuit
- [ ] Scan insertion into the core. Two flows: DFT Compiler + TestMAX (CMU) and the
      open-source **Fault** toolchain (CI). ATPG: stuck-at + transition coverage, target ≥98% SA
- [ ] **MBIST**: synthesizable March C− controller for the SoC SRAMs + fault-injection TB
- [ ] IEEE **1149.1 JTAG TAP** as the access mechanism for scan + MBIST; boundary-scan demo
- [ ] README table: pattern counts, coverage %, estimated test time

## Tiering (honesty)
Runnable here: the **C++ fault simulator** (no EDA tools); MBIST/JTAG RTL sim (next).
`pending-CMU`: DFT Compiler / TestMAX scan+ATPG coverage on the core (the ≥98% target).

## Results
| Metric | Value | Provenance |
|--------|-------|-----------|
| Fault sim — c17 (ISCAS'85) | **100.00%** stuck-at (22/22 faults, 256 patterns) | `CI` — `fault_sim`, g++ |
| Fault sim — redundancy check | **62.50%** (correctly flags 3 untestable faults) | `CI` — validates the simulator |
| Core scan + ATPG stuck-at | — | ⏳ `pending-CMU` (target ≥98%) |
| Transition coverage | — | ⏳ `pending-CMU` |

Run: `make -C fault_sim run` (or `make dft` from repo root). The redundant-circuit case is
the important one — it proves the simulator distinguishes testable vs untestable faults rather
than always reporting 100%.

DESIGN_DECISIONS covers: chain count vs compression, shift power, X-handling (scan flow).
