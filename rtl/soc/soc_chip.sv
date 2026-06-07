// soc_chip.sv - chip-level top for hardening (synthesis/PnR boundary).
//
// Wraps soc_top with the things a real tapeout boundary needs and the flow
// hardens against:
//   * a reset synchroniser: the external rst_n is asserted asynchronously but
//     de-asserted synchronously to clk, so no flop leaves reset on a recovery
//     violation (the internal core reset is clean);
//   * a fixed, PnR-tractable RAM size (compiled SRAM macro or inline flops);
//   * a narrow, pad-friendly top-level port list.
//
// Functionally identical to soc_top; the differential/cocotb verification runs
// on soc_top directly. This module is the place & route target (flow/pnr).
module soc_chip #(
    parameter int RAM_WORDS = 1024,       // 4 KiB -- tractable for a sky130 harden
    parameter int GPIO_W    = 8,
    parameter int UART_DIV  = 868,        // 50 MHz / 115200 baud
    parameter int SYNC_MEM  = 1           // 1 = synchronous RAM (compiled SRAM macro)
) (
    input  logic              clk,
    input  logic              rst_n,      // async assert, external
    output logic              uart_tx,
    output logic [GPIO_W-1:0] gpio_out,
    input  logic [GPIO_W-1:0] gpio_in
);
    // ---- reset synchroniser (async assert, sync de-assert) -----------------
    logic rst_meta, rst_sync_n;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rst_meta <= 1'b0; rst_sync_n <= 1'b0; end
        else        begin rst_meta <= 1'b1; rst_sync_n <= rst_meta; end
    end

    // ---- SoC ---------------------------------------------------------------
    soc_top #(
        .RAM_WORDS(RAM_WORDS), .UART_DIV(UART_DIV), .GPIO_W(GPIO_W), .SYNC_MEM(SYNC_MEM)
    ) u_soc (
        .clk, .rst_n(rst_sync_n),
        .gpio_out(gpio_out), .gpio_in(gpio_in),
        .uart_tx(uart_tx),
        .uart_tx_strobe(/* unused at chip top */),
        .uart_tx_byte(/* unused at chip top */),
        .dbg_timer_irq(/* unused */),
        .dbg_pc(/* unused */),
        .rvfi_valid(/* unused */), .rvfi_pc(/* unused */),
        .rvfi_rd(/* unused */), .rvfi_we(/* unused */), .rvfi_wdata(/* unused */)
    );
endmodule
