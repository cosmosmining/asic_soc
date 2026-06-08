#!/usr/bin/env bash
# run_formal.sh - run every SymbiYosys task and summarise pass/fail.
# Proofs: ALU operation equivalence (exhaustive, depth 1) and core safety BMC
# (PC/data alignment, store byte-enable) over arbitrary instruction streams.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if ! command -v sby >/dev/null 2>&1; then
    echo "formal: SymbiYosys (sby) not installed -- see docs/FLOW.md" >&2
    exit 127
fi

rc=0
for cfg in flow/formal/*.sby; do
    name="$(basename "${cfg%.sby}")"
    echo ">> formal: $name"
    rm -rf "flow/formal/$name"
    if sby -f "$cfg" >/dev/null 2>&1; then
        echo "   PASS  $name ($(cat flow/formal/$name/status 2>/dev/null))"
    else
        echo "   FAIL  $name -- see flow/formal/$name/ for the counterexample"
        rc=1
    fi
done
exit $rc
