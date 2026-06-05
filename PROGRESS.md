# PROGRESS — autonomous ASIC agent log

Each entry is one loop iteration: PLAN → IMPLEMENT → VERIFY → SYNTHESIZE → ANALYZE → FIX.

## Iteration 1 — RV32IM single-cycle core (bring-up)

**Goal:** stand up the repo and a correct, synthesizable, *runnable* RV32IM core
as the foundation for the 5-stage pipeline.

**Changed**
- Repo skeleton (`rtl/ tb/ formal/ tools/ gds_flow/`) + architecture diagram in `README.md`.
- `rtl/common/riscv_defs.svh` — opcode / ALU-op encodings.
- `rtl/cpu_riscv/regfile.sv` — 2R/1W register file, x0=0, write-first bypass.
- `rtl/cpu_riscv/alu.sv` — RV32IM ALU incl. MUL/MULH/MULHSU/MULHU.
- `rtl/cpu_riscv/riscv_core.sv` — single-cycle RV32IM datapath + control
  (OP, OP-IMM, LOAD/STORE w/ byte-enables, BRANCH, JAL/JALR, LUI, AUIPC, M-mul).
- `tb/directed/tb_riscv_core.sv` — directed smoke test (10 checks).
- `tools/scripts/run_sim.sh`, `tools/yosys/synth_riscv.ys`,
  `tools/openroad/riscv_core.sdc`, `formal/assertions/riscv_core_sva.sv`.

**Verify** — `run_sim.sh tb_riscv_core`: **PASS (10/10)**. Covers ADD/SUB/ADDI,
SLT/logic, a SW→LW round-trip, a taken BEQ (skips a poisoned instr), and MUL (5×37=185).

**Synthesize** — `yosys synth_riscv.ys`: clean, `check -assert` ok, netlist written.
~1023 DFFs (992 = 31×32 regfile, 32 = PC). No unsynthesizable constructs.

**What broke / fixed** — first run: all registers read 0. Root cause = **RTL bug**:
decoded fields were declared `logic x = inst[...];`, which in SV is a one-time
*initializer*, not a continuous assign — fields froze at time-0 X. Fixed by moving
to explicit `assign` (same in `alu.sv` for the signed operands). Re-ran → PASS.

**Next bottleneck** — single-cycle core has no pipeline; can't hit timing/throughput
targets and doesn't exercise hazards/forwarding (a stated requirement).

**Next single-step action** — add a self-checking instruction-by-instruction trace
comparator (golden model) so the pipeline refactor in Iteration 2 is regression-safe,
*then* split into IF/ID/EX/MEM/WB with a hazard/forwarding unit.

---

## Iteration 2 — golden-trace harness + 5-stage pipeline

**Goal:** make the design regression-safe, then add the pipeline with hazard handling.

**Changed**
- RVFI-lite retire interface added to `riscv_core` (registered commit record).
- `tb/directed/riscv_golden.sv` — independent behavioral RV32IM ISS that emits the
  expected retire trace (a *separate* implementation, for differential testing).
- `tb/directed/tb_riscv_trace.sv` — order-based retire comparator; one TB validates
  both cores (`-DPIPELINE` switch). `tb/directed/programs/test_core.hex` exercises
  EX-forwarding chains, a load-use hazard, and branch taken/not-taken.
- `rtl/cpu_riscv/riscv_pipeline.sv` — **5-stage IF/ID/EX/MEM/WB pipeline**: full EX
  forwarding (EX/MEM + MEM/WB), load-use stall+bubble, branch/jump resolved in EX
  with 2-cycle flush, regfile write-first bypass. Same ports as `riscv_core`.
- `tools/yosys/synth_pipeline.ys`; runner now auto-includes TB helper modules and
  forwards defines (`-DPIPELINE`).

**Verify** — golden-trace differential test:
- single-cycle: **PASS 14/14**, pipeline: **PASS 14/14** (same golden model).

