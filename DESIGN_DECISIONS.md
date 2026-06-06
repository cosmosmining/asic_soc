# DESIGN_DECISIONS — portfolio decision log

Every non-trivial choice, the alternatives considered, and why. Format per entry:
**Decision · Options · Choice · Why · Revisit-if.** Block-level timing/CDC notes for
each RTL block live in the per-track sections further down (a rule for this repo:
every block gets a timing/CDC note here).

---
## Phase 0 — foundation & honesty baseline

### D0.1 Repo structure
- **Options:** (A) monorepo, 4 top-level dirs; (B) monorepo now, split to standalone
  repos later; (C) 4 separate GitHub repos now.
- **Choice:** A — monorepo, four dirs (`riscv-soc/`, `-dv/`, `-dft/`, `-pd/`).
- **Why:** the four tracks share one core DUT; a monorepo references it once (no
  duplication), gives one CI, and matches the session's single-repo scope. B kept open
  for Phase 3 if profile optics want standalone repos.
- **Revisit-if:** profile needs independent repo badges → mirror dirs out (option B).

### D0.2 Sequencing
- **Options:** (A) foundation-first then depth-first per track; (B) thin vertical slice
  across all four; (C) one discipline to interview-ready first.
- **Choice:** A — `riscv-soc` (the DUT) to interview-grade first, then dv → dft → pd.
- **Why:** dv/dft/pd all consume the SoC; building it first removes rework. 

### D0.3 Commercial-tool numbers (honesty)
- **Options:** (A) placeholder rows you fill from real CMU reports; (B) open-source-only
  in README; (C) labeled open-source proxy (e.g. OpenSTA for PrimeTime).
- **Choice:** A — tables show real CI numbers now; commercial rows are present but
  marked `pending-CMU`, filled only from real reports.
- **Why:** satisfies "never fabricate" while keeping the full table shape visible so the
  résumé story is legible. Proxies (C) risk being mistaken for the real tool in interview.

### D0.4 Base core
- **Options:** (A) reuse the existing verified RV32IM core + trim the overstated README;
  (B) wait for a different core path; (C) write a fresh core.
- **Choice:** A — reuse `rtl/cpu_riscv` (already verified, synthesized, taken to a routed
  sky130 GDS) as the shared DUT; README rewritten to "built vs roadmap".
- **Why:** preserves real, hard-won verified work; fastest path to interview-grade; the
  RV32I**M** core is a superset of the RV32I the brief named.

### D0.5 Toolchain pinning
- **Options:** (A) Docker-pinned images for heavy EDA + apt-pinned Verilator/Icarus;
  (B) all-apt; (C) Nix flake (fully hermetic).
- **Choice:** A. Verilator **5.020** + Icarus **12.0** installed via apt and recorded in
  `tools/versions.env`; Yosys/OpenROAD/OpenLane/sky130 pinned via Docker images when the
  synth/PD phases introduce them.
- **Why:** apt versions are reproducible enough for sim/lint and zero-friction in CI;
  Docker pins the version-sensitive PD tools. Nix (C) is more hermetic but higher upkeep.
- **Revisit-if:** CI runner image drift changes a tool version → move that tool to Docker.

### D0.6 CI gating policy
- **Options:** (A) Icarus smoke+regression blocking, Verilator lint advisory until the
  core is cleaned; (B) lint blocking immediately; (C) lint with a baselined warning count.
- **Choice:** A for Phase 0.
- **Why:** the core has 51 pre-existing lint warnings (0 errors); making lint blocking now
  would red-bar CI on legacy code. The blocking gate is the **reproducible passing**
  smoke+regression; lint flips to blocking in Phase 1 once the core + new SoC RTL are clean.

### Honest baseline measured this environment (Phase 0)
- Directed smoke: **PASS 10/10** (iverilog 12.0).
- Differential regression: directed + **20 random seeds × 2 cores, 0 mismatches**.
- Verilator `--lint-only` core: **51 warnings (44 WIDTHEXPAND, 7 UNUSEDSIGNAL), 0 errors**.
- Not reproduced here yet (no yosys/openroad installed): synthesis area, GDSII — carried
  as `prior` from PROGRESS.md until the synth/PD tracks re-run them.

---
## riscv-soc (RTL track) — decisions & block CDC/timing notes
_Phase 1. Each block gets its timing/CDC note here as it lands._

_Open decisions for the bus: AXI4-Lite fabric topology (shared-bus + decoder vs
crossbar); gshare vs the existing BTB+BHT predictor for the stretch item._

### D-SOC.1 Async FIFO (CDC showcase block)
- **Design:** Cummings-style dual-clock FIFO. Pointers are AW+1 bits (extra MSB
  separates full from empty); each pointer crosses domains as **Gray code** through a
  2-flop synchronizer (`sync_2ff`).
