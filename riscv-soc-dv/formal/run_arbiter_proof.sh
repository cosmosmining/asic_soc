#!/usr/bin/env bash
# Formal proof of axil_arbiter safety with yosys + yosys-smtbmc (z3):
#   * grant mutual-exclusion: at most one master selected per response channel
#   * registered-grant stability: grant never changes mid-transaction
# BMC base case + unbounded temporal induction. Runs without SymbiYosys.
set -euo pipefail
cd "$(dirname "$0")"
ARB=../../riscv-soc/rtl/axil_arbiter.sv
mkdir -p /tmp/arbf
yosys -ql /tmp/arbf/arb.log -p \
  "read_verilog -sv -formal $ARB; chparam -set M 2 axil_arbiter; prep -top axil_arbiter; async2sync; dffunmap; write_smt2 -wires /tmp/arbf/arb.smt2"
echo ">> BMC base case (20 steps)"
yosys-smtbmc -s z3 -t 20 /tmp/arbf/arb.smt2
echo ">> temporal induction (unbounded)"
yosys-smtbmc -s z3 -i -t 20 /tmp/arbf/arb.smt2
echo "FORMAL: arbiter grant mutual-exclusion + grant-stability PROVEN (base + induction)"
