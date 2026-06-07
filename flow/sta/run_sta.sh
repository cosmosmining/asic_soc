#!/usr/bin/env bash
# run_sta.sh - OpenSTA timing signoff on the sky130-mapped netlist.
#
# Runs if OpenSTA and a sky130 Liberty are available. Produce the netlist first
# with `make synth-sky130`. Liberty path can be overridden with LIB=...
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TOP="${TOP:-riscv_pipeline}"
NETLIST="${NETLIST:-build/${TOP}_sky130.v}"
SDC="${SDC:-flow/sta/riscv_pipeline.sdc}"
LIB="${LIB:-$(ls tools/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib 2>/dev/null | head -1)}"

if ! command -v sta >/dev/null 2>&1; then
    echo "sta: OpenSTA not installed."
    echo "    install: https://github.com/parallaxsw/OpenSTA  (or use the IIC-OSIC-TOOLS image)"
    echo "    then:    make synth-sky130 && make sta"
    exit 127
fi
if [[ -z "$LIB" || ! -f "$LIB" ]]; then
    echo "sta: sky130 Liberty not found (set LIB=...). Fetch the PDK with volare; see gds_flow/README.md" >&2
    exit 2
fi
if [[ ! -f "$NETLIST" ]]; then
    echo "sta: gate netlist $NETLIST missing -- run 'make synth-sky130' first" >&2
    exit 2
fi

echo ">> OpenSTA: TOP=$TOP  LIB=$LIB"
LIB="$LIB" NETLIST="$NETLIST" TOP="$TOP" SDC="$SDC" sta -no_init -exit flow/sta/sta.tcl
