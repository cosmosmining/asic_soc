// soc_map.svh - SoC physical memory map (single source of truth).
//
// The CPU presents word-aligned byte addresses on imem (fetch) and dmem
// (load/store). Instruction fetches always target RAM; data accesses are
// decoded to RAM or one of the memory-mapped peripherals below. The CLINT
// follows the standard RISC-V layout so machine-timer firmware is portable.
`ifndef SOC_MAP_SVH
`define SOC_MAP_SVH

// Region decode uses addr[31:16] (a 64 KiB page granularity).
`define RAM_PAGE        16'h0000         // 0x0000_xxxx -> RAM
`define CLINT_PAGE      16'h0200         // 0x0200_xxxx -> CLINT
`define UART_PAGE       16'h1000         // 0x1000_xxxx -> UART
`define GPIO_PAGE       16'h1001         // 0x1001_xxxx -> GPIO

// ---- RAM: code + data, single-cycle (base 0x0000_0000, size = RAM_WORDS*4) --
`define RAM_BASE        32'h0000_0000

// ---- CLINT (core-local interruptor): machine timer + software interrupt -----
`define CLINT_BASE      32'h0200_0000   // decoded by addr[31:16] == 0x0200
`define CLINT_MSIP      16'h0000         // +0x0000  msip      (sw interrupt)
`define CLINT_MTIMECMP  16'h4000         // +0x4000  mtimecmp  [31:0]
`define CLINT_MTIMECMPH 16'h4004         // +0x4004  mtimecmp  [63:32]
`define CLINT_MTIME     16'hBFF8         // +0xBFF8  mtime     [31:0]
`define CLINT_MTIMEH    16'hBFFC         // +0xBFFC  mtime     [63:32]

// ---- UART (TX only) ---------------------------------------------------------
`define UART_BASE       32'h1000_0000   // decoded by addr[31:16] == 0x1000
`define UART_TXDATA     16'h0000         // +0x00  W: enqueue byte / R: last byte
`define UART_STATUS     16'h0004         // +0x04  R: bit0 = tx_busy

// ---- GPIO -------------------------------------------------------------------
`define GPIO_BASE       32'h1001_0000   // decoded by addr[31:16] == 0x1001
`define GPIO_OUT        16'h0000         // +0x00  R/W: output drive
`define GPIO_IN         16'h0004         // +0x04  R:   sampled inputs

`endif
