// soc_ram_sync.sv - synchronous (registered-read) on-chip RAM.
//
// Models a compiled single-clock SRAM macro (OpenRAM 1rw1r / DFFRAM): the read
// data for an address appears one cycle after it is presented, so each port
// raises `*_ready` only once its address has been stable for a cycle. The CPU's
// imem_ready/dmem_ready memory-wait absorbs that latency. Two read ports (fetch
// + load) and one synchronous byte-write port; map to a 1rw1r macro at harden.
module soc_ram_sync #(
    parameter int WORDS    = 1024,
    parameter     INITFILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    // instruction read port
    input  logic [31:0] i_addr,
    output logic [31:0] i_rdata,
    output logic        i_ready,
    // data read/write port
    input  logic [31:0] d_addr,
    input  logic [31:0] d_wdata,
    input  logic [3:0]  d_be,
    input  logic        d_we,
    output logic [31:0] d_rdata,
    output logic        d_ready
);
    localparam int AW = $clog2(WORDS);
    logic [31:0] mem [0:WORDS-1];
    logic [31:0] i_addr_q, d_addr_q;

    always_ff @(posedge clk) begin
        i_rdata  <= mem[i_addr[AW+1:2]];        // 1-cycle registered read
        d_rdata  <= mem[d_addr[AW+1:2]];
        i_addr_q <= i_addr;
        d_addr_q <= d_addr;
        if (d_we) begin
            if (d_be[0]) mem[d_addr[AW+1:2]][7:0]   <= d_wdata[7:0];
            if (d_be[1]) mem[d_addr[AW+1:2]][15:8]  <= d_wdata[15:8];
            if (d_be[2]) mem[d_addr[AW+1:2]][23:16] <= d_wdata[23:16];
            if (d_be[3]) mem[d_addr[AW+1:2]][31:24] <= d_wdata[31:24];
        end
    end

    // data valid once the presented address has been stable for one cycle
    assign i_ready = rst_n && (i_addr == i_addr_q);
    assign d_ready = rst_n && (d_addr == d_addr_q);

    initial begin
        if (INITFILE != "") $readmemh(INITFILE, mem);
    end
endmodule
