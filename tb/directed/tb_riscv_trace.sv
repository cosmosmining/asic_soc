// tb_riscv_trace.sv - golden-trace differential test for the RISC-V core.
// Runs the DUT and an independent ISS (riscv_golden) on the same program and
// checks the DUT's RVFI-lite retire stream against the golden retire trace,
// in program order. Microarchitecture-independent: the SAME testbench validates
// the single-cycle core and the 5-stage pipeline.
//   default build -> riscv_core (single-cycle)
//   -DPIPELINE    -> riscv_pipeline (5-stage)
`timescale 1ns/1ps

module tb_riscv_trace;
    localparam int    XLEN  = 32;
    localparam int    WORDS = 1024;
    localparam string PROG  = "tb/directed/programs/test_core.hex";
`ifdef PIPELINE
    localparam string MODE = "PIPELINE";
`else
    localparam string MODE = "SINGLE-CYCLE";
`endif

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                       // 100 MHz

    // core <-> memory
    logic [XLEN-1:0] imem_addr, imem_rdata;
    logic [XLEN-1:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]      dmem_be;
    logic            dmem_we;
    logic [XLEN-1:0] dbg_pc;
    // RVFI-lite retire
    logic            rvfi_valid;
    logic [XLEN-1:0] rvfi_pc;
    logic [4:0]      rvfi_rd;
    logic            rvfi_we;
    logic [XLEN-1:0] rvfi_wdata;

`ifdef PIPELINE
    riscv_pipeline #(.XLEN(XLEN)) dut (
`else
    riscv_core #(.XLEN(XLEN)) dut (
`endif
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_addr, .dmem_wdata, .dmem_be, .dmem_we, .dmem_rdata,
        .dbg_pc,
        .rvfi_valid, .rvfi_pc, .rvfi_rd, .rvfi_we, .rvfi_wdata
    );

    // unified word-addressed memory, async read / sync byte-write
    logic [XLEN-1:0] mem [0:WORDS-1];
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

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0;
        $readmemh(PROG, mem);
    end

    // independent golden model (publishes gold.exp_* and gold.n_exp at t=0)
    riscv_golden #(.XLEN(XLEN), .WORDS(WORDS),
                   .PROG("tb/directed/programs/test_core.hex")) gold ();

    // ----------------------------------------------------- retire comparator
    int idx = 0, errors = 0;
    initial begin
        $dumpfile("tb_riscv_trace.vcd");
        $dumpvars(0, tb_riscv_trace);
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;

        forever begin
            @(posedge clk);
            if (rst_n && rvfi_valid) begin
                if (idx >= gold.n_exp) begin
                    // DUT retired more than expected before we stopped — ignore
                    // (halt self-loop keeps retiring); we already finished below.
                end else begin
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
                    if (idx == gold.n_exp) begin
                        report_and_finish();
                    end
                end
            end
        end
    end

    function void report_and_finish();
        $display("=== golden-trace differential test (%s) ===", MODE);
        $display("retired %0d/%0d instructions", idx, gold.n_exp);
        // architectural memory spot-check: store of x5(=74) at 0x100
        if (mem[256>>2] !== 32'd74) begin
            errors++;
            $display("  MISMATCH mem[0x100] = 0x%08x (expected 0x4a)", mem[256>>2]);
        end
        if (errors == 0) $display("RESULT: PASS (trace matched golden)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    endfunction

    // watchdog
    initial begin
        #200000;
        $display("RESULT: FAIL (timeout, idx=%0d/%0d)", idx, gold.n_exp);
        $finish;
    end
endmodule
