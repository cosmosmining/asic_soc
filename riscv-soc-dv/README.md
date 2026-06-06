# riscv-soc-dv — verification (DV track)

Real UVM evidence against the SoC blocks. **Closes the UVM résumé gap** (CV lists UVM with
no project behind it).

> **Process gate (your rule):** you write the verification plan first. I interview you on
> the DUT, then critique your plan — **before any test code**.

## Deliverables & status
- [ ] UVM TB for AXI4-Lite DMA + async FIFO: agent (driver/monitor/sequencer), scoreboard
      with reference model, RAL for DMA registers
- [ ] Constrained-random sequences, functional covergroups (≥95% functional, 100% code +
      documented waivers), SVA for AXI handshake + FIFO invariants (no overflow/underflow,
      Gray single-bit transitions)
- [ ] CPU level: riscv-dv streams + Spike ISS co-sim + trace compare; triage in `BUGS_FOUND.md`
- [ ] Formal: SymbiYosys proofs for FIFO ordering/depth and arbiter fairness
- [ ] Tooling: cocotb/Verilator fallback (CI) + VCS+Verdi Makefiles (CMU); regression with
      seed management + coverage merge

## Tiering (honesty)
Runnable here in CI: cocotb+Verilator, riscv-dv+Spike co-sim, SymbiYosys. `pending-CMU`:
full SystemVerilog UVM coverage on VCS+Verdi.

## Results
| Metric | Value | Provenance |
|--------|-------|-----------|
| Formal: arbiter grant mutual-exclusion + stability | **PROVEN** (BMC base + induction) | `CI` — yosys-smtbmc + z3 (`make dv`) |
| Formal: FIFO Gray-pointer invariants | **PROVEN** | `CI` — yosys-smtbmc + z3 (riscv-soc) |
| Real RTL bugs found + fixed | **2** (1 high, closed with a formal proof) | [`BUGS_FOUND.md`](BUGS_FOUND.md) |
| DMA copy + 2-ch concurrency | **PASS** | `CI` — `tb_dma` (riscv-soc) |
| Functional coverage (UVM ≥95%) | — | ⏳ pending-CMU |
| riscv-dv + Spike co-sim | — | ⬜ planned (open-source) |

See [`VERIFICATION_PLAN.md`](VERIFICATION_PLAN.md) for the full plan + tiering.
