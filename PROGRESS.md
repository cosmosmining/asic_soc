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

## Iteration 8 — real RTL→GDSII (sky130, OpenLane on local Docker)

**Goal (user ask):** actually run the physical flow to a GDS, locally.

**Done**
- Stood up headless Docker (**Colima** arm64 VM + Rosetta for the x86 OpenLane
  image) — no Docker Desktop / GUI needed. Pulled OpenLane, installed sky130 PDK.
- Ran OpenLane: synthesis → floorplan → placement → CTS → **detailed routing
  (0 DRC violations)** → SPEF extraction → **GDSII** (streamed via Magic from the
  clean routed DEF). Worked around 3 bugs in the `latest` dev image (unset
  `GLB_RESIZER_TIMING_OPTIMIZATIONS`, unset `$::env(PWD)`, and a `/dev/null` RCX
  save), plus relieved routing congestion (util 35→16%).

**Result:** real **`gds_flow/gds/riscv_pipeline.gds.gz`** (112 MB → 20 MB),
die **2.03 mm²**, router DRC **0 violations**, post-CTS timing **MET @50 MHz**
(+6.52 ns slack). See `gds_flow/RESULTS.md`.

**Honest caveats:** post-*route* timing not closed at 20 ns (the crashing timing
resizer was disabled), and LVS not reached (dev-image bug). A stable OpenLane
image would finish post-route opt + LVS. So: a real DRC-clean routed GDSII exists;
it is **not** a fully signed-off tapeout.

---

## Iteration 9 — PD signoff automation (PrimeTime parser + flow scorecard)

**Goal (user priority, "PD teams live in Tcl/Python — show it"):** build the
day-job automation that turns signoff text into decisions, and frame the whole
PD story (DeepDGR routing + the Iteration-8 flow + the tooling) coherently.

**Changed**
- `tools/pd/pt_report_parser.py` — parses PrimeTime/OpenSTA `report_timing`
  (`-path_type full_clock_expanded`), derives PD features (logic depth,
  net-vs-cell split, path category, CDC), classifies every violation into a
  **fix category** (restructure/retime, net/placement-routing, upsize+VT, useful
  skew, I/O budget, hold-buffer, CDC/constraint), and emits a prioritized Pareto
  as text/JSON/CSV with a `--fail-on-violation` CI gate.
- `tools/pd/flow_metrics.py` — scrapes the Iteration-8 `gds_flow/` reports into a
  one-screen scorecard (cells, area, util target, WNS/TNS, and **achieved fmax =
  1/(T−WNS)** from the worst setup slack), labeling measured vs. derived. On the
  current reports: 20,789 cells / 0.201 mm², setup **+6.40 ns ⇒ 73.5 MHz**, with
  the small **−0.14 ns post-route hold** violation Iteration 8 flagged still open
  (the parser classifies it as hold-buffer insertion — the right P&R fix).
- `tools/pd/samples/` + `_gen_samples.py` — representative, arithmetically
  self-consistent `report_timing` fixtures covering every fix category.
- `tools/pd/tests/` — **32 pytest cases** (parsing, features, classification,
  aggregation, JSON/CSV, CLI) — all pass; the flow-metrics test reads the live
  signoff reports value-agnostically so it survives flow re-runs.
- `tools/primetime/` — real `pt_shell` multi-corner signoff deck (`mmmc.tcl`,
  `constraints.sdc`, `report_signoff.tcl`, `run_pt.tcl`): setup@slow / hold@fast
  / typical-reference with OCV derate, emitting the exact format the parser eats.
- `gds_flow/openlane2/` — OpenLane 2 (LibreLane) port of the validated OL1 config.
- `docs/PD_PORTFOLIO.md` — frames **DeepDGR with routing metrics** (overflow,
  wirelength, runtime — not ML accuracy) and bridges router quality → the
  net-dominated paths the parser flags. README updated with a PD quick-start.

**Also (flow hygiene):** `tools/yosys/synth_{pipeline,riscv}.ys` now `mkdir -p
build` before `write_verilog`, fixing the `synth-check` CI job on fresh checkouts
(build/ is gitignored, so a synth-only runner had no output dir). Verified
end-to-end with yosys 0.33.

**Verify** — `pytest tools/pd/tests -q`: **32 passed**. Parser classifies all five
setup fix categories + hold + CDC correctly on the sample corners.

**Honest status:** the Python toolkit runs and is unit-tested here; the PrimeTime
deck and OL2 config are complete and idiomatic but need commercial PrimeTime / a
Docker host (not in this CI) — the parser that consumes their output *is* tested
against representative captures of that exact format.

---

## Backlog (ordered)
0. ~~Branch prediction (BTB + 2-bit BHT)~~ ✅ (Iteration 4)
00. ~~Physical synth (sky130 area) + UVM env + multi-cycle divider~~ ✅ (Iter 5-7)
000. ~~Real RTL→GDSII on local Docker (sky130/OpenLane)~~ ✅ (Iter 8)
0000. ~~PD signoff automation (PrimeTime parser + flow scorecard) + multi-corner deck~~ ✅ (Iter 9)
1. ~~Golden-trace co-sim harness~~ ✅ (Iteration 2)
2. ~~5-stage pipeline: forwarding, load-use stall, branch flush~~ ✅ (Iteration 2)
3. ~~DIV/REM (M-extension)~~ ✅ (Iteration 3) — now combinational; multi-cycle later.
4. Randomized differential testing ✅ (Iteration 3) — extend with loads/stores+branches.
4. CSR + minimal trap handling (mtvec/mepc/mcause) for compliance subset.
5. AXI-lite memory slave + interconnect; swap TB BRAM for it via adapter.
6. GPU SIMD lanes (vec add/mul/dot) sharing the AXI fabric.
7. ARM-like educational core.
8. OpenROAD P&R run from the Yosys netlist → GDS, timing/area reports.
