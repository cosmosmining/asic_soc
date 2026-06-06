// tb_soc - directed AXI4-Lite master test of the SoC fabric: boot ROM read,
// SRAM read/write, ROM-write SLVERR, UART (decoded by a real RX in the TB), and
// the timer (count + compare interrupt). One master exercises all four slaves
// through the crossbar.
`timescale 1ns/1ps
module tb_soc;
    localparam int UART_CLKS = 16;
    localparam     BIT_NS    = UART_CLKS * 10;   // clk period is 10 ns

    logic        clk = 0, rst_n = 0;
    logic [31:0] m_awaddr = 0; logic m_awvalid = 0; logic m_awready;
    logic [31:0] m_wdata = 0;  logic [3:0] m_wstrb = 0; logic m_wvalid = 0; logic m_wready;
    logic [1:0]  m_bresp;      logic m_bvalid; logic m_bready = 0;
    logic [31:0] m_araddr = 0; logic m_arvalid = 0; logic m_arready;
    logic [31:0] m_rdata;      logic [1:0] m_rresp; logic m_rvalid; logic m_rready = 0;
    logic        uart_tx, timer_irq;

    logic [1:0]  last_bresp, last_rresp;
    int errors = 0;

    soc_top #(.ROM_INIT("tb/programs/rom_init.hex"), .UART_CLKS(UART_CLKS)) dut (.*);

    always #5 clk = ~clk;

    // ---------- AXI master ----------
    task automatic axi_write(input [31:0] a, input [31:0] d, input [3:0] strb);
        bit done = 0;
        @(posedge clk);
        m_awaddr <= a; m_wdata <= d; m_wstrb <= strb; m_awvalid <= 1; m_wvalid <= 1; m_bready <= 1;
        while (!done) begin
            @(posedge clk);
            if (m_awready) m_awvalid <= 0;
            if (m_wready)  m_wvalid  <= 0;
            if (m_bvalid) begin last_bresp = m_bresp; m_bready <= 0; done = 1; end
        end
    endtask

    task automatic axi_read(input [31:0] a, output [31:0] d);
        bit done = 0;
        @(posedge clk);
        m_araddr <= a; m_arvalid <= 1; m_rready <= 1;
        while (!done) begin
            @(posedge clk);
            if (m_arready) m_arvalid <= 0;
            if (m_rvalid) begin d = m_rdata; last_rresp = m_rresp; m_rready <= 0; done = 1; end
        end
    endtask

    // ---------- background UART receiver (decodes uart_tx, 8N1) ----------
    logic [7:0] rx_q [$];
    initial begin
        logic [7:0] b;
        forever begin
            @(negedge uart_tx);          // start bit
            #(BIT_NS*3/2);               // to middle of bit0
            for (int i = 0; i < 8; i++) begin b[i] = uart_tx; #(BIT_NS); end
            rx_q.push_back(b);
        end
    end

    // ---------- test ----------
    logic [31:0] rd;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;

        // boot ROM (read-only, preloaded)
        axi_read(32'h0000_0000, rd); if (rd !== 32'hDEADBEEF) begin $display("  ROM[0]=%08h exp DEADBEEF", rd); errors++; end
        axi_read(32'h0000_0008, rd); if (rd !== 32'h12345678) begin $display("  ROM[2]=%08h exp 12345678", rd); errors++; end

        // SRAM read/write
        axi_write(32'h1000_0010, 32'hCAFEBABE, 4'hf);
        axi_read (32'h1000_0010, rd); if (rd !== 32'hCAFEBABE) begin $display("  SRAM rw=%08h", rd); errors++; end

        // write to ROM must report SLVERR
        axi_write(32'h0000_0000, 32'h0, 4'hf);
        if (last_bresp !== 2'b10) begin $display("  ROM write bresp=%0d exp 2 (SLVERR)", last_bresp); errors++; end

        // UART: send "Hi", decode the serial line in the TB
        axi_write(32'h2000_0000, 32'h48, 4'hf);   // 'H'
        repeat (UART_CLKS*12) @(posedge clk);      // let it finish (10 bit-times)
        axi_write(32'h2000_0000, 32'h69, 4'hf);   // 'i'
        repeat (UART_CLKS*12) @(posedge clk);
        if (rx_q.size() < 2) begin $display("  UART got %0d bytes exp 2", rx_q.size()); errors++; end
        else begin
            if (rx_q[0] !== 8'h48) begin $display("  UART[0]=%02h exp 48", rx_q[0]); errors++; end
            if (rx_q[1] !== 8'h69) begin $display("  UART[1]=%02h exp 69", rx_q[1]); errors++; end
        end

        // timer: set compare, enable, wait for interrupt
        axi_write(32'h3000_0008, 32'd20, 4'hf);   // MTIMECMP
        axi_write(32'h3000_0004, 32'd1,  4'hf);   // CTRL enable
        repeat (40) @(posedge clk);
        axi_read(32'h3000_0000, rd);              // MTIME should be advancing
        if (rd < 32'd20) begin $display("  MTIME=%0d (expected >=20)", rd); errors++; end
        if (timer_irq !== 1'b1) begin $display("  timer_irq not asserted"); errors++; end

        if (errors == 0) $display("RESULT: PASS (SoC fabric: ROM/SRAM/SLVERR/UART/timer via xbar)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #500000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
