#!/usr/bin/env bash
# regress_sync.sh [n_seeds] [n_instr]
# Differential regression of the pipeline against a SYNCHRONOUS (registered-read)
# memory -- the compiled-SRAM access model -- in BOTH fetch modes:
#   tb_riscv_sync      : stall-model fetch  (imem_ready handshake, ~2x CPI)
#   tb_riscv_pipefetch : pipelined fetch    (SYNC_FETCH=1, imem_cen, ~1 IPC)
# Each runs the directed programs + N random seeds and checks every retire
# against the timing-independent golden ISS, stressing the memory-wait stalls
# and (for pipefetch) the one-cycle redirect bubble across loads, stores,
# branches, CSRs and divides.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
N_SEEDS="${1:-50}"
N_INSTR="${2:-64}"
BUILD="$ROOT/build"; mkdir -p "$BUILD"

RTL=$(find "$ROOT/rtl" -path '*/generated/*' -prune -o -name '*.sv' -print | sort)
HELP=$(find "$ROOT/tb" -path '*/uvm/*' -prune -o -name '*.sv' ! -name 'tb_*' -print | sort)

build() {  # <tb_top> <out>
    iverilog -g2012 -gsupported-assertions -I "$ROOT/rtl/common" \
        -s "$1" -o "$2" $RTL $HELP "$ROOT/tb/directed/$1.sv" 2>/dev/null
}
echo ">> building tb_riscv_sync (stall-model) + tb_riscv_pipefetch (pipelined)"
build tb_riscv_sync      "$BUILD/sync.vvp"
build tb_riscv_pipefetch "$BUILD/pf.vvp"

run() { vvp "$1" "+PROG=$2" 2>/dev/null | grep -q "RESULT: PASS" && echo PASS || echo FAIL; }

fails=0
check() {  # <vvp> <prog> <label>
    [[ "$(run "$1" "$2")" == PASS ]] || { echo "   $3 FAIL"; fails=$((fails+1)); }
}

for vv in "$BUILD/sync.vvp:stall" "$BUILD/pf.vvp:pipe"; do
    bin="${vv%%:*}"; tag="${vv##*:}"
    check "$bin" "$ROOT/tb/directed/programs/test_core.hex" "$tag directed test_core"
    check "$bin" "$ROOT/tb/directed/programs/csr_test.hex"  "$tag directed csr_test"
done

echo ">> $N_SEEDS linear + $N_SEEDS mixed random seeds ($N_INSTR instr), both fetch modes"
for s in $(seq 1 "$N_SEEDS"); do
    python3 "$ROOT/tools/scripts/gen_rand_prog.py" "$s" "$N_INSTR" > "$BUILD/sr.hex"
    python3 "$ROOT/tools/scripts/gen_rand_prog.py" "$s" "$N_INSTR" 0.15 0.30 > "$BUILD/sm.hex"
    for bin in "$BUILD/sync.vvp" "$BUILD/pf.vvp"; do
        check "$bin" "$BUILD/sr.hex" "seed $s linear"
        check "$bin" "$BUILD/sm.hex" "seed $s mixed"
    done
done

echo "------------------------------------------------------------"
if [[ $fails -eq 0 ]]; then
    echo "SYNC REGRESSION PASS: directed + $N_SEEDS random seeds (stall + pipelined fetch)"
    exit 0
else
    echo "SYNC REGRESSION FAIL: $fails failing case(s)"
    exit 1
fi
