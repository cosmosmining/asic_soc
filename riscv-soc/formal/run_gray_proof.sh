#!/usr/bin/env bash
# Real formal proof of the async-FIFO Gray-pointer encoding with yosys +
# yosys-smtbmc (z3) -- no SymbiYosys needed, so it runs in CI.
# Proves, over the actual pointer RTL:
#   P1  gray == graycode(bin)                         (encoding correctness)
#   P2  popcount(gray ^ past(gray)) <= 1              (single-bit CDC transition)
# via BMC base case + unbounded temporal induction (a complete proof).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
yosys -ql build/gray.log -p \
  "read_verilog -sv -formal formal/gray_inc.sv; prep -top gray_inc; async2sync; dffunmap; write_smt2 -wires build/gray_inc.smt2"
echo ">> BMC base case (20 steps)"
yosys-smtbmc -s z3 -t 20 build/gray_inc.smt2
echo ">> temporal induction (unbounded)"
yosys-smtbmc -s z3 -i -t 20 build/gray_inc.smt2
echo "FORMAL: PASSED (Gray-pointer invariants P1+P2: base case + induction)"
