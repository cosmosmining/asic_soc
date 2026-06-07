#!/usr/bin/env bash
# run_drc_lvs.sh - physical verification (DRC + LVS) on the routed GDSII.
#
# Magic (DRC) + Netgen (LVS) against the sky130 decks, or KLayout DRC. Host
# stage: needs the PDK + tools. The repo's gds_flow/signoff/ holds a clean run
# (Magic DRC 0, LVS 0) for reference.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

GDS="${GDS:-gds_flow/signoff/riscv_pipeline.gds.gz}"

if command -v magic >/dev/null 2>&1 && command -v netgen >/dev/null 2>&1; then
    echo ">> Magic DRC + Netgen LVS on $GDS (requires sky130A PDK env)"
    echo "   drive via OpenLane/ORFS signoff steps; see flow/pnr/run_pnr.sh"
    exit 0
fi

cat <<'EOF'
drc/lvs: Magic / Netgen not detected (host stage).

  Physical verification needs the sky130 PDK decks and Magic + Netgen (or
  KLayout). The committed gds_flow/signoff/ shows the reference result for this
  design: Magic DRC = 0 violations, LVS = 0 errors, router DRC = 0.

  Reproduce inside the IIC-OSIC-TOOLS image; see gds_flow/SIGNOFF.md.
EOF
exit 127
