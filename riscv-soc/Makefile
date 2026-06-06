# riscv-soc track — RTL build/lint/sim/formal.
SHELL := /bin/bash
.DEFAULT_GOAL := all

BUILD   := build
IVFLAGS := -g2012 -gsupported-assertions

FIFO_RTL := rtl/async_fifo.sv rtl/sync_2ff.sv
SOC_RTL  := rtl/soc_top.sv rtl/axil_arbiter.sv rtl/axil_xbar.sv rtl/axil_sram.sv \
            rtl/axil_uart.sv rtl/axil_timer.sv rtl/dma_engine.sv

.PHONY: all lint sim fifo axil soc dma formal clean
all: lint sim formal

lint: ## Verilator lint-only, all RTL (must be clean)
	verilator --lint-only -Wall --top-module async_fifo $(FIFO_RTL)
	verilator --lint-only -Wall --top-module soc_top $(SOC_RTL)

sim: fifo axil soc dma ## run all block + integration sims

fifo: ## async FIFO dual-clock self-checking sim
	@mkdir -p $(BUILD)
	iverilog $(IVFLAGS) -o $(BUILD)/tb_async_fifo.vvp tb/tb_async_fifo.sv $(FIFO_RTL)
	@vvp $(BUILD)/tb_async_fifo.vvp | grep -E "RESULT|ERROR|MISMATCH"

axil: ## AXI4-Lite slave directed test (handshake + byte strobes)
	@mkdir -p $(BUILD)
	iverilog $(IVFLAGS) -o $(BUILD)/tb_axil_one.vvp tb/tb_axil_one.sv rtl/axil_sram.sv
	@vvp $(BUILD)/tb_axil_one.vvp | grep -E "RESULT|ERR|MISMATCH"

soc: ## integrated SoC fabric sim (xbar + ROM/SRAM/UART/timer)
	@mkdir -p $(BUILD)
	iverilog $(IVFLAGS) -o $(BUILD)/tb_soc.vvp tb/tb_soc.sv $(SOC_RTL)
	@vvp $(BUILD)/tb_soc.vvp | grep -E "RESULT|ROM|SRAM|UART|MTIME|timer"

dma: ## DMA + round-robin arbiter sim (1-ch + 2-ch concurrent copy)
	@mkdir -p $(BUILD)
	iverilog $(IVFLAGS) -o $(BUILD)/tb_dma.vvp tb/tb_dma.sv $(SOC_RTL)
	@vvp $(BUILD)/tb_dma.vvp | grep -E "RESULT|A:|B0|B1|DMA"

formal: ## formal proof of FIFO Gray-pointer invariants (yosys + smtbmc + z3)
	bash formal/run_gray_proof.sh

synth: ## generic Yosys synthesis + latch-free check per fabric block
	bash syn/synth_check.sh

clean:
	rm -rf $(BUILD) obj_dir *.vcd
