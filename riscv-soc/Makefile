# riscv-soc track — RTL build/lint/sim.
SHELL := /bin/bash
.DEFAULT_GOAL := all

BUILD := build
IVFLAGS := -g2012 -gsupported-assertions

# block -> (rtl files, tb)
FIFO_RTL := rtl/async_fifo.sv rtl/sync_2ff.sv

.PHONY: all lint sim fifo formal clean
all: lint sim formal

lint: ## Verilator lint-only, all RTL blocks (must be clean)
	verilator --lint-only -Wall --top-module async_fifo $(FIFO_RTL)

sim: fifo ## run all block sims

fifo: ## async FIFO dual-clock self-checking sim
	@mkdir -p $(BUILD)
	iverilog $(IVFLAGS) -o $(BUILD)/tb_async_fifo.vvp tb/tb_async_fifo.sv $(FIFO_RTL)
	@vvp $(BUILD)/tb_async_fifo.vvp | grep -E "RESULT|ERROR|MISMATCH"

formal: ## formal proof of FIFO Gray-pointer invariants (yosys + smtbmc + z3)
	bash formal/run_gray_proof.sh

clean:
	rm -rf $(BUILD) obj_dir *.vcd
