# asic_soc - one target per flow stage. Every stage returns a real exit code so
# the agent loop (and CI) gate on pass/fail, not on parsing logs.
#
#   make tools        install the open-source toolchain (apt + pip)
#   make lint         Verilator lint, 0 warnings (RTL + SoC)
#   make regs         PeakRDL: RTL + C header + UVM + HTML from regs/*.rdl
#   make sim          directed golden-trace test (single-cycle)
#   make regress      differential regression (both cores + random seeds)
#   make sim-soc      cocotb SoC test (UART + machine-timer interrupts)
#   make formal       SymbiYosys: ALU equivalence + pipeline safety BMC
#   make synth        generic Yosys synth/area (pipeline)
#   make synth-soc    generic Yosys synth/area (full SoC)
#   make synth-sky130 map the pipeline onto the sky130 standard cells
#   make sta          OpenSTA timing signoff            (host stage: PDK + tool)
#   make pnr          OpenROAD/ORFS place & route        (host stage)
#   make drc lvs      Magic/Netgen physical verification (host stage)
#   make metrics      aggregate reports/summary.json
#   make all          lint + regress + sim-soc + formal  (the CI gate)

SHELL    := /bin/bash
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD    := $(ROOT)/build

# --- source lists ----------------------------------------------------------
COMMON   := rtl/common
RTL_CORE := rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv \
            rtl/cpu_riscv/riscv_core.sv
RTL_PIPE := rtl/cpu_riscv/regfile.sv rtl/cpu_riscv/csr.sv rtl/cpu_riscv/alu.sv \
            rtl/cpu_riscv/divider.sv rtl/cpu_riscv/mul_seq.sv rtl/cpu_riscv/riscv_pipeline.sv
RTL_SOC  := $(RTL_PIPE) rtl/soc/soc_ram.sv rtl/soc/mtimer.sv rtl/soc/uart_tx.sv \
            rtl/soc/gpio.sv rtl/soc/soc_top.sv rtl/soc/soc_chip.sv

# --- tools -----------------------------------------------------------------
VERILATOR := verilator
WAIVERS   := tools/verilator/lint_waivers.vlt
VFLAGS    := --lint-only -Wall -I$(COMMON) $(WAIVERS)

SEEDS ?= 50
INSTR ?= 64

.PHONY: all tools lint lint-core lint-pipe lint-soc regs sim sim-pipeline regress \
        sim-soc formal synth synth-soc synth-soc-macro synth-sky130 sta pnr drc lvs \
        metrics clean help

all: lint regress sim-soc formal   ## the CI gate (lint + regression + SoC + formal)

help:
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

tools:                      ## install the open-source toolchain (apt + pip)
	sudo apt-get update && sudo apt-get install -y iverilog verilator yosys
	pip install -q cocotb cocotb-bus peakrdl peakrdl-regblock peakrdl-uvm \
	    peakrdl-cheader peakrdl-html z3-solver

# --- lint ------------------------------------------------------------------
lint: lint-core lint-pipe lint-soc  ## Verilator lint (0 warnings tolerated)

lint-core:
	@echo ">> lint riscv_core (single-cycle)"
	$(VERILATOR) $(VFLAGS) --top-module riscv_core $(RTL_CORE)

lint-pipe:
	@echo ">> lint riscv_pipeline (5-stage)"
	$(VERILATOR) $(VFLAGS) --top-module riscv_pipeline $(RTL_PIPE)

lint-soc:
	@echo ">> lint soc_chip (full SoC + chip wrapper)"
	$(VERILATOR) $(VFLAGS) --top-module soc_chip $(RTL_SOC)

# --- register generation ---------------------------------------------------
regs:                       ## PeakRDL: regblock + docs + C header + UVM
	bash scripts/gen_regs.sh

# --- simulation / verification ---------------------------------------------
sim:                        ## directed golden-trace test (single-cycle)
	bash tools/scripts/run_sim.sh tb_riscv_trace

sim-pipeline:               ## directed golden-trace test (5-stage pipeline)
	bash tools/scripts/run_sim.sh tb_riscv_trace -DPIPELINE

regress:                    ## differential regression, both cores + random
	bash tools/scripts/regress.sh $(SEEDS) $(INSTR)

sim-soc:                    ## cocotb SoC test (UART + machine-timer interrupts)
	python3 sim/cocotb/run_soc.py

formal:                     ## SymbiYosys: ALU equivalence + pipeline safety BMC
	bash flow/formal/run_formal.sh

# --- synthesis -------------------------------------------------------------
synth:                      ## generic Yosys synth/area (pipeline)
	mkdir -p $(BUILD) reports
	yosys -s tools/yosys/synth_pipeline.ys 2>&1 | tee reports/synth.log

synth-soc:                  ## generic Yosys synth/area (full SoC)
	mkdir -p $(BUILD) reports
	yosys -s tools/yosys/synth_soc.ys 2>&1 | tee reports/synth.log

synth-soc-macro:            ## hardening synth of soc_chip (RAM as a macro)
	mkdir -p $(BUILD) reports
	yosys -s tools/yosys/synth_soc_macro.ys 2>&1 | tee reports/synth_macro.log

synth-sky130:               ## map pipeline onto the real sky130 PDK
	bash tools/scripts/synth_sky130.sh riscv_pipeline

# --- physical (host stages: need PDK + heavy tools) ------------------------
sta:                        ## OpenSTA timing signoff
	bash flow/sta/run_sta.sh

pnr:                        ## OpenROAD/ORFS place & route -> GDSII
	bash flow/pnr/run_pnr.sh

drc:                        ## Magic/KLayout DRC on the routed GDSII
	bash flow/pnr/run_drc_lvs.sh

lvs:                        ## Netgen LVS (netlist vs layout)
	bash flow/pnr/run_drc_lvs.sh

# --- metrics ---------------------------------------------------------------
metrics:                    ## aggregate per-stage metrics -> reports/summary.json
	python3 scripts/metrics.py

clean:                      ## remove build artifacts
	rm -rf $(BUILD) sim_build *.vcd *.vvp reports/*.json reports/*.log
	rm -rf flow/formal/alu flow/formal/pipeline_safety
