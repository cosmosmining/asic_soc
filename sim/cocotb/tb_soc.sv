// tb_soc.sv - thin cocotb wrapper around soc_top.
//
// cocotb attaches to this module: it drives clk/rst_n and observes the UART
// line, GPIO outputs and RVFI retire stream. The firmware image is loaded into
// the SoC RAM from the +PROG=<hex> plusarg at time 0 (hierarchical $readmemh).
`timescale 1ns/1ps

module tb_soc #(
    parameter int RAM_WORDS = 4096,
    parameter int UART_DIV  = 8,        // small divisor -> fast sim
    parameter int TICK_DIV  = 1
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
        .RAM_WORDS(RAM_WORDS), .UART_DIV(UART_DIV), .TICK_DIV(TICK_DIV)
    ) dut (
        .clk, .rst_n,
        .gpio_out, .gpio_in,
        .uart_tx, .uart_tx_strobe, .uart_tx_byte,
        .dbg_timer_irq, .dbg_pc,
        .rvfi_valid, .rvfi_pc,
        .rvfi_rd(), .rvfi_we(), .rvfi_wdata()
    );

    string prog;
    initial begin
        if ($value$plusargs("PROG=%s", prog))
            $readmemh(prog, dut.u_ram.mem);
    end
endmodule
