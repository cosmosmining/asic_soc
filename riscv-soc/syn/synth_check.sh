#!/usr/bin/env bash
# Generic (technology-independent) Yosys synthesis of each fabric/logic block.
# Reports the abstract cell count and asserts each block is LATCH-FREE (an
# inferred latch in synchronous RTL is a bug). sky130 area/fmax come from the PD
# track (OpenLane); these numbers are a fast, reproducible synthesizability gate.
set -euo pipefail
cd "$(dirname "$0")/.."
RTL="rtl/sync_2ff.sv rtl/async_fifo.sv rtl/axil_uart.sv rtl/axil_timer.sv rtl/axil_xbar.sv rtl/axil_arbiter.sv rtl/dma_engine.sv"
printf "%-14s %-14s %s\n" "block" "generic_cells" "latch-free"
for m in async_fifo axil_arbiter axil_xbar dma_engine axil_uart axil_timer; do
    yosys -qp "read_verilog -sv $RTL; synth -top $m -flatten; \
               select -assert-none t:\$dlatch t:\$dlatchsr; \
               tee -o /tmp/stat_$m.txt stat" >/dev/null 2>&1
    cells=$(grep 'Number of cells' /tmp/stat_$m.txt | head -1 | grep -oE '[0-9]+$')
    printf "%-14s %-14s %s\n" "$m" "$cells" "OK"
done
echo "SYNTH: all blocks synthesize, 0 inferred latches"
