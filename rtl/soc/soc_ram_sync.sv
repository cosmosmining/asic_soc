// soc_ram_sync.sv - synchronous (registered-read) on-chip RAM.
//
// Models a compiled single-clock SRAM macro (OpenRAM 1rw1r / DFFRAM): read data
// appears one cycle after the address. The instruction port has a clock-enable
// (`i_en`) so the CPU's pipelined fetch can freeze the read on a stall (the
// SRAM holds its output -- no re-read). The data port raises `d_ready` once its
// address has been stable for a cycle, which the CPU's load memory-wait absorbs.
// Two read ports (fetch + load) and one synchronous byte-write port; maps to a
// 1rw1r macro at harden.
module soc_ram_sync #(
    parameter int WORDS    = 1024,
    parameter     INITFILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    // instruction read port (clock-enabled)
    input  logic        i_en,
    input  logic [31:0] i_addr,
    output logic [31:0] i_rdata,
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
    logic [31:0] d_addr_q;
    logic        d_we_q;

    always_ff @(posedge clk) begin
        if (i_en) i_rdata <= mem[i_addr[AW+1:2]];   // registered fetch (frozen when !i_en)
        d_rdata  <= mem[d_addr[AW+1:2]];            // registered load read
        d_addr_q <= d_addr;
        d_we_q   <= d_we;
        if (d_we) begin
            if (d_be[0]) mem[d_addr[AW+1:2]][7:0]   <= d_wdata[7:0];
            if (d_be[1]) mem[d_addr[AW+1:2]][15:8]  <= d_wdata[15:8];
            if (d_be[2]) mem[d_addr[AW+1:2]][23:16] <= d_wdata[23:16];
            if (d_be[3]) mem[d_addr[AW+1:2]][31:24] <= d_wdata[31:24];
        end
    end

    // load data valid once the address has been stable a cycle; a store to the
    // same address last cycle (RAW) forces one more wait so the registered read
    // reflects the write.
    assign d_ready = rst_n && (d_addr == d_addr_q) && !(d_we_q && (d_addr == d_addr_q));

    initial begin
        if (INITFILE != "") $readmemh(INITFILE, mem);
    end
endmodule