- **Options for pointer crossing:** (A) Gray pointers + 2-FF sync; (B) handshake/req-ack
  FIFO; (C) async clear + mux-recirculation. Chose A — the standard, lowest-latency,
  formally-tractable approach for a pure rate-decoupling FIFO.
- **CDC note:** the *only* signals crossing clock domains are `wgray` and `rgray`. Gray
  coding guarantees a single-bit change per increment, so a 2-FF synchronizer resolves to
  the old or new value — never an illegal intermediate. Binary pointers, memory, and
  data never cross. The `wfull`/`rempty` compares use the synchronized opposite pointer,
  so they can be pessimistic by a couple of cycles (never optimistic) → no overflow/underflow.
- **Timing/SDC note:** apply `set_false_path` (or a max-delay ≤ 1 destination period) on the
  `sync_2ff.d` inputs; STA must not try to time the asynchronous launch→capture path.
- **Verification:** dual-clock self-checking sim (256 words, 0 errors); **Gray-pointer
  invariants P1/P2 formally proven** (yosys-smtbmc + z3, BMC base + unbounded induction,
  `formal/run_gray_proof.sh` / `gray_inc.sby`). Multiclock FIFO-level ordering/depth proofs
  are the dv-track extension.

### D-SOC.2 AXI4-Lite bus topology
- **Options:** (A) shared-bus + address decoder, single outstanding; (B) full NxM
  crossbar with per-slave queues; (C) pipelined/AXI4 with bursts + IDs.
- **Choice:** A — a 1xN decoder/router (`axil_xbar`) with a per-direction lock
  (one outstanding read + one outstanding write).
- **Why:** AXI4-Lite has no bursts/IDs, so a single-outstanding router is spec-complete and
  far easier to verify and synthesize; the multi-master story is handled by a round-robin
  arbiter *in front of* the router (next increment) rather than a full crossbar. B/C are
  overkill for this peripheral bus and add verification surface for no interview value here.
- **Slave handshake note:** all slaves use the canonical decoupled handshake — AW+W accepted
  with a 1-cycle READY pulse, **B asserted the following cycle**. That 1-cycle AW→B
  separation is what lets the router's lock latch the routed slave on address-accept and
  release on the response, so a back-to-back transaction to a different slave can't mis-route
  an in-flight B/R. (A same-cycle READY+B slave deadlocks the lock — found and fixed in sim.)
- **Peripherals:** `axil_sram` (RAM or READONLY ROM w/ `$readmemh` init, byte strobes,
  SLVERR on ROM write); `axil_uart` (8N1 TX serializer, status reg); `axil_timer`
  (free-running MTIME + MTIMECMP compare IRQ). All Verilator-lint-clean.

### D-SOC.3 Multi-master arbitration + DMA
- **Topology:** masters {CPU/external, DMA} → `axil_arbiter` (round-robin, M=2) → `axil_xbar`
  (N=5: adds DMA-config as a slave) → peripherals. The DMA (`dma_engine`) is both a bus
  **slave** (its SRC/DST/LEN/CTRL registers per channel) and a bus **master** (the data
  mover); its two channels round-robin per word so concurrent copies make fair progress.
- **Arbiter decision — registered vs combinational grant:** first cut drove the grant
  combinationally from the request vector (`rr_pick(awvalid)`). Under contention this
  **glitched**: when the second master's `AWVALID` toggled mid-handshake, the selected
  master flipped, the slave saw a second `AWVALID`, and an address was **double-issued**
  (caught in sim: a channel's `LEN` write committed twice and its `START` write was lost,
  so that DMA channel never ran). Fix: **register the grant** — latch the round-robin winner
  when idle and hold it from lock to response handshake, so routing is stable for the whole
  transaction (1-cycle arbitration latency, no glitch).
- **Slave write robustness:** the DMA config slave latches `AW` and `W` **independently** and
  commits when both are captured, rather than assuming they arrive the same cycle — robust to
  AW/W skew an arbiter can introduce. (The simple peripherals are only ever driven by a single
  master per transaction, so they keep the simpler same-cycle accept.)
- **Timing note:** single-clock domain throughout the fabric; no CDC here (the async FIFO is
  the dedicated CDC block). Critical path is the address-decode + response mux; pipeldining the
  decode is the move if fmax needs it.

## riscv-soc-dv (DV track) — decisions
_Phase 2. Process gate: you write the verification plan first; I interview on the DUT and
critique the plan before any code._

## riscv-soc-dft (DFT track) — decisions
_Phase 2. Must cover: chain count vs compression, shift power, X-handling._

## riscv-soc-pd (PD track) — decisions
_Phase 2. Process gate: you write the SDC; I review/critique rather than write it._
