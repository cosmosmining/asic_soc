# Hardening the full SoC to GDSII

The pipeline already has a DRC/LVS-clean sky130 GDSII (`gds_flow/`). This is the
plan and the wiring to harden the **whole `soc_chip`** (CPU + RAM + CLINT + UART +
GPIO) the same way. PnR/STA/DRC/LVS are host stages (they need the sky130 PDK and
OpenROAD/Magic/Netgen); everything up to the gate netlist runs locally.

## Chip boundary — `soc_chip`

`rtl/soc/soc_chip.sv` is the place & route target. Over `soc_top` it adds what a
tapeout boundary needs:
- a **reset synchroniser** (external `rst_n` asserts asynchronously, de-asserts
  synchronously to `clk`) so no flop leaves reset on a recovery violation;
- a fixed, PnR-tractable RAM size and a narrow, pad-friendly port list.

The functional verification (differential regression + cocotb) runs on `soc_top`;
`soc_chip` is a thin wrapper, so it inherits that coverage.

## The RAM: two strategies

A standard sky130 SRAM macro is single-port and **synchronous-read**, but the
SoC's `soc_ram` has two **asynchronous** read ports (fetch + load). That mismatch
drives the choice:

**A. Inline flop RAM (default — `flow/pnr/config_soc.mk`).**
The RAM stays a small flop array (`soc_chip` `RAM_WORDS=1024`, 4 KiB) and ORFS
synthesises it to standard cells alongside the logic. Self-contained (no macro
generation), and functionally *exactly* what cocotb verifies. Cost: area — flops
are ~6–10× the density of an SRAM bitcell. Fine for a small RAM on sky130.

**B. Compiled SRAM macro (area-optimised) — implemented.**
A compiled SRAM is synchronous-read, so the core carries a one-cycle
**memory-wait**: `imem_ready`/`dmem_ready` inputs (`riscv_pipeline.sv`) stall the
front-end on fetch and freeze the pipeline on a load until the data lands, gating
every EX-stage commit effect so a frozen instruction is a perfect no-op. It is a
no-op when the memory answers combinationally (ready tied 1), so the async path
is byte-identical. `rtl/soc/soc_ram_sync.sv` models the macro (registered read +
ready), and `soc_top`/`soc_chip` select it with `SYNC_MEM=1`. Harden it via
`make synth-soc-macro` (tops at `soc_chip`, blackboxes `soc_ram_sync` -> SoC
**logic ≈ 19.3 k cells**, RAM a single macro instance); in ORFS add the macro's
`.lef`/`.lib`/`.gds` (`ADDITIONAL_LEFS`, `*_LIB`) and place it with macro
placement. A DFFRAM flop-macro is the async alternative (path A), trading area
for simplicity.

The memory-wait is verified: `make sync-regress` runs the differential golden
trace against a synchronous memory over directed + 100 random programs, and
`make sim-soc` runs the firmware on both the async and synchronous SoC (the
synchronous run exercises fetch + load stalls end to end).

## Flow

```
make synth-soc        # quick area check (RAM as flops)
make synth-soc-macro  # hardening netlist: logic to std cells, RAM = macro instance
make pnr DESIGN=soc   # ORFS floorplan->place->CTS->route->GDSII   (host: PDK)
make sta              # OpenSTA setup/hold signoff                  (host: PDK)
make drc lvs          # Magic / Netgen physical verification        (host: PDK)
make metrics          # fold the signoff numbers into summary.json
```

`flow/pnr/config_soc.mk` (ORFS) and `flow/sta/soc_chip.sdc` (50 MHz, with a false
path on the async reset) drive the host stages. Run them in the IIC-OSIC-TOOLS
docker image or via Nix/LibreLane.

## Status

- ✅ `soc_chip` lints clean; `make synth-soc-macro` produces the hardening netlist
  (logic ≈ 19.3 k cells, RAM a single macro instance), `check -assert` clean.
- ✅ ORFS config + SDC wired for the full SoC; the inline-RAM path is runnable
  on a PDK host with no extra collateral.
- ✅ Path B's synchronous-read **memory-wait is implemented and verified**
  (`make sync-regress`: directed + 100 random programs vs the golden ISS;
  `make sim-soc`: firmware on the synchronous SoC). The async path stays
  byte-identical (ready tied 1), and the safety BMC now proves PC/data alignment
  under *arbitrary* memory latency.
- ⏳ Host stages (PnR/STA/DRC/LVS) not run here — no PDK/OpenROAD in this
  environment. The pipeline's `gds_flow/` is the proven reference; running
  `make pnr DESIGN=soc` on a PDK host produces the SoC GDSII.
