// tb_riscv_sync.sv - differential test of the pipeline against a *synchronous*
// (registered-read) memory with the imem_ready/dmem_ready handshake.
//
// Same golden-trace check as tb_riscv_trace, but the memory answers one cycle
// late (like a compiled SRAM), so this exercises the pipeline's memory-wait
// stalls (if_wait on fetch, mem_wait on load). The golden ISS is timing-
// independent, so a correct pipeline must retire the identical stream -- only
// slower. Pipeline only (the single-cycle core uses async memory).
`timescale 1ns/1ps

module tb_riscv_sync;
    localparam int    XLEN  = 32;
    localparam int    WORDS = 1024;
    localparam int    AW    = $clog2(WORDS);
    localparam string PROG  = "tb/directed/programs/test_core.hex";

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [XLEN-1:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]      dmem_be;
    logic            dmem_we, imem_ready, dmem_ready;
    logic [XLEN-1:0] dbg_pc;
    logic            rvfi_valid, rvfi_we;
    logic [XLEN-1:0] rvfi_pc, rvfi_wdata;
    logic [4:0]      rvfi_rd;

    riscv_pipeline #(.XLEN(XLEN)) dut (
        .clk, .rst_n,
        .imem_addr, .imem_rdata, .imem_ready,
        .dmem_addr, .dmem_wdata, .dmem_be, .dmem_we, .dmem_rdata, .dmem_ready,
        .sw_irq(1'b0), .timer_irq(1'b0), .ext_irq(1'b0),
        .dbg_pc, .rvfi_valid, .rvfi_pc, .rvfi_rd, .rvfi_we, .rvfi_wdata
    );

    // ---- synchronous unified memory: registered read, sync byte write -------
    logic [XLEN-1:0] mem [0:WORDS-1];
    logic [XLEN-1:0] iaddr_q, daddr_q;
    initial begin imem_rdata = '0; dmem_rdata = '0; iaddr_q = '1; daddr_q = '1; end

    always_ff @(posedge clk) begin
        imem_rdata <= mem[imem_addr[AW+1:2]];   // 1-cycle read latency
        dmem_rdata <= mem[dmem_addr[AW+1:2]];
        iaddr_q    <= imem_addr;
        daddr_q    <= dmem_addr;
        if (dmem_we) begin
            if (dmem_be[0]) mem[dmem_addr[AW+1:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_be[1]) mem[dmem_addr[AW+1:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_be[2]) mem[dmem_addr[AW+1:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_be[3]) mem[dmem_addr[AW+1:2]][31:24] <= dmem_wdata[31:24];
        end
    end
    // data for the presented address is valid once that address has been stable
    // for a cycle (its registered read has landed).
    assign imem_ready = rst_n && (imem_addr == iaddr_q);
    assign dmem_ready = rst_n && (dmem_addr == daddr_q);

    integer i;
    string  progfile;
    bit     default_prog;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0;
        default_prog = !$value$plusargs("PROG=%s", progfile);
        if (default_prog) progfile = PROG;
        $readmemh(progfile, mem);
    end

    riscv_golden #(.XLEN(XLEN), .WORDS(WORDS),
                   .PROG("tb/directed/programs/test_core.hex")) gold ();

    // ----------------------------------------------------- retire comparator
    int idx = 0, errors = 0, cycles = 0;
    initial begin
        rst_n = 0;
        repeat (3) @(posedge clk);
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
        $display("=== golden-trace SYNC-memory test ===");
        $display("retired %0d/%0d instructions", idx, gold.n_exp);
        if (idx > 0)
            $display("PERF: %0d cycles, %0d retired, CPI=%0.3f",
                     cycles, idx, real'(cycles) / real'(idx));
        if (default_prog && mem[256>>2] !== 32'd74) begin
            errors++;
            $display("  MISMATCH mem[0x100] = 0x%08x (expected 0x4a)", mem[256>>2]);
        end
        if (errors == 0) $display("RESULT: PASS (sync-memory trace matched golden)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    endfunction

    initial begin
        #400000;
        $display("RESULT: FAIL (timeout, idx=%0d/%0d)", idx, gold.n_exp);
        $finish;
    end
endmodule
