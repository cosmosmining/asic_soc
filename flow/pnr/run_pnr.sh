#!/usr/bin/env bash
# run_pnr.sh - place & route to GDSII.
#
# Prefers OpenROAD-flow-scripts (ORFS) if $FLOW_HOME is set; otherwise points at
# the proven OpenLane flow already captured under gds_flow/. Both need the sky130
# PDK and the OpenROAD toolchain (use the IIC-OSIC-TOOLS docker image or Nix).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# DESIGN=soc (default) hardens the full SoC (soc_chip); DESIGN=pipeline hardens
# just the RV32IM core.
DESIGN="${DESIGN:-soc}"
case "$DESIGN" in
    soc)      CFG="$ROOT/flow/pnr/config_soc.mk" ;;
    pipeline) CFG="$ROOT/flow/pnr/config.mk" ;;
    *) echo "unknown DESIGN=$DESIGN (use soc|pipeline)" >&2; exit 2 ;;
esac

if command -v openroad >/dev/null 2>&1 && [[ -n "${FLOW_HOME:-}" ]]; then
    echo ">> ORFS place & route (sky130hd, DESIGN=$DESIGN)"
    make -C "$FLOW_HOME" DESIGN_CONFIG="$CFG"
    exit $?
fi

cat <<'EOF'
pnr: OpenROAD / ORFS not detected in this environment.

  This is a host stage -- it needs the sky130 PDK and the OpenROAD toolchain.
  Two supported paths (both produce a routed GDSII with DRC/LVS):

    1. ORFS:     set FLOW_HOME to your OpenROAD-flow-scripts checkout, then
                 `make pnr` runs flow/pnr/config.mk.
    2. OpenLane: see gds_flow/README.md -- the repo already carries a proven
                 sky130 GDSII (gds_flow/signoff/, DRC 0 / LVS 0) built this way.

  Run it inside the IIC-OSIC-TOOLS docker image (Apple Silicon / WSL2 ok).
EOF
exit 127
