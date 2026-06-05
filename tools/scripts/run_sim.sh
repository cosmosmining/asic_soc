#!/usr/bin/env bash
# run_sim.sh <tb_top> [extra rtl/tb files...]
# Compiles the named testbench plus all RTL with Icarus Verilog and runs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB_TOP="${1:?usage: run_sim.sh <tb_top_module>}"
shift || true

BUILD="$ROOT/build"
mkdir -p "$BUILD"

# Gather sources: all synthesizable RTL + the requested TB file.
RTL_FILES=$(find "$ROOT/rtl" -name '*.sv' | sort)
TB_FILE=$(find "$ROOT/tb" -name "${TB_TOP}.sv" | head -1)

if [[ -z "${TB_FILE}" ]]; then
    echo "error: testbench ${TB_TOP}.sv not found under tb/" >&2
    exit 1
fi

echo ">> compiling ${TB_TOP}"
iverilog -g2012 -gsupported-assertions \
    -I "$ROOT/rtl/common" \
    -s "${TB_TOP}" \
    -o "$BUILD/${TB_TOP}.vvp" \
    ${RTL_FILES} "${TB_FILE}" "$@"

echo ">> running ${TB_TOP}"
vvp "$BUILD/${TB_TOP}.vvp"
