#!/usr/bin/env bash
# synth_sky130.sh [top]
# ASIC synthesis of the CPU mapped to the REAL SkyWater sky130 standard-cell
# library (sky130_fd_sc_hd). Reports true cell count and silicon area (um^2)
# and writes a technology-mapped gate-level netlist. This is genuine physical
# synthesis against a real PDK -- the step before place & route.
#
# Requires the sky130 PDK fetched via volare (see README). Set PDK_ROOT or let
# this script default to tools/pdk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
TOP="${1:-riscv_pipeline}"
export PDK_ROOT="${PDK_ROOT:-$ROOT/tools/pdk}"
BUILD="$ROOT/build"; mkdir -p "$BUILD"

LIB=$(find "$PDK_ROOT" -name "sky130_fd_sc_hd__tt_025C_1v80.lib" 2>/dev/null | head -1)
if [[ -z "$LIB" ]]; then
    echo "error: sky130 liberty not found under $PDK_ROOT" >&2
    echo "  run: tools/.venv/bin/volare enable --pdk sky130   (PDK_ROOT=$PDK_ROOT)" >&2
    exit 1
fi
echo ">> using liberty: $LIB"

case "$TOP" in
    riscv_pipeline) SRCS="rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/alu.sv rtl/cpu_riscv/divider.sv rtl/cpu_riscv/riscv_pipeline.sv" ;;
    riscv_core)     SRCS="rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/alu.sv rtl/cpu_riscv/riscv_core.sv" ;;
    *) echo "unknown top $TOP" >&2; exit 1 ;;
esac

yosys -q -p "
    read_verilog -sv -I rtl/common $SRCS
    hierarchy -check -top $TOP
    synth -top $TOP -flatten
    dfflibmap -liberty $LIB
    abc -liberty $LIB
    setundef -zero
    opt_clean -purge
    write_verilog -noattr $BUILD/${TOP}_sky130.v
    tee -o $BUILD/${TOP}_sky130_area.rpt stat -liberty $LIB
"
echo ">> wrote $BUILD/${TOP}_sky130.v and area report"
echo "------ area summary ------"
grep -E "Number of cells|Chip area|Number of wires" "$BUILD/${TOP}_sky130_area.rpt" || true
