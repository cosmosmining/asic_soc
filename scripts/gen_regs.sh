#!/usr/bin/env bash
# gen_regs.sh - generate RTL + docs + C header + UVM model from the SystemRDL
# register specs (regs/*.rdl) using PeakRDL. One source -> four consistent views.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="rtl/generated"
DOC="docs/regs"
mkdir -p "$OUT" "$DOC"

for rdl in regs/*.rdl; do
    base="$(basename "${rdl%.rdl}")"
    echo ">> $rdl"
    # synthesizable register block (APB4 control interface)
    peakrdl regblock "$rdl" -o "$OUT" --cpuif apb4-flat
    # firmware C header (register offsets + field masks)
    peakrdl c-header "$rdl" -o "$OUT/${base}.h"
    # UVM register model (for a commercial-sim RAL)
    peakrdl uvm "$rdl" -o "$OUT/${base}_uvm_pkg.sv"
    # HTML documentation
    peakrdl html "$rdl" -o "$DOC/${base}"
done
echo ">> generated register collateral in $OUT and $DOC"
