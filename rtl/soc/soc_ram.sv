// soc_ram.sv - on-chip RAM for the SoC: code + data in one array.
//
// Two asynchronous read ports (instruction fetch + data load) and one
// synchronous byte-write port -- the access model the single-cycle CPU memory
// interface expects (combinational read, registered write). Initialised from a
// $readmemh image when INITFILE is set (firmware/boot code).
//
// For silicon this maps to a 1RW + 1R SRAM macro (OpenRAM/DFFRAM); the async
// register array here keeps WORDS small so it still synthesises with std cells.
module soc_ram #(
    parameter int WORDS = 4096,              // 16 KiB
    parameter     INITFILE = ""              // untyped: iverilog passes it down cleanly
) (
    input  logic        clk,
    // instruction read port (async)
    input  logic [31:0] i_addr,
    output logic [31:0] i_rdata,
    // data read/write port (async read, sync byte-write)
    input  logic [31:0] d_addr,
    input  logic [31:0] d_wdata,
    input  logic [3:0]  d_be,
    input  logic        d_we,
    output logic [31:0] d_rdata
);
    localparam int AW = $clog2(WORDS);
    logic [31:0] mem [0:WORDS-1];

    wire [AW-1:0] i_idx = i_addr[AW+1:2];
    wire [AW-1:0] d_idx = d_addr[AW+1:2];

    assign i_rdata = mem[i_idx];
    assign d_rdata = mem[d_idx];

    always_ff @(posedge clk) begin
        if (d_we) begin
            if (d_be[0]) mem[d_idx][7:0]   <= d_wdata[7:0];
            if (d_be[1]) mem[d_idx][15:8]  <= d_wdata[15:8];
            if (d_be[2]) mem[d_idx][23:16] <= d_wdata[23:16];
            if (d_be[3]) mem[d_idx][31:24] <= d_wdata[31:24];
        end
    end

    initial begin
        if (INITFILE != "") $readmemh(INITFILE, mem);
    end
endmodule
