// Single-clock proof harness for the FIFO's binary->Gray pointer encoding.
`default_nettype none
module gray_inc #(parameter int AW = 4) (
    input wire clk, input wire rst_n, input wire en
);
    reg  [AW:0] bin = '0, gray = '0;
    wire [AW:0] bin_n  = bin + {{AW{1'b0}}, en};
    wire [AW:0] gray_n = (bin_n >> 1) ^ bin_n;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin bin <= '0; gray <= '0; end
        else        begin bin <= bin_n; gray <= gray_n; end
`ifdef FORMAL
    reg init = 1'b0; always_ff @(posedge clk) init <= 1'b1;
    function automatic [31:0] pc(input [AW:0] x);
        integer i; begin pc = 0; for (i=0;i<=AW;i=i+1) pc = pc + x[i]; end
    endfunction
    // P1: gray always equals the Gray code of bin
    always @(*) assert (gray == ((bin >> 1) ^ bin));
    // P2: consecutive Gray codes differ in at most one bit
    always_ff @(posedge clk) if (init && rst_n && $past(rst_n))
        assert (pc(gray ^ $past(gray)) <= 1);
`endif
endmodule
