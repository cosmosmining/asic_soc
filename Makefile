# asic_soc - top-level build / verify / lint entry point.
#
# Combined tree:
#   * verified RV32IM core (CSR + sequential multiplier + caches + sky130 GDS signoff)
#   * four-track interview portfolio: riscv-soc / -dv / -dft / -pd
#
# Quick start:
#   make tools      # one-time: install iverilog + verilator
#   make lint       # Verilator lint: core (with waivers) + portfolio blocks, 0 warnings
#   make regress    # differential regression (both cores + random seeds)
#   make portfolio  # run all four portfolio tracks (soc/dv/dft/pd)
#   make            # help

SHELL    := /bin/bash
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD    := $(ROOT)/build
.DEFAULT_GOAL := help

# --- core source lists -----------------------------------------------------
COMMON   := rtl/common
RTL_CORE := rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv \
            rtl/cpu_riscv/riscv_core.sv
RTL_PIPE := rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv \
            rtl/cpu_riscv/divider.sv rtl/cpu_riscv/mul_seq.sv rtl/cpu_riscv/riscv_pipeline.sv

VERILATOR := verilator
WAIVERS   := tools/verilator/lint_waivers.vlt
VFLAGS    := --lint-only -Wall -I$(COMMON) $(WAIVERS)
SEEDS    ?= 50
INSTR    ?= 64

.PHONY: all help tools sim sim-pipeline regress lint lint-core lint-pipe \
        synth synth-sky130 portfolio soc dv dft pd clean

all: lint regress           ## core gate: lint (0 warnings) + differential regression

help:
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

tools:                      ## install iverilog + verilator (apt)
	apt-get update && apt-get install -y iverilog verilator

# --- core simulation + regression (verified RV32IM) ------------------------
sim:                        ## single-cycle directed golden-trace test
	bash tools/scripts/run_sim.sh tb_riscv_trace

sim-pipeline:               ## 5-stage pipeline directed golden-trace test
	bash tools/scripts/run_sim.sh tb_riscv_trace -DPIPELINE

regress:                    ## full differential regression, both cores
	bash tools/scripts/regress.sh $(SEEDS) $(INSTR)

# --- lint: core (with justified waivers) + portfolio blocks, 0 warnings ----
lint: lint-core lint-pipe   ## Verilator lint core + portfolio blocks (0 warnings)
	$(MAKE) -C riscv-soc lint

lint-core:
	@echo ">> lint riscv_core (single-cycle)"
	$(VERILATOR) $(VFLAGS) --top-module riscv_core $(RTL_CORE)

lint-pipe:
	@echo ">> lint riscv_pipeline (5-stage)"
	$(VERILATOR) $(VFLAGS) --top-module riscv_pipeline $(RTL_PIPE)

# --- synthesis -------------------------------------------------------------
synth:                      ## generic yosys synth/area for the pipeline
	yosys -s tools/yosys/synth_pipeline.ys

synth-sky130:               ## map pipeline onto the real sky130 PDK
	bash tools/scripts/synth_sky130.sh riscv_pipeline

# --- interview portfolio tracks --------------------------------------------
portfolio: soc dv dft pd    ## run all four portfolio tracks

soc:                        ## RTL track: AXI4-Lite SoC (lint + sim + formal)
	$(MAKE) -C riscv-soc all

dv:                         ## DV track: arbiter formal proofs (yosys-smtbmc)
	bash riscv-soc-dv/formal/run_arbiter_proof.sh

dft:                        ## DFT track: C++ stuck-at fault simulator
	$(MAKE) -C riscv-soc-dft/fault_sim run

pd:                         ## PD track: STA timing-violation classifier
	python3 riscv-soc-pd/timing_cli/tests/test_classify.py

clean:                      ## remove build artifacts
	rm -rf $(BUILD) build obj_dir *.vcd *.vvp
