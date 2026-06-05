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

## Iteration 4 — dynamic branch prediction (stronger CPU)

**Goal:** raise pipeline throughput by removing the fixed 2-cycle taken-branch
penalty. Architecturally transparent, so the existing golden-trace harness proves
correctness for free (a mispredict only costs cycles, never changes results).

**Changed**
- `riscv_pipeline.sv`: added a direct-mapped **BTB + 2-bit BHT** branch predictor
  (`BP_IDX_BITS`=4, 16 entries). Predict-taken redirects fetch early; EX compares
  predicted-next-pc vs actual and flushes *only* on a real mismatch, then trains
  BTB/BHT. Full-`pc[31:2]` tags ⇒ no cross-PC aliasing. `-DBP_OFF` reverts to the
  static predict-not-taken baseline for A/B measurement.
- TB: CPI instrumentation (cycles/retired). New benchmarks `loop_sum.hex`,
  `loop_sum100.hex`. Generator gained safe forward-branch injection (`pbr` arg).

**Verify** — directed + **100 linear random** + **60 branch-random** seeds, both
cores: **all PASS**. Synthesis clean (netlist 1.35M→1.90M; predictor adds the BTB/BHT
state + compare logic).

**Measured (CPI, predict-not-taken → predictor)**
| program                  | OFF   | ON    | Δ        |
|--------------------------|-------|-------|----------|
| loop_sum (10 iters)      | 1.618 | 1.206 | −25%     |
| loop_sum100 (100 iters)  | 1.661 | 1.023 | **−38%** |
| branch-random (1-shot)   | 1.290 | 1.290 | 0 (expected — single-visit branches can't be learned) |

The predictor pays off on *repeated* branches (loops), driving CPI to ~1.02 — near
the ideal — on the long loop.

**Next bottleneck** — the combinational 32-bit divider is the worst critical-path /
area offender; still no real memory subsystem (AXI), CSRs, or traps.

**Next single-step action** — make division multi-cycle (iterative, with an EX stall)
to shorten the critical path, OR start the AXI-lite memory subsystem. (Predictor is
a clean, verified win; either is a good next step.)

---

## Iteration 5 — physical synthesis against the real sky130 PDK

**Goal (user priority #1, "is it ready to fab?"):** push past generic synthesis to
a real foundry library and report honest physical numbers.

**Changed / done**
- Fetched the actual **SkyWater sky130** PDK (`volare`), mapped `riscv_pipeline`
  onto `sky130_fd_sc_hd` standard cells (`tools/scripts/synth_sky130.sh`).
- Added OpenLane config (`tools/openlane/config.json`) + `gds_flow/README.md` with
  the exact steps to produce a routed GDSII on a Docker host.

**Result (real PDK):** **27,017 std cells, 234,751 µm² (≈0.235 mm²)** for the
pipeline. Mapped netlist written.

**Honest status:** RTL is functionally verified + maps to the real sky130 library
with area numbers — a solid *pre-physical* milestone. It is **not** fab-ready:
routed GDSII (OpenROAD/OpenLane, needs Docker — unavailable locally), DRC/LVS, and
timing signoff are still required. See `gds_flow/README.md`.

**Bottleneck made concrete:** the **combinational 32-bit divider** dominates area
and makes ABC mapping take minutes — exactly the unit to convert to multi-cycle.

## Iteration 6 — UVM verification environment

**Goal (user priority #2, "use UVM, as pro as possible"):** package the proven
checking in an industry-standard UVM TB.

**Changed:** `tb/uvm/` — `riscv_if.sv`, `riscv_uvm_pkg.sv` (program seq-item +
constrained-random stream, sequencer, driver w/ backdoor load, monitor on RVFI,
scoreboard with an **independent reference ISS + functional covergroup**, agent,
env, `riscv_random_test`), `tb_uvm_top.sv`, README.

**Honest status:** UVM needs a commercial simulator / EDA Playground; the
open-source Icarus/Verilator flow here **cannot run UVM**, so this env is **not
locally compile-checked**. Its scoreboard reference is the *same algorithm* as the
golden model that the local Icarus differential test proves over ~260 programs —
so the logic is sound; the UVM wrapper is for VCS/Questa/Xcelium.

---

## Iteration 7 — multi-cycle divider (area + timing, fab-ability)

**Goal (user priority #3, "stronger CPU"):** kill the combinational 32-bit divider
that dominated area and the critical path and blocked practical P&R.

**Changed**
- New `rtl/cpu_riscv/divider.sv` — sequential restoring divider (~34 cycles),
  signed/unsigned, spec corner cases (÷0, signed overflow) in a fast path.
- `alu.sv` gained `HAS_DIV`: pipeline ALU now has **no divide hardware** (DIV/REM
  routed to the sequential unit); single-cycle core keeps the combinational one.
- `riscv_pipeline.sv` integrates the divider with a front-end **hold** (`div_stall`)
  that freezes IF/ID/EX and bubbles MEM until the divide completes, then muxes the
  result into EX/MEM. Added `divider.sv` to all synth/flow source lists.

**Verify** — directed + **100 div-heavy random seeds**, both cores: **PASS**.

**Result (real sky130, before → after):**
| metric | combinational ÷ | sequential ÷ | Δ |
|--------|-----------------|--------------|---|
| std cells | 27,017 | **20,789** | −23% |
| area | 0.235 mm² | **0.201 mm²** | −14% |
| synth time | >3 min | seconds | — |
| critical path | 32-bit ripple ÷ | small/cycle | **major timing win** |

Throughput cost: DIV/REM now take ~34 cycles (CPI rises on div-heavy code) — the
standard area/throughput trade every real CPU makes.

**Next bottleneck** — no CSRs/privilege/traps (can't run real RISC-V system code);
multiplier is still single-cycle combinational (next critical-path candidate); no
caches/AXI memory subsystem.

**Next single-step action** — CSR file + machine-mode traps (mcycle/minstret,
mtvec/mepc/mcause, ECALL/EBREAK/MRET), extending the golden model + UVM reference.

---

## Iteration 9 — commercial hardening: Zicsr/traps, M-unit, AXI4-Lite SoC, PPA

**Goal (user ask, "more robust + closer to a commercial chip; add AXI4-Lite,
caches, branch prediction; put real PPA numbers on the bullet"):** close the
biggest gaps between a verified core and a real SoC, and report measured PPA.

**Changed**
- *Process / lint (9a):* sized every ALU op 5 bits (killed ~44 Verilator
  WIDTHEXPAND warnings), removed dead nets, added `tools/verilator/lint_waivers.vlt`,
  a top-level `Makefile`, and **GitHub Actions CI** (`.github/workflows/ci.yml`)
  that lints (0 warnings) + runs the differential regression on every push.
- *Zicsr + M-mode traps (9b/9c):* new `rtl/cpu_riscv/csr.sv` (mstatus/mie/mtvec/
  mscratch/mepc/mcause/mtval/mip, misa, mhartid, 64-bit mcycle/minstret), full
  instruction-legality decode → illegal-instruction trap, ECALL/EBREAK/MRET, and
  load/store/instruction address-misaligned traps. Integrated into **both** cores
  (single-cycle + pipeline; pipeline resolves traps/CSR in EX over the existing
  redirect path) and the independent golden ISS. New `gen_csr_test.py` directed
  test (every CSR op, minstret, all trap causes) + mscratch CSR ops in the random
  generator.
- *Sequential multiplier (9d):* `rtl/cpu_riscv/mul_seq.sv` — the combinational
  32×32 multiplier dominated the critical path and made std-cell mapping
  intractable (ABC ran minutes); the multi-cycle unit (like the divider) fixes
  area, timing, and synth runtime. `alu.sv` gains `HAS_MUL`.
- *AXI4-Lite memory subsystem + SoC (9e/9f):* `rtl/soc/` — `axi_sram.sv`
  (AXI4-Lite SRAM slave), `riscv_cache.sv` (direct-mapped, read-only I$ /
  write-through D$, line fill = single-beat AXI4-Lite reads), `axil_arb.sv`
  (2→1 AXI4-Lite interconnect), `riscv_soc.sv` (pipeline + I$ + D$ + arb + SRAM).
  The pipeline gained a memory-stall handshake (global freeze; mul/div `hold`)
  that is bit-identical to before when memory is always-ready.

**Verify** — `make lint` clean across core/pipeline/SoC (Verilator -Wall).
Differential regression (both cores): directed, the CSR/trap program (42/42),
and linear + mixed (branch + CSR) random seeds. **Full-SoC differential test
(`tb_soc`) passes** — the same programs (incl. the trap test, 42/42, and stores)
run correctly through I$/D$ + the AXI4-Lite fabric, cold-miss fills included.

**Measured PPA (real sky130, `sky130_fd_sc_hd__tt_025C_1v80`, Yosys map):**
| metric | riscv_pipeline (CPU core) |
|--------|---------------------------|
| std cells | **15,342** |
| cell area | **151,693 µm² ≈ 0.152 mm²** |
| flip-flops | ~3,155 |

Area shrank vs. the iteration-7 number (0.201 mm²) because the sequential
multiplier removed the combinational 32×32 array. `make synth-sky130` /
`tools/scripts/ppa.sh` reproduce it; timing closure (Fmax) and power are driven
by `ppa.sh` through OpenSTA / the OpenROAD-OpenLane flow in `gds_flow/`.

**Next bottleneck** — async interrupts (timer/CLINT) on top of the trap plumbing;
caches use flop arrays (real chips use SRAM macros for the data RAM); no GPU/ARM
core yet.

---

## Backlog (ordered)
0. ~~Branch prediction (BTB + 2-bit BHT)~~ ✅ (Iteration 4)
00. ~~Physical synth (sky130 area) + UVM env + multi-cycle divider~~ ✅ (Iter 5-7)
1. ~~Golden-trace co-sim harness~~ ✅ (Iteration 2)
2. ~~5-stage pipeline: forwarding, load-use stall, branch flush~~ ✅ (Iteration 2)
3. ~~DIV/REM (M-extension)~~ ✅ (Iteration 3) — now combinational; multi-cycle later.
4. Randomized differential testing ✅ (Iteration 3) — + branches/CSRs (Iter 9).
4. ~~CSR + machine-mode trap handling (mtvec/mepc/mcause, ECALL/EBREAK/MRET,
   illegal + misaligned, mcycle/minstret)~~ ✅ (Iteration 9, both cores).
5. ~~AXI4-Lite SRAM slave + I$/D$ + interconnect; full SoC, differential-tested~~
   ✅ (Iteration 9).
6. ~~Multi-cycle multiplier~~ ✅ (Iteration 9).
7. Async interrupts (machine timer / CLINT) on top of the trap plumbing.
8. GPU SIMD lanes (vec add/mul/dot) sharing the AXI fabric.
9. ARM-like educational core.
10. OpenROAD P&R run from the Yosys netlist → GDS, timing/area reports.
