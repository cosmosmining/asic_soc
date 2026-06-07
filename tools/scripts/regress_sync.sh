#!/usr/bin/env bash
# regress_sync.sh [n_seeds] [n_instr]
# Differential regression of the pipeline against a SYNCHRONOUS (registered-read)
# memory with the imem_ready/dmem_ready handshake -- the compiled-SRAM access
# model. Runs the directed programs plus N random seeds and checks every retire
# against the timing-independent golden ISS, so it stresses the memory-wait
# stalls (fetch + load) across loads, stores, branches, CSRs and divides.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
N_SEEDS="${1:-50}"
N_INSTR="${2:-64}"
BUILD="$ROOT/build"; mkdir -p "$BUILD"

RTL=$(find "$ROOT/rtl" -path '*/generated/*' -prune -o -name '*.sv' -print | sort)
HELP=$(find "$ROOT/tb" -path '*/uvm/*' -prune -o -name '*.sv' ! -name 'tb_*' -print | sort)

echo ">> building tb_riscv_sync (synchronous-memory pipeline)"
iverilog -g2012 -gsupported-assertions -I "$ROOT/rtl/common" \
    -s tb_riscv_sync -o "$BUILD/sync.vvp" \
    $RTL $HELP "$ROOT/tb/directed/tb_riscv_sync.sv" 2>/dev/null

run() { vvp "$BUILD/sync.vvp" "+PROG=$1" 2>/dev/null | grep -q "RESULT: PASS" && echo PASS || echo FAIL; }

fails=0
for p in test_core csr_test; do
    r=$(run "$ROOT/tb/directed/programs/$p.hex")
    echo "   directed $p: $r"; [[ "$r" == PASS ]] || fails=$((fails+1))
done

echo ">> $N_SEEDS linear + $N_SEEDS mixed random seeds ($N_INSTR instr)"
for s in $(seq 1 "$N_SEEDS"); do
    python3 "$ROOT/tools/scripts/gen_rand_prog.py" "$s" "$N_INSTR" > "$BUILD/sr.hex"
    [[ "$(run "$BUILD/sr.hex")" == PASS ]] || { echo "   linear seed $s FAIL"; fails=$((fails+1)); }
    python3 "$ROOT/tools/scripts/gen_rand_prog.py" "$s" "$N_INSTR" 0.15 0.30 > "$BUILD/sm.hex"
    [[ "$(run "$BUILD/sm.hex")" == PASS ]] || { echo "   mixed seed $s FAIL"; fails=$((fails+1)); }
done

echo "------------------------------------------------------------"
if [[ $fails -eq 0 ]]; then
    echo "SYNC REGRESSION PASS: directed + $N_SEEDS random seeds (synchronous memory)"
    exit 0
else
    echo "SYNC REGRESSION FAIL: $fails failing case(s)"
    exit 1
fi
