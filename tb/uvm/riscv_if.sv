// riscv_if.sv - UVM interface to the CPU DUT.
// Bundles the clock/reset, the RVFI-lite retire bus the monitor samples, and a
// backdoor handle the driver uses to load a generated program into instruction
// memory before a run. (The memory itself lives in the TB top.)
interface riscv_if #(parameter int XLEN = 32) (input logic clk);
    logic            rst_n;

    // RVFI-lite retire (sampled by the monitor)
    logic            rvfi_valid;
    logic [XLEN-1:0] rvfi_pc;
    logic [4:0]      rvfi_rd;
    logic            rvfi_we;
    logic [XLEN-1:0] rvfi_wdata;

    // backdoor program memory access (driven by the driver / read by scoreboard)
    // Implemented by the TB top via these hooks.
    function automatic void mem_write(input int word_addr, input logic [XLEN-1:0] data);
        tb_uvm_top.mem[word_addr] = data;
    endfunction
    function automatic logic [XLEN-1:0] mem_read(input int word_addr);
        return tb_uvm_top.mem[word_addr];
    endfunction

    // monitor clocking: sample retire on the rising edge
    clocking mon_cb @(posedge clk);
        input rvfi_valid, rvfi_pc, rvfi_rd, rvfi_we, rvfi_wdata;
    endclocking
endinterface
