// tb_riscv_core.sv - directed smoke test for the single-cycle RV32IM core.
// Loads a hand-assembled program exercising ADD/SUB/ADDI/LUI-class ALU ops,
// a store+load round-trip, a taken branch, and an M-extension multiply, then
// checks the architectural register file against expected values.
`timescale 1ns/1ps

module tb_riscv_core;
    localparam int XLEN  = 32;
    localparam int WORDS = 1024;           // 4 KB unified memory

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;                   // 100 MHz

    // ----- core <-> memory wiring -----
    logic [XLEN-1:0] imem_addr, imem_rdata;
    logic [XLEN-1:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]      dmem_be;
    logic            dmem_we;
    logic [XLEN-1:0] dbg_pc;

    riscv_core #(.XLEN(XLEN)) dut (
        .clk, .rst_n,
        .imem_addr, .imem_rdata,
        .dmem_addr, .dmem_wdata, .dmem_be, .dmem_we, .dmem_rdata,
        .dbg_pc
    );

    // ----- unified word-addressed memory -----
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

    // ----- program -----
    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0000_0000;
        mem[0]  = 32'h00500093; // addi x1, x0, 5
        mem[1]  = 32'h02500113; // addi x2, x0, 37
        mem[2]  = 32'h002081B3; // add  x3, x1, x2     -> 42
        mem[3]  = 32'h40110233; // sub  x4, x2, x1     -> 32
        mem[4]  = 32'h10000293; // addi x5, x0, 256
        mem[5]  = 32'h00328023; // sw   x3, 0(x5)
        mem[6]  = 32'h0002A303; // lw   x6, 0(x5)      -> 42
        mem[7]  = 32'h00100393; // addi x7, x0, 1
        mem[8]  = 32'h00000463; // beq  x0, x0, +8     (taken)
        mem[9]  = 32'h06300393; // addi x7, x0, 99     (skipped)
        mem[10] = 32'h00700413; // addi x8, x0, 7      -> 7
        mem[11] = 32'h022084B3; // mul  x9, x1, x2     -> 185
        mem[12] = 32'h0000006F; // jal  x0, 0          (halt)
    end

    // ----- run + check -----
    int errors = 0;
    task automatic chk(input string name, input [XLEN-1:0] got, input [XLEN-1:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-6s = 0x%08x (expected 0x%08x)", name, got, exp);
            errors++;
        end else begin
            $display("  ok   %-6s = 0x%08x", name, got);
        end
    endtask

    initial begin
        $dumpfile("tb_riscv_core.vcd");
        $dumpvars(0, tb_riscv_core);
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;

        // let the program run to completion (settles on the halt loop)
        repeat (40) @(posedge clk);

        $display("=== RV32IM single-cycle core smoke test ===");
        chk("x1", dut.u_rf.regs[1], 32'd5);
        chk("x2", dut.u_rf.regs[2], 32'd37);
        chk("x3", dut.u_rf.regs[3], 32'd42);
        chk("x4", dut.u_rf.regs[4], 32'd32);
        chk("x5", dut.u_rf.regs[5], 32'd256);
        chk("x6", dut.u_rf.regs[6], 32'd42);
        chk("x7", dut.u_rf.regs[7], 32'd1);    // branch skipped the 99
        chk("x8", dut.u_rf.regs[8], 32'd7);
        chk("x9", dut.u_rf.regs[9], 32'd185);  // 5 * 37
        // memory[64] (= 0x100>>2) should hold the stored 42
        chk("mem", mem[256>>2], 32'd42);

        if (errors == 0) $display("RESULT: PASS (all checks)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    // watchdog
    initial begin
        #100000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
