// tb_soc.sv - end-to-end SoC differential test.
// Runs a program through the full hierarchy (pipeline -> I$/D$ -> AXI4-Lite
// interconnect -> SRAM) and checks the RVFI retire stream against the same
// independent golden ISS used for the bare-core tests. Proves the memory
// subsystem is functionally transparent: instructions and data flow correctly
// through the caches and AXI fabric, cold-miss fills and write-throughs included.
`timescale 1ns/1ps

module tb_soc;
    localparam int    XLEN  = 32;
    localparam int    WORDS = 4096;
    localparam string PROG  = "tb/directed/programs/test_core.hex";

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                       // 100 MHz

    logic [XLEN-1:0] dbg_pc;
    logic            rvfi_valid;
    logic [XLEN-1:0] rvfi_pc;
    logic [4:0]      rvfi_rd;
    logic            rvfi_we;
    logic [XLEN-1:0] rvfi_wdata;

    riscv_soc #(.XLEN(XLEN), .MEM_WORDS(WORDS)) dut (
        .clk, .rst_n, .dbg_pc,
        .rvfi_valid, .rvfi_pc, .rvfi_rd, .rvfi_we, .rvfi_wdata
    );

    // load the program image directly into the SRAM
    integer i;
    string  progfile;
    bit     default_prog;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) dut.u_sram.mem[i] = 32'h0;
        default_prog = !$value$plusargs("PROG=%s", progfile);
        if (default_prog) progfile = PROG;
        $readmemh(progfile, dut.u_sram.mem);
    end

    // independent golden model on the same program
    riscv_golden #(.XLEN(XLEN), .WORDS(WORDS),
                   .PROG("tb/directed/programs/test_core.hex")) gold ();

    // ----------------------------------------------------- retire comparator
    int idx = 0, errors = 0, cycles = 0;
    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        forever begin
            @(posedge clk);
            if (rst_n) cycles++;
            if (rst_n && rvfi_valid) begin
                if (idx < gold.n_exp) begin
                    if (rvfi_pc !== gold.exp_pc[idx] ||
                        rvfi_we !== gold.exp_we[idx] ||
                        (rvfi_we && (rvfi_rd    !== gold.exp_rd[idx])) ||
                        (rvfi_we && (rvfi_wdata !== gold.exp_wd[idx]))) begin
                        errors++;
                        $display("  MISMATCH @retire %0d", idx);
                        $display("    DUT   : pc=0x%08x we=%b rd=x%0d wd=0x%08x",
                                 rvfi_pc, rvfi_we, rvfi_rd, rvfi_wdata);
                        $display("    GOLDEN: pc=0x%08x we=%b rd=x%0d wd=0x%08x",
                                 gold.exp_pc[idx], gold.exp_we[idx],
                                 gold.exp_rd[idx], gold.exp_wd[idx]);
                    end
                    idx++;
                    if (idx == gold.n_exp) report_and_finish();
                end
            end
        end
    end

    function void report_and_finish();
        $display("=== SoC differential test (pipeline + I$/D$ + AXI4-Lite SRAM) ===");
        $display("retired %0d/%0d instructions in %0d cycles (CPI=%0.3f incl. cache misses)",
                 idx, gold.n_exp, cycles, real'(cycles)/real'(idx));
        if (errors == 0) $display("RESULT: PASS (trace matched golden through the cache/AXI hierarchy)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    endfunction

    // watchdog (caches + AXI add fill/write-through latency, so allow more time)
    initial begin
        #2000000;
        $display("RESULT: FAIL (timeout, idx=%0d/%0d)", idx, gold.n_exp);
        $finish;
    end
endmodule
