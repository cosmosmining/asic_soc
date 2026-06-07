# config_soc.mk - ORFS configuration to harden the full SoC (soc_chip) to GDSII.
#
#   make DESIGN_CONFIG=flow/pnr/config_soc.mk
#
# Default: the on-chip RAM is a small inline flop array (soc_chip RAM_WORDS=1024),
# so this is self-contained -- no separate macro generation, functionally exactly
# what the cocotb test verifies. For a smaller die, swap the RAM for a compiled
# SRAM macro (OpenRAM 1rw1r / DFFRAM): blackbox soc_ram, add its LEF/LIB via
# ADDITIONAL_LEFS / *_LIB, and place it with macro placement. See docs/HARDENING.md.
export PLATFORM            = sky130hd
export DESIGN_NAME         = soc_chip

export VERILOG_FILES = $(sort \
    $(wildcard ./rtl/cpu_riscv/regfile.sv ./rtl/cpu_riscv/csr.sv \
               ./rtl/cpu_riscv/alu.sv ./rtl/cpu_riscv/divider.sv \
               ./rtl/cpu_riscv/mul_seq.sv ./rtl/cpu_riscv/riscv_pipeline.sv) \
    $(wildcard ./rtl/soc/*.sv))
export SDC_FILE      = ./flow/sta/soc_chip.sdc

# Flop-heavy (inline RAM) -> give placement room and let global route adjust.
export CORE_UTILIZATION    = 35
export CORE_ASPECT_RATIO   = 1
export CORE_MARGIN         = 2
export PLACE_DENSITY       = 0.50
export GRT_ALLOW_CONGESTION = 1

export CLOCK_PORT          = clk
export CLOCK_PERIOD        = 20.0    # 50 MHz, matching the gds_flow baseline
