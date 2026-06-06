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

**Q. Why Gray-code the FIFO pointers instead of binary?**
A binary counter can flip many bits at once (0111→1000). A multi-bit synchronizer samples
each bit independently, so it could latch a transient value that never existed, corrupting
the full/empty compare. Gray code changes exactly one bit per increment, so the
synchronized pointer is always the old or new count — the compare is always safe. I proved
the single-bit-transition invariant formally (yosys-smtbmc + z3).

**Q. Why two flops in the synchronizer, and what sets the count?**
The first flop can go metastable; the second gives it (almost) a full destination clock to
settle, and MTBF rises exponentially with that settling time. Two is the standard for
moderate clock ratios; very high-frequency or high-reliability crossings add a third.

**Q. How do full and empty stay correct across two clocks if the pointers are stale?**
Each side compares its own pointer against the *synchronized* opposite pointer, which lags
by up to ~2 cycles. That lag only ever makes `full`/`empty` pessimistic (assert slightly
early / deassert slightly late), never optimistic — so you can never overflow or underflow,
only briefly under-utilize. That's the safe direction.

**Q. What do you constrain in SDC for this block?**
`set_false_path` (or a max-delay bounded by one destination period) on the synchronizer
data inputs, so STA doesn't time the asynchronous launch→capture edge.

**Q. Your AXI4-Lite slave asserts READY the cycle after AW/W and BVALID the cycle after that — why not same-cycle?**
A same-cycle READY+BVALID slave is legal, but my 1×N router latches the routed slave on the
AW handshake and releases on B. If READY and B land in the same cycle, the lock can't engage
before it would need to release → it sticks busy and deadlocks the next transaction. The
1-cycle AW→B separation makes the lock clean. I actually hit this deadlock in sim and fixed
it by decoupling the handshake — good "I debug protocol timing" story.

**Q. How does the router avoid mis-routing a response when the master moves to the next address?**
Per-direction lock: on AW-accept it latches the decoded slave index and holds the route until
B completes (single outstanding write; same for read/R). A later AR/AW to a different slave is
held off (its READY is gated) until the in-flight transaction's response returns.

**Q. Why is AXI4-Lite enough here instead of full AXI4?**
The peripheral bus moves single 32-bit words — no bursts, no out-of-order, no multiple IDs.
AXI4-Lite is the exact subset for that, so it's spec-complete with a fraction of the
verification surface. Bursty masters (a cache refill) would want full AXI4.

**Q. Tell me about a bug you found in your arbiter.**
My round-robin arbiter first drove the grant *combinationally* from the request vector. Under
two-master contention, when the other master's `AWVALID` toggled mid-handshake the selected
index flipped, the slave saw a second `AWVALID`, and one address got **double-issued** — in sim
a DMA channel's `LEN` write committed twice and its `START` write was dropped, so that channel
silently never ran. I root-caused it from a config-write trace, then fixed it by **registering
the grant**: latch the round-robin winner when the channel is idle and hold it from lock until
the response handshake. One cycle of arbitration latency, zero glitching. Good lesson that
"works with one master" hides multi-master hazards.

**Q. Your DMA is a bus master and a bus slave — why, and how do you keep them straight?**
Slave port = the CPU programs SRC/DST/LEN/CTRL registers (per channel); master port = the
engine issues the actual read/write transactions to move data. They're separate AXI ports on
separate fabric attach points (config is xbar slave 4; the master goes through the arbiter).
The config-slave write path latches AW and W independently so it's robust to AW/W skew the
arbiter can introduce.

**Gaps to study (riscv-soc):** exact MTBF formula and how to back out settling time; gshare
aliasing vs the BTB+BHT I have; clock-gating insertion + how DC reports the dynamic-power
delta; wiring the CPU's load/store path onto AXI with proper stall/ready (the next increment).

_Expanding as CPU-on-bus lands._

## riscv-soc-dv (DV track)
_Seeded in Phase 2. Expect: UVM phasing, RAL frontdoor/backdoor, scoreboard vs predictor,
functional vs code coverage, SVA for AXI handshake, riscv-dv↔Spike trace compare._

## riscv-soc-dft (DFT track)

**Q. How does your fault simulator get a 64× speedup?**
Bit parallelism: each signal's value is a machine word holding 64 independent test patterns,
so one word-wide AND/OR/XOR evaluates a gate for 64 patterns at once (PPSFP). One fault-free
pass, then per fault I force the stuck line and re-simulate; a fault is detected if any PO
word differs from the good word.

**Q. How do you know it actually works and isn't just reporting 100%?**
I run it on a circuit with a *structurally redundant* fault (`g = a AND !a`, always 0). The
simulator reports 62.5% and flags the 3 untestable faults (g SA0 and both na faults, since the
output equals `a` regardless) — exactly the redundancy you'd expect. c17, which is fully
testable, comes back 100%.

**Q. Why is stuck-at not enough for modern parts?**
It misses timing-dependent defects — you also need transition (slow-to-rise/fall) and
path-delay faults, run at-speed. And bridging/cell-aware models for real silicon.

**Gaps to study (riscv-soc-dft):** scan compression internals (EDT/MISR), at-speed transition
ATPG launch-on-capture vs launch-on-shift, March algorithms beyond C− (coupling/neighborhood
faults), JTAG TAP 16-state controller, boundary-scan BSDL.

## riscv-soc-pd (PD track)
_Seeded in Phase 2. Expect: setup/hold closure, WNS/TNS, utilization vs congestion,
CTS skew, RC- vs logic-depth-dominated paths, why DeepDGR warm-starts global routing._

---
## Track-end quizzes (rule 4 — 3 Qs per phase)
_Logged here after each phase with your answers + any re-quiz._
