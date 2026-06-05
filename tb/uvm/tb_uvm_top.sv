// tb_uvm_top.sv - UVM top for the RV32IM CPU.
// Instantiates the pipeline DUT + unified memory + interface, registers the vif
// in the config DB, and launches the UVM test. Run on a UVM-capable simulator:
//   vcs   -sverilog -ntb_opts uvm-1.2 +incdir+rtl/common rtl/.../*.sv \
//         tb/uvm/riscv_if.sv tb/uvm/riscv_uvm_pkg.sv tb/uvm/tb_uvm_top.sv \
//         +UVM_TESTNAME=riscv_random_test
//   (Questa: qrun -uvm ... ;  or paste into EDA Playground with UVM 1.2.)
`timescale 1ns/1ps
`include "riscv_defs.svh"

module tb_uvm_top;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import riscv_uvm_pkg::*;

    localparam int XLEN = 32, WORDS = 1024;

    logic clk = 0;
    always #5 clk = ~clk;

    riscv_if #(.XLEN(XLEN)) vif (.clk(clk));

    // unified word-addressed memory (backdoor-loaded by the driver)
    logic [XLEN-1:0] mem [0:WORDS-1];

    // DUT <-> memory
    logic [XLEN-1:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]      dmem_be;
    logic            dmem_we;
    logic [XLEN-1:0] dbg_pc;

    assign imem_rdata = mem[imem_addr[XLEN-1:2]];
    assign dmem_rdata = mem[dmem_addr[XLEN-1:2]];
    always_ff @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_be[0]) mem[dmem_addr[XLEN-1:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_be[1]) mem[dmem_addr[XLEN-1:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_be[2]) mem[dmem_addr[XLEN-1:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_be[3]) mem[dmem_addr[XLEN-1:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    riscv_pipeline #(.XLEN(XLEN)) dut (
        .clk(clk), .rst_n(vif.rst_n),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_be(dmem_be), .dmem_we(dmem_we), .dmem_rdata(dmem_rdata),
        .dbg_pc(dbg_pc),
        .rvfi_valid(vif.rvfi_valid), .rvfi_pc(vif.rvfi_pc), .rvfi_rd(vif.rvfi_rd),
        .rvfi_we(vif.rvfi_we), .rvfi_wdata(vif.rvfi_wdata)
    );

    initial begin
        uvm_config_db#(virtual riscv_if)::set(null, "*", "vif", vif);
        run_test("riscv_random_test");
    end
endmodule
