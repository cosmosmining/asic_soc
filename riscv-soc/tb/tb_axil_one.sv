// tb_axil_one - directed AXI4-Lite master test for axil_sram (locks down the
// handshake convention reused by every peripheral + the crossbar).
`timescale 1ns/1ps
module tb_axil_one;
    logic        clk = 0, rst_n = 0;
    logic [31:0] awaddr = 0;  logic awvalid = 0;  logic awready;
    logic [31:0] wdata  = 0;  logic [3:0] wstrb = 0; logic wvalid = 0; logic wready;
    logic [1:0]  bresp;       logic bvalid;        logic bready = 0;
    logic [31:0] araddr = 0;  logic arvalid = 0;   logic arready;
    logic [31:0] rdata;       logic [1:0] rresp;   logic rvalid; logic rready = 0;
    int errors = 0;

    axil_sram #(.DEPTH_WORDS(256)) dut (.*);
    always #5 clk = ~clk;

    task automatic axi_write(input [31:0] a, input [31:0] d, input [3:0] strb);
        bit done = 0;
        @(posedge clk);
        awaddr <= a; wdata <= d; wstrb <= strb; awvalid <= 1; wvalid <= 1; bready <= 1;
        while (!done) begin
            @(posedge clk);
            if (awready) awvalid <= 0;
            if (wready)  wvalid  <= 0;
            if (bvalid) begin
                if (bresp !== 2'b00) begin $display("  ERR write bresp=%0d @%08h", bresp, a); errors++; end
                bready <= 0; done = 1;
            end
        end
    endtask

    task automatic axi_read(input [31:0] a, output [31:0] d);
        bit done = 0;
        @(posedge clk);
        araddr <= a; arvalid <= 1; rready <= 1;
        while (!done) begin
            @(posedge clk);
            if (arready) arvalid <= 0;
            if (rvalid) begin
                d = rdata;
                if (rresp !== 2'b00) begin $display("  ERR read rresp=%0d @%08h", rresp, a); errors++; end
                rready <= 0; done = 1;
            end
        end
    endtask

    logic [31:0] rd;
    initial begin
        repeat (3) @(posedge clk); rst_n = 1;
        axi_write(32'h00, 32'hCAFEBABE, 4'hf);
        axi_write(32'h04, 32'h12345678, 4'hf);
        axi_read (32'h00, rd); if (rd !== 32'hCAFEBABE) begin $display("  MISMATCH @0: %08h", rd); errors++; end
        axi_read (32'h04, rd); if (rd !== 32'h12345678) begin $display("  MISMATCH @4: %08h", rd); errors++; end
        // byte-strobe: set all ones, then overwrite only byte 1
        axi_write(32'h08, 32'hFFFFFFFF, 4'hf);
        axi_write(32'h08, 32'h0000AA00, 4'b0010);
        axi_read (32'h08, rd); if (rd !== 32'hFFFFAAFF) begin $display("  MISMATCH strobe: %08h (exp FFFFAAFF)", rd); errors++; end
        if (errors == 0) $display("RESULT: PASS (axil_sram: rw + byte-strobe)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #100000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
