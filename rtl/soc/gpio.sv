// gpio.sv - memory-mapped general-purpose I/O.
//
// GPIO_OUT is a readable/writable output-drive register. GPIO_IN reads the
// external inputs through a two-flop synchroniser (the pins are asynchronous to
// the core clock -- this is the standard CDC guard for sampling them safely).
`include "soc_map.svh"

module gpio #(
    parameter int W = 32
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         sel,
    input  logic         we,
    input  logic [15:0]  offs,
    input  logic [31:0]  wdata,
    output logic [31:0]  rdata,
    output logic [W-1:0] gpio_out,
    input  logic [W-1:0] gpio_in
);
    // two-flop input synchroniser (CDC: async pins -> core clock domain)
    logic [W-1:0] in_meta, in_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin in_meta <= '0; in_sync <= '0; end
        else        begin in_meta <= gpio_in; in_sync <= in_meta; end
    end

    always_comb begin
        unique case (offs)
            `GPIO_OUT: rdata = 32'(gpio_out);     // zero-extend when W < 32
            `GPIO_IN : rdata = 32'(in_sync);
            default  : rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                              gpio_out <= '0;
        else if (sel && we && offs == `GPIO_OUT) gpio_out <= wdata[W-1:0];
    end
endmodule
