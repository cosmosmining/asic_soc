# BUGS_FOUND — real defects caught by verification

Defects found while building/verifying the riscv-soc DUTs. Format:
**ID · DUT · how found · root cause · fix · severity.** (These are real — every one
was reproduced in simulation before the fix.)

## BUG-001 — arbiter double-issues an address under multi-master contention  [HIGH]
- **DUT:** `axil_arbiter` (round-robin AXI4-Lite, M masters).
- **Found by:** `tb_dma` two-channel concurrent copy — DMA channel 1's destination
  read back as `X`; the channel never ran.
- **Triage:** a config-write trace showed channel 1's `LEN` write committed **twice**
  and its `START` write was **dropped** (`off=18` twice, `off=1c` missing).
- **Root cause:** the grant was driven **combinationally** from the request vector
  (`rr_pick(mi_awvalid)`). When the other master's `AWVALID` toggled mid-handshake,
  the selected index flipped, the slave saw `AWVALID` a second time, and one address
  was double-accepted — corrupting the transaction stream.
- **Fix:** **register the grant** — latch the round-robin winner on lock and hold it to
  the response handshake. Now **formally proven stable** (`formal/run_arbiter_proof.sh`,
  grant-stability property).
- **Severity:** high — silent data corruption / dropped transaction under contention.

## BUG-002 — DMA config slave assumed AW and W arrive on the same cycle  [MED]
- **DUT:** `dma_engine` config slave (AXI4-Lite write).
- **Found by:** same test (suspected here first, before root-causing BUG-001).
- **Root cause:** the write committed using `s_wdata` at the cycle `AW`+`W` coincided;
  under arbiter-induced **AW/W skew** that could pair an address with stale write data.
- **Fix:** latch `AW` and `W` **independently**, commit when both are captured.
- **Severity:** medium — robustness; only exposed under arbitration.

## Process note (not a DUT bug)
The first `tb_async_fifo` checker re-sampled `rdata` in the same delta the read pointer
advanced (FWFT off-by-one) — a **testbench** bug, fixed by sampling on the read-fire edge.
Logged here as a reminder that an apparent DUT failure was the bench.

---
**Tally for résumé:** 2 real RTL bugs found + fixed (1 high, 1 medium), 1 high-severity
bug subsequently closed with a formal proof.
