// tb_soc.sv - thin cocotb wrapper around soc_top (async or synchronous RAM).
//
// cocotb attaches here: it drives clk/rst_n and observes the UART line, GPIO
// outputs and RVFI retire stream. The firmware image is loaded into the SoC RAM
// from the +PROG=<hex> plusarg at time 0. SYNC selects the synchronous
// (compiled-SRAM-style) RAM so the same test also exercises the memory-wait.
`timescale 1ns/1ps

module tb_soc #(
    parameter int RAM_WORDS = 4096,
    parameter int UART_DIV  = 8,        // small divisor -> fast sim
    parameter int TICK_DIV  = 1,
    parameter int SYNC      = 0         // 1 = synchronous RAM (memory-wait path)
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        uart_tx,
    output logic        uart_tx_strobe,
    output logic [7:0]  uart_tx_byte,
    output logic [31:0] gpio_out,
    output logic        dbg_timer_irq,
    output logic [31:0] dbg_pc,
    output logic        rvfi_valid,
    output logic [31:0] rvfi_pc
);
    logic [31:0] gpio_in = 32'h0;

    soc_top #(
        .RAM_WORDS(RAM_WORDS), .UART_DIV(UART_DIV), .TICK_DIV(TICK_DIV), .SYNC_MEM(SYNC)
    ) dut (
        .clk, .rst_n,
        .gpio_out, .gpio_in,
        .uart_tx, .uart_tx_strobe, .uart_tx_byte,
        .dbg_timer_irq, .dbg_pc,
        .rvfi_valid, .rvfi_pc,
        .rvfi_rd(), .rvfi_we(), .rvfi_wdata()
    );

    // load firmware into whichever RAM the generate selected
    string prog;
    generate
        if (SYNC != 0) begin : g_load_sync
            initial if ($value$plusargs("PROG=%s", prog))
                $readmemh(prog, dut.g_sync_ram.u_ram.mem);
        end else begin : g_load_async
            initial if ($value$plusargs("PROG=%s", prog))
                $readmemh(prog, dut.g_async_ram.u_ram.mem);
        end
    endgenerate
endmodule
