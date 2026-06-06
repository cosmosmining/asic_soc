// tb_dma - exercises the 2-channel DMA + round-robin arbiter. The external
// master fills an SRAM source region, programs the DMA over the bus, starts it,
// polls status, and verifies the destination region. Two concurrent channels
// test the DMA's internal round-robin (and the top arbiter, since the external
// master polls while the DMA master is moving data).
`timescale 1ns/1ps
module tb_dma;
    localparam SRAM = 32'h1000_0000;
    localparam DMA  = 32'h4000_0000;   // ch c regs at +c*0x10: +0 SRC +4 DST +8 LEN +C CTRL

    logic        clk = 0, rst_n = 0;
    logic [31:0] m_awaddr = 0; logic m_awvalid = 0; logic m_awready;
    logic [31:0] m_wdata = 0;  logic [3:0] m_wstrb = 0; logic m_wvalid = 0; logic m_wready;
    logic [1:0]  m_bresp;      logic m_bvalid; logic m_bready = 0;
    logic [31:0] m_araddr = 0; logic m_arvalid = 0; logic m_arready;
    logic [31:0] m_rdata;      logic [1:0] m_rresp; logic m_rvalid; logic m_rready = 0;
    logic        uart_tx, timer_irq;
    int errors = 0;

    soc_top #(.SRAM_WORDS(4096)) dut (.*);
    always #5 clk = ~clk;

    task automatic axi_write(input [31:0] a, input [31:0] d);
        bit done = 0;
        @(posedge clk);
        m_awaddr <= a; m_wdata <= d; m_wstrb <= 4'hf; m_awvalid <= 1; m_wvalid <= 1; m_bready <= 1;
        while (!done) begin
            @(posedge clk);
            if (m_awready) m_awvalid <= 0;
            if (m_wready)  m_wvalid  <= 0;
            if (m_bvalid) begin m_bready <= 0; done = 1; end
        end
    endtask
    task automatic axi_read(input [31:0] a, output [31:0] d);
        bit done = 0;
        @(posedge clk);
        m_araddr <= a; m_arvalid <= 1; m_rready <= 1;
        while (!done) begin
            @(posedge clk);
            if (m_arready) m_arvalid <= 0;
            if (m_rvalid) begin d = m_rdata; m_rready <= 0; done = 1; end
        end
    endtask

    task automatic dma_prog(input int ch, input [31:0] src, input [31:0] dst, input [31:0] nwords);
        axi_write(DMA + ch*32'h10 + 32'h0, src);
        axi_write(DMA + ch*32'h10 + 32'h4, dst);
        axi_write(DMA + ch*32'h10 + 32'h8, nwords);
        axi_write(DMA + ch*32'h10 + 32'hC, 32'h1);   // start
    endtask

    task automatic dma_wait(input int ch);
        logic [31:0] st; int guard = 0;
        st = 32'h1;
        while (st[0] && guard < 5000) begin axi_read(DMA + ch*32'h10 + 32'hC, st); guard++; end
        if (st[0]) begin $display("  DMA ch%0d never finished", ch); errors++; end
    endtask

    logic [31:0] rd;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;

        // ---- Test A: single-channel copy (8 words) ----
        for (int i = 0; i < 8; i++) axi_write(SRAM + 32'h000 + i*4, 32'hA000 + i);
        dma_prog(0, SRAM + 32'h000, SRAM + 32'h100, 8);
        dma_wait(0);
        for (int i = 0; i < 8; i++) begin
            axi_read(SRAM + 32'h100 + i*4, rd);
            if (rd !== (32'hA000 + i)) begin $display("  A: dst[%0d]=%08h exp %08h", i, rd, 32'hA000+i); errors++; end
        end

        // ---- Test B: two channels concurrent (round-robin) ----
        for (int i = 0; i < 6; i++) axi_write(SRAM + 32'h200 + i*4, 32'hB000 + i);
        for (int i = 0; i < 6; i++) axi_write(SRAM + 32'h400 + i*4, 32'hC000 + i);
        dma_prog(0, SRAM + 32'h200, SRAM + 32'h300, 6);
        dma_prog(1, SRAM + 32'h400, SRAM + 32'h500, 6);   // both active -> interleaved
        dma_wait(0); dma_wait(1);
        for (int i = 0; i < 6; i++) begin
            axi_read(SRAM + 32'h300 + i*4, rd);
            if (rd !== (32'hB000 + i)) begin $display("  B0: dst[%0d]=%08h exp %08h", i, rd, 32'hB000+i); errors++; end
            axi_read(SRAM + 32'h500 + i*4, rd);
            if (rd !== (32'hC000 + i)) begin $display("  B1: dst[%0d]=%08h exp %08h", i, rd, 32'hC000+i); errors++; end
        end

        if (errors == 0) $display("RESULT: PASS (DMA: 1-ch + 2-ch concurrent copy via arbiter)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #2000000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
