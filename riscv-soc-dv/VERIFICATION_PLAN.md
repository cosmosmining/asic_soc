# VERIFICATION_PLAN — riscv-soc-dv (starter scaffold)

> **Process gate (your rule):** you own the authoritative verification plan. This is a
> scaffold to react to / critique, plus the evidence already produced. Before UVM code we
> do the DUT interview + plan critique.

## DUTs under test
| DUT | What it is | Key risk |
|-----|-----------|----------|
| `axil_arbiter` | round-robin AXI4-Lite arbiter (M masters) | grant glitch / contention (see BUG-001) |
| `dma_engine` | 2-channel DMA (slave config + master data) | AW/W skew, descriptor errors, round-robin fairness |
| `async_fifo` | dual-clock CDC FIFO | overflow/underflow, pointer CDC, data ordering |

## Checks
| Check | Type | Status |
|-------|------|--------|
| Arbiter: ≤1 master granted per channel | formal (smtbmc) | ✅ PROVEN |
| Arbiter: grant stable per transaction | formal (smtbmc) | ✅ PROVEN |
| FIFO: Gray pointer encoding + 1-bit transition | formal (smtbmc) | ✅ PROVEN (riscv-soc) |
| FIFO: no overflow/underflow, depth bound | formal (multiclock) | ⬜ SymbiYosys (planned) |
| AXI handshake: VALID stable until READY | SVA | ⬜ planned |
| DMA: copy correctness, 2-ch concurrency | directed sim | ✅ PASS (`tb_dma`) |
| DMA registers (RAL frontdoor/backdoor) | UVM | ⏳ pending-CMU (VCS) |
| Constrained-random streams + covergroups (≥95%) | UVM | ⏳ pending-CMU |
| CPU: riscv-dv streams vs Spike co-sim | sim | ⬜ planned (open-source) |

## Coverage goals
Functional ≥95%, code 100% with a documented waiver list (UVM tier, VCS+Verdi).

## Tooling tiers (honesty)
- **Reproduced here (CI):** formal proofs (yosys-smtbmc + z3) for arbiter + FIFO.
- **Open-source planned:** cocotb/Verilator tests, riscv-dv + Spike co-sim.
- **`pending-CMU`:** full SystemVerilog UVM (agent/RAL/scoreboard/covergroups) on VCS+Verdi.

## Bugs found
See [`BUGS_FOUND.md`](BUGS_FOUND.md) — 2 real RTL bugs (1 high closed with a formal proof).
