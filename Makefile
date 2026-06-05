# asic_soc - top-level build / verify / lint entry point.
#
# Quick start:
#   make tools     # one-time: install iverilog + verilator (Debian/Ubuntu)
#   make lint      # static lint (Verilator -Wall, zero warnings tolerated)
#   make sim       # single-cycle directed golden-trace test
#   make regress   # full differential regression (both cores + random seeds)
#   make           # == lint + regress  (the gate CI runs)
#
# Synthesis (needs yosys; sky130 flow needs the PDK via volare -- see gds_flow/):
#   make synth         # generic yosys elaboration/area for the pipeline
#   make synth-sky130  # map onto the real sky130 standard-cell library

SHELL    := /bin/bash
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD    := $(ROOT)/build

# --- source lists ----------------------------------------------------------
COMMON   := rtl/common
RTL_CORE := rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv \
            rtl/cpu_riscv/riscv_core.sv
RTL_PIPE := rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv \
            rtl/cpu_riscv/divider.sv rtl/cpu_riscv/mul_seq.sv rtl/cpu_riscv/riscv_pipeline.sv
RTL_SOC  := $(RTL_PIPE) rtl/soc/axi_sram.sv rtl/soc/riscv_cache.sv \
            rtl/soc/axil_arb.sv rtl/soc/riscv_soc.sv

# --- tools -----------------------------------------------------------------
IVERILOG := iverilog
VERILATOR:= verilator
WAIVERS  := tools/verilator/lint_waivers.vlt
VFLAGS   := --lint-only -Wall -I$(COMMON) $(WAIVERS)

# Random regression knobs (override on the command line: make regress SEEDS=200)
SEEDS    ?= 50
INSTR    ?= 64

.PHONY: all tools sim sim-pipeline regress lint lint-core lint-pipe \
        synth synth-sky130 clean help

all: lint regress           ## lint + full regression (the CI gate)

help:
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

tools:                      ## install iverilog + verilator (apt)
	apt-get update && apt-get install -y iverilog verilator

# --- simulation ------------------------------------------------------------
sim:                        ## single-cycle directed golden-trace test
	bash tools/scripts/run_sim.sh tb_riscv_trace

sim-pipeline:               ## 5-stage pipeline directed golden-trace test
	bash tools/scripts/run_sim.sh tb_riscv_trace -DPIPELINE

sim-soc:                    ## full-SoC test (pipeline + I$/D$ + AXI4-Lite SRAM)
	bash tools/scripts/run_sim.sh tb_soc

regress:                    ## full differential regression, both cores
	bash tools/scripts/regress.sh $(SEEDS) $(INSTR)

# --- lint ------------------------------------------------------------------
lint: lint-core lint-pipe lint-soc  ## Verilator lint everything (0 warnings tolerated)

lint-core:
	@echo ">> lint riscv_core (single-cycle)"
	$(VERILATOR) $(VFLAGS) --top-module riscv_core $(RTL_CORE)

lint-pipe:
	@echo ">> lint riscv_pipeline (5-stage)"
	$(VERILATOR) $(VFLAGS) --top-module riscv_pipeline $(RTL_PIPE)

lint-soc:
	@echo ">> lint riscv_soc (pipeline + I\$$/D\$$ + AXI4-Lite SRAM)"
	$(VERILATOR) $(VFLAGS) --top-module riscv_soc $(RTL_SOC)

# --- synthesis -------------------------------------------------------------
synth:                      ## generic yosys synth/area for the pipeline
	yosys -s tools/yosys/synth_pipeline.ys

synth-sky130:               ## map pipeline onto the real sky130 PDK
	bash tools/scripts/synth_sky130.sh riscv_pipeline

clean:                      ## remove build artifacts
	rm -rf $(BUILD) *.vcd *.vvp