**Synthesize** — `synth_pipeline.ys`: clean, `check -assert` ok, netlist written
(~23k generic cells incl. expanded multiplier).

**What broke / fixed**
1. *TB bug:* hand-encoded `addi x6` as rd=x5 (clobbered a result). Golden+DUT agreed
   (same hex) so the trace stayed green — caught only by the architectural mem check.
   Fixed the hex word.
2. *RTL/synth bug:* ID/EX bubble used `if(!rst_n || ex_bubble)`, ORing a synchronous
   clear with the async reset → Yosys "Multiple edge sensitive events". Split into
   async-reset branch + synchronous-bubble branch. Re-verified + synthesized clean.

**Next bottleneck** — M-extension is incomplete (DIV/REM are ADD placeholders); the
verification is directed-only (no randomized differential stress).

**Next single-step action** — add DIV/REM to the ALU + golden model, then a randomized
instruction-stream differential test (constrained-random) reusing the golden ISS.

---

## Iteration 3 — complete RV32IM + randomized differential testing

**Goal:** finish the M-extension (DIV/REM) and add constrained-random differential
stress to flush out hazard/datapath bugs the directed tests can't reach.

**Changed**
- ALU: added DIV/DIVU/REM/REMU with full RISC-V corner cases (÷0, signed overflow);
  widened ALU op to 5 bits. Decoded M-ext funct3 4..7 in both cores + golden ISS.
- `tools/scripts/gen_rand_prog.py` — random linear RV32IM program generator.
- `tools/scripts/regress.sh` — builds both cores once, runs directed + N random
  seeds against BOTH, via a `+PROG=` plusarg override (added to TB + golden).

**Verify** — directed 17/17 both cores; **REGRESSION PASS: 100 random seeds × 80
instr on both single-cycle and pipeline.** Synthesis clean (divider maps).

**What broke / fixed** — the random tests exposed bugs, all in the *test infra /
reference model* (the RTL was correct each time — which is the point of an
independent golden):
1. *RTL+semantic:* shared regfile `write-first` bypass formed a combinational loop
   in the single-cycle core (`rs1→ALU→rd_data→rs1`) whenever `rd==rs1`, and was also
   wrong per spec there. Made it a `WRITE_FIRST` parameter: off for single-cycle,
   on for the pipeline (where `rd_data` is registered). Real fix, real bug.
2. *Harness:* `mem[0x100]` spot-check was directed-only; gated it behind `default_prog`.
3. *Golden model (x3):* iverilog signedness traps — `$signed()` casts and, crucially,
   mixed-sign `?:` ternaries silently demote `>>>` to a logical shift and signed `/`
   to unsigned. Rewrote SRA/SRAI/DIV/REM as if/else with signed-declared operands.

**Next bottleneck** — combinational 32-bit divider is large/slow (hurts timing/area);
the CPU still has no memory subsystem beyond the TB BRAM, no CSRs, no AXI fabric.

**Next single-step action** — bind SVA into the pipeline + add a cycle/CPI counter,
then start the system side: an AXI-lite SRAM slave + a thin core→AXI adapter.

---

## Backlog (ordered)
1. ~~Golden-trace co-sim harness~~ ✅ (Iteration 2)
2. ~~5-stage pipeline: forwarding, load-use stall, branch flush~~ ✅ (Iteration 2)
3. ~~DIV/REM (M-extension)~~ ✅ (Iteration 3) — now combinational; multi-cycle later.
4. Randomized differential testing ✅ (Iteration 3) — extend with loads/stores+branches.
4. CSR + minimal trap handling (mtvec/mepc/mcause) for compliance subset.
5. AXI-lite memory slave + interconnect; swap TB BRAM for it via adapter.
6. GPU SIMD lanes (vec add/mul/dot) sharing the AXI fabric.
7. ARM-like educational core.
8. OpenROAD P&R run from the Yosys netlist → GDS, timing/area reports.
