# INTERVIEW_PREP — questions, model answers, and gaps to study

The 15–20 questions an interviewer would ask about each track, with model answers and an
honest **"gaps to study"** list. Filled in as each track is built. Use the gaps lists as
your study queue before a loop.

> How to use: read the Q, answer out loud *before* reading the model answer, then mark any
> gap you couldn't cover. Track-end quizzes (3 questions) are logged at the bottom.

---
## Core / RISC-V µarch (foundation — answerable today)

**Q1. Why is your differential test trustworthy if the golden model could share the bug?**
The golden ISS is an *independent* behavioral implementation (separate author intent,
separate control structure) run on every retire via an order-based comparator; a shared
bug would have to manifest identically in two unrelated implementations across 100s of
constrained-random programs. History (PROGRESS Iter-3) shows the random tests caught
real bugs — and they were in the *reference model*, not the RTL, which is exactly the
signal you want from an independent checker.

**Q2. Walk the hazards your 5-stage pipeline handles and how.**
EX/MEM and MEM/WB forwarding for ALU producers; load-use is the one unavoidable stall
(1 bubble) because the loaded value isn't ready until MEM; control hazards resolve in EX
with a flush. The BTB+2-bit BHT predicts taken branches to cut the steady-state penalty —
measured CPI on a 100-iteration loop fell 1.66→1.02 with the predictor on.

**Q3. Why did `logic x = inst[...];` freeze your decode at X?**
In SystemVerilog a variable declaration initializer is a *one-time* assignment at time 0,
not a continuous assign — so the decoded fields never updated. Fix: explicit `assign`.
(Real bug from Iter-1; good "I read LRM semantics" story.)

**Q4. Your Verilator lint shows 51 warnings — defend that.**
All WIDTHEXPAND (case-item constants narrower than the 5-bit ALU op) and a few
UNUSEDSIGNAL — zero true errors. They're cosmetic width mismatches; the fix is to width
the case selector/items consistently. Driving the core to lint-clean is a tracked Phase-1
task; I'd never claim "lint-clean" before it's true.

**Gaps to study (core):** precise CPI math for mispredict penalty; formal vs simulation
coverage argument; why write-first regfile bypass formed a comb loop in the single-cycle
core but not the pipeline.

---
## riscv-soc (RTL track)
_Seeded as blocks land. Expect: AXI4-Lite handshake rules, why Gray-code pointers for the
async FIFO, 2-flop synchronizer MTBF intuition, round-robin fairness, DMA descriptor flow,
clock-gating power mechanism._

## riscv-soc-dv (DV track)
_Seeded in Phase 2. Expect: UVM phasing, RAL frontdoor/backdoor, scoreboard vs predictor,
functional vs code coverage, SVA for AXI handshake, riscv-dv↔Spike trace compare._

## riscv-soc-dft (DFT track)
_Seeded in Phase 2. Expect: stuck-at vs transition faults, scan compression tradeoffs,
shift power, X-handling/masking, March C− fault coverage, JTAG TAP state machine._

## riscv-soc-pd (PD track)
_Seeded in Phase 2. Expect: setup/hold closure, WNS/TNS, utilization vs congestion,
CTS skew, RC- vs logic-depth-dominated paths, why DeepDGR warm-starts global routing._

---
## Track-end quizzes (rule 4 — 3 Qs per phase)
_Logged here after each phase with your answers + any re-quiz._
