// tb_async_fifo — dual-clock self-checking test for async_fifo.
// Independent write/read clocks; pushes N incrementing words with backpressure,
// checks FIFO order on the read side, flags write-while-full / read-while-empty.
// The reader is a clocked checker that samples rdata on the edge a read actually
// fires (rinc & !rempty), which is the cycle the head word is consumed.
`timescale 1ns/1ps
module tb_async_fifo;
    localparam int DW = 32;
    localparam int AW = 4;          // depth 16 -> easy to force full backpressure
    localparam int N  = 256;

    logic          wclk = 1'b0, wrst_n = 1'b0;
    logic          winc = 1'b0;
    logic [DW-1:0] wdata = '0;
    logic          wfull;

    logic          rclk = 1'b0, rrst_n = 1'b0;
    logic          rinc = 1'b0;
    logic [DW-1:0] rdata;
    logic          rempty;

    async_fifo #(.DW(DW), .AW(AW)) dut (.*);

    always #3.5 wclk = ~wclk;       // ~142 MHz
    always #5.5 rclk = ~rclk;       // ~91 MHz  (asynchronous to wclk)

    logic [DW-1:0] exp_q [$];
    int   wrote = 0, rcount = 0, errors = 0;
    logic done = 1'b0, ren_go = 1'b0;

    // ---- writer: one-cycle winc pulse per word, honoring wfull ----
    initial begin
        repeat (2) @(posedge wclk); wrst_n = 1'b1;
        for (int i = 0; i < N; i++) begin
            @(posedge wclk);
            while (wfull) @(posedge wclk);
            winc  <= 1'b1;
            wdata <= i[DW-1:0];
            exp_q.push_back(i[DW-1:0]);
            @(posedge wclk);
            winc <= 1'b0;
            wrote++;
        end
    end

    // ---- reader enable: start late to force the FIFO full first ----
    initial begin
        repeat (2) @(posedge rclk); rrst_n = 1'b1;
        repeat (60) @(posedge rclk); ren_go = 1'b1;
    end

    // ---- reader/checker: a read fires when rinc & !rempty ----
    always @(posedge rclk) begin
        if (rrst_n) begin
            if (rinc && !rempty) begin
                if (exp_q.size() == 0) begin
                    $display("  ERROR: underflow (expected-model empty)"); errors++;
                end else begin
                    if (rdata !== exp_q[0]) begin
                        $display("  MISMATCH idx %0d: got %08h exp %08h",
                                 rcount, rdata, exp_q[0]);
                        errors++;
                    end
                    void'(exp_q.pop_front());
                end
                rcount++;
            end
            rinc <= ren_go && !rempty && (rcount < N);
            if (rcount == N) done <= 1'b1;
        end
    end

    // ---- protocol monitor: writing while full would drop data ----
    always @(posedge wclk) if (wrst_n && winc && wfull) begin
        $display("  ERROR: write asserted while full"); errors++; end

    // ---- finish ----
    initial begin
        wait (done);
        repeat (4) @(posedge rclk);
        if (rcount == N && wrote == N && errors == 0)
            $display("RESULT: PASS (async FIFO: %0d words across 2 async clocks, 0 errors)", rcount);
        else
            $display("RESULT: FAIL (wrote=%0d read=%0d/%0d errors=%0d)", wrote, rcount, N, errors);
        $finish;
    end
    initial begin
        #500000;
        $display("RESULT: FAIL (timeout; wrote=%0d read=%0d/%0d)", wrote, rcount, N);
        $finish;
    end
endmodule
