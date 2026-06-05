#!/usr/bin/env bash
# ppa.sh [top] [clk_period_ns]
# Real sky130 PPA: Yosys maps the design to the SkyWater sky130_fd_sc_hd
# standard-cell library (area + gate-level netlist); OpenSTA then closes timing
# at the target period and reports power. Writes gds_flow/reports/ppa_<top>.rpt.
#
# The SoC's SRAM is a memory macro, so for `riscv_soc` the SRAM is treated as a
# black box (its bits are not synthesised to flip-flops).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"
TOP="${1:-riscv_pipeline}"
PERIOD="${2:-12.0}"          # ns ; 12 ns = 83.3 MHz target
BUILD="$ROOT/build"; mkdir -p "$BUILD"
REPORTS="$ROOT/gds_flow/reports"; mkdir -p "$REPORTS"

LIB="${LIB:-$(find "$ROOT/tools/pdk" -name 'sky130_fd_sc_hd__tt*.lib' 2>/dev/null | head -1)}"
[[ -z "$LIB" ]] && { echo "error: sky130 liberty not found under tools/pdk" >&2; exit 1; }
echo ">> top=$TOP  period=${PERIOD}ns  lib=$(basename "$LIB")"

case "$TOP" in
  riscv_pipeline) SRCS="rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv rtl/cpu_riscv/divider.sv rtl/cpu_riscv/mul_seq.sv rtl/cpu_riscv/riscv_pipeline.sv"; BBOX="" ;;
  riscv_soc)      SRCS="rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv rtl/cpu_riscv/divider.sv rtl/cpu_riscv/mul_seq.sv rtl/cpu_riscv/riscv_pipeline.sv rtl/soc/axi_sram.sv rtl/soc/riscv_cache.sv rtl/soc/axil_arb.sv rtl/soc/riscv_soc.sv"; BBOX="blackbox axi_sram" ;;
  *) echo "unknown top $TOP" >&2; exit 1 ;;
esac

NET="$BUILD/${TOP}_sky130.v"
echo ">> [1/2] yosys synthesis + area"
yosys -q -p "
    read_verilog -sv -I rtl/common $SRCS
    hierarchy -check -top $TOP
    ${BBOX}
    synth -top $TOP -flatten
    dfflibmap -liberty $LIB
    abc -liberty $LIB
    setundef -zero
    opt_clean -purge
    write_verilog -noattr $NET
    tee -o $BUILD/${TOP}_area.rpt stat -liberty $LIB
"

# --- OpenSTA timing + power (if available) ---
STA="${STA_BIN:-/tmp/OpenSTA/build/sta}"
RPT="$REPORTS/ppa_${TOP}.rpt"
if [[ -x "$STA" ]]; then
  echo ">> [2/2] OpenSTA timing + power @ ${PERIOD}ns"
  cat > "$BUILD/sta_${TOP}.tcl" <<EOF
read_liberty $LIB
read_verilog $NET
link_design $TOP
create_clock -name clk -period $PERIOD [get_ports clk]
set_input_delay  -clock clk [expr 0.30*$PERIOD] [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -clock clk [expr 0.30*$PERIOD] [all_outputs]
set_load 0.05 [all_outputs]
puts "=== SETUP (worst) ==="
report_wns
report_tns
report_worst_slack -max
puts "=== POWER ==="
report_power
EOF
  "$STA" -no_init -exit "$BUILD/sta_${TOP}.tcl" | tee "$RPT.tmp"
  { echo "# PPA signoff: $TOP @ ${PERIOD}ns (sky130_fd_sc_hd tt_025C_1v80)";
    grep -iE "Number of cells|Chip area" "$BUILD/${TOP}_area.rpt";
    cat "$RPT.tmp"; } > "$RPT"; rm -f "$RPT.tmp"
  echo ">> wrote $RPT"
else
  echo ">> OpenSTA not built; area only. (build: see tools/scripts/build_opensta.sh)"
  { echo "# Area: $TOP (sky130_fd_sc_hd tt_025C_1v80)";
    grep -iE "Number of cells|Chip area" "$BUILD/${TOP}_area.rpt"; } > "$RPT"
fi
echo "------ summary ------"; cat "$RPT" | grep -iE "cells|area|slack|wns|Total " | head