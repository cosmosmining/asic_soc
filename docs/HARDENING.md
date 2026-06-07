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

**B. Compiled SRAM macro (area-optimised).**
Swap the RAM for an OpenRAM `1rw1r` (or DFFRAM) macro: `make synth-soc-macro`
already blackboxes `soc_ram` and emits a top netlist with the RAM as a single
instance (SoC **logic ≈ 19.3 k cells**, RAM excluded). In ORFS, add the macro's
`.lef`/`.lib`/`.gds` (`ADDITIONAL_LEFS`, `*_LIB`) and place it with macro
placement. **Prerequisite RTL:** a compiled SRAM is synchronous-read, so the core
needs a one-cycle **memory-wait** (registered fetch + a load stall) to use it.
That change is functionally verifiable locally (regression + cocotb) and is the
one remaining RTL item before path B is drop-in. A DFFRAM flop-macro keeps the
async read and needs no core change, trading area for simplicity.

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
- ⏳ Host stages (PnR/STA/DRC/LVS) not run here — no PDK/OpenROAD in this
  environment. The pipeline's `gds_flow/` is the proven reference.
- ⏳ Path B's synchronous-read memory-wait is the remaining RTL change for a
  compiled-SRAM die; path A needs none.
