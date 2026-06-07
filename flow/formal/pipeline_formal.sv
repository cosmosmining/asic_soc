// pipeline_formal.sv - bounded-model-check harness for the 5-stage pipeline.
//
// Drives the pipeline with free (anyseq) memory inputs, so the solver explores
// *all* instruction and load-data streams, and checks the existing safety SVA
// (PC/data-address word-alignment, stores assert a byte-enable, PC never X).
// rst_n is held low for the first step then released.
`include "riscv_defs.svh"

module pipeline_formal (
    input logic clk
);
    reg rst_done = 1'b0;
    always @(posedge clk) rst_done <= 1'b1;
    wire rst_n = rst_done;

    // arbitrary fetched instructions, load data, and memory readiness every
    // cycle -- so the proof covers any SRAM latency / stall pattern too.
    (* anyseq *) logic [31:0] imem_rdata;
    (* anyseq *) logic [31:0] dmem_rdata;
    (* anyseq *) logic        imem_ready;
    (* anyseq *) logic        dmem_ready;

    logic [31:0] imem_addr, dmem_addr, dmem_wdata, dbg_pc, rvfi_pc, rvfi_wdata;
    logic [3:0]  dmem_be;
    logic        dmem_we, rvfi_valid, rvfi_we;
    logic [4:0]  rvfi_rd;

    riscv_pipeline dut (
        .clk, .rst_n,
        .imem_addr, .imem_rdata, .imem_ready,
        .dmem_addr, .dmem_wdata, .dmem_be, .dmem_we, .dmem_rdata, .dmem_ready,
        .sw_irq(1'b0), .timer_irq(1'b0), .ext_irq(1'b0),
        .dbg_pc, .rvfi_valid, .rvfi_pc, .rvfi_rd, .rvfi_we, .rvfi_wdata
    );

    // the proven safety properties (yosys-friendly form of riscv_core_sva)
    pipeline_safety_props u_sva (
        .clk, .rst_n,
        .imem_addr, .dmem_addr, .dmem_be, .dmem_we
    );
endmodule
