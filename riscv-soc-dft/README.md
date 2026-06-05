# riscv-soc-dft — design-for-test (DFT track)

Hands-on DFT to pair with the ACTL/EDA research context — the portfolio differentiator.

## Deliverables & status
- [ ] Scan insertion into the core. Two flows: DFT Compiler + TestMAX (CMU) and the
      open-source **Fault** toolchain (CI). ATPG: stuck-at + transition coverage, target ≥98% SA
- [ ] **MBIST**: synthesizable March C− controller for the SoC SRAMs + fault-injection TB
      (stuck-at + coupling faults)
- [ ] IEEE **1149.1 JTAG TAP** as the access mechanism for scan + MBIST; boundary-scan demo
- [ ] Stretch: standalone C++ **PPSFP** stuck-at fault simulator, benchmarked on ISCAS'85,
      coverage cross-checked vs the ATPG tool
- [ ] README table: pattern counts, coverage %, estimated test time

## Tiering (honesty)
Runnable here: RTL (MBIST, JTAG TAP) sim; the C++ fault simulator; Fault toolchain ATPG.
`pending-CMU`: DFT Compiler / TestMAX coverage.

## Results
| Metric | Value | Provenance |
|--------|-------|-----------|
| Stuck-at coverage | — | ⏳ target ≥98% |
| Transition coverage | — | ⏳ |
| Pattern count / est. test time | — | ⬜ |

DESIGN_DECISIONS must cover: chain count vs compression, shift power, X-handling.
