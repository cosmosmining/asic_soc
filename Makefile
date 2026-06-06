# RISC-V SoC portfolio — top-level dispatch.
# Reproducible entry points; CI calls these directly.
SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: help smoke regress lint clean soc dv dft pd

help: ## list targets
	@echo "RISC-V SoC portfolio — targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

smoke: ## directed smoke + 20-seed differential regression (iverilog)
	bash tools/scripts/run_sim.sh tb_riscv_core
	bash tools/scripts/regress.sh 20 64

regress: ## directed + 100-seed regression, both cores
	bash tools/scripts/regress.sh 100 64

lint: ## Verilator --lint-only on the core (advisory until Phase 1 cleanup)
	verilator --lint-only -Wall +incdir+rtl/common --top-module riscv_pipeline \
	  rtl/cpu_riscv/riscv_pipeline.sv rtl/cpu_riscv/alu.sv \
	  rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/divider.sv

clean: ## remove build artifacts
	rm -rf build obj_dir *.vcd

# --- per-track dispatch (implemented as each phase lands) ---
soc: ## riscv-soc track (Phase 1)
	$(MAKE) -C riscv-soc
dv: ## riscv-soc-dv track — formal proofs (yosys-smtbmc)
	bash riscv-soc-dv/formal/run_arbiter_proof.sh
dft: ## riscv-soc-dft track (Phase 2)
	@echo "riscv-soc-dft: Phase 2 — not yet implemented"
pd: ## riscv-soc-pd track (Phase 2)
	@echo "riscv-soc-pd: Phase 2 — not yet implemented"
