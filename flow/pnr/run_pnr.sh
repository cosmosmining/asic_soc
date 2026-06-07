#!/usr/bin/env bash
# run_pnr.sh - place & route to GDSII.
#
# Prefers OpenROAD-flow-scripts (ORFS) if $FLOW_HOME is set; otherwise points at
# the proven OpenLane flow already captured under gds_flow/. Both need the sky130
# PDK and the OpenROAD toolchain (use the IIC-OSIC-TOOLS docker image or Nix).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if command -v openroad >/dev/null 2>&1 && [[ -n "${FLOW_HOME:-}" ]]; then
    echo ">> ORFS place & route (sky130hd, riscv_pipeline)"
    make -C "$FLOW_HOME" DESIGN_CONFIG="$ROOT/flow/pnr/config.mk"
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
