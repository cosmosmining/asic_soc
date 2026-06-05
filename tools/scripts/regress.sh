#!/usr/bin/env bash
# regress.sh [n_seeds] [n_instr]
# Full regression: builds both cores once, runs the directed golden-trace test,
# then runs N random-program differential tests against BOTH the single-cycle
# core and the 5-stage pipeline. Any mismatch fails the run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
N_SEEDS="${1:-50}"
N_INSTR="${2:-64}"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

RTL=$(find "$ROOT/rtl" -name '*.sv' | sort)
HELP=$(find "$ROOT/tb" -name '*.sv' ! -name 'tb_*' | sort)
TB="$ROOT/tb/directed/tb_riscv_trace.sv"
IVFLAGS="-g2012 -gsupported-assertions -I $ROOT/rtl/common"

echo ">> building single-cycle + pipeline test binaries"
iverilog $IVFLAGS            -s tb_riscv_trace -o "$BUILD/tb_sc.vvp" $RTL $HELP "$TB" 2>/dev/null
iverilog $IVFLAGS -DPIPELINE -s tb_riscv_trace -o "$BUILD/tb_pl.vvp" $RTL $HELP "$TB" 2>/dev/null

run_one() { # <vvp> <prog>  -> echoes PASS/FAIL
    vvp "$1" "+PROG=$2" 2>/dev/null | grep -q "RESULT: PASS" && echo PASS || echo FAIL
}

fails=0

echo ">> directed test (default program)"
for vv in tb_sc tb_pl; do
    r=$(vvp "$BUILD/$vv.vvp" 2>/dev/null | grep -E "RESULT" | head -1)
    echo "   $vv: $r"; echo "$r" | grep -q PASS || fails=$((fails+1))
done

echo ">> $N_SEEDS random differential tests ($N_INSTR instr each)"
for s in $(seq 1 "$N_SEEDS"); do
    python3 "$ROOT/tools/scripts/gen_rand_prog.py" "$s" "$N_INSTR" > "$BUILD/rand_$s.hex"
    sc=$(run_one "$BUILD/tb_sc.vvp" "$BUILD/rand_$s.hex")
    pl=$(run_one "$BUILD/tb_pl.vvp" "$BUILD/rand_$s.hex")
    if [[ "$sc" != PASS || "$pl" != PASS ]]; then
        echo "   seed $s: SC=$sc PL=$pl   <-- FAIL (prog: build/rand_$s.hex)"
        fails=$((fails+1))
    fi
done

echo "------------------------------------------------------------"
if [[ $fails -eq 0 ]]; then
    echo "REGRESSION PASS: directed + $N_SEEDS random seeds, both cores"
    exit 0
else
    echo "REGRESSION FAIL: $fails failing case(s)"
    exit 1
fi
