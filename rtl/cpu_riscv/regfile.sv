// regfile.sv - RV32 register file: 2 read ports, 1 write port, x0 hardwired 0.
// Synchronous write, combinational read.
//
// WRITE_FIRST controls same-cycle write->read visibility:
//   0 (default): plain read of the stored value. Correct for the single-cycle
//      core, where rd_data is the *current* instruction's combinational result;
//      bypassing it would (a) read an instruction's own result (wrong per spec)
//      and (b) form a combinational loop rs1->ALU->rd_data->rs1.
//   1: write-first bypass. Needed by the pipeline so a WB-stage write is visible
//      to a same-cycle ID-stage read. There rd_data is registered (MEM/WB), so
//      no combinational loop forms.
module regfile #(
    parameter int XLEN        = 32,
    parameter bit WRITE_FIRST = 1'b0
) (
    input  logic              clk,
    input  logic              rst_n,
    // read ports
    input  logic [4:0]        rs1_addr,
    input  logic [4:0]        rs2_addr,
    output logic [XLEN-1:0]   rs1_data,
    output logic [XLEN-1:0]   rs2_data,
    // write port
    input  logic              we,
    input  logic [4:0]        rd_addr,
    input  logic [XLEN-1:0]   rd_data
);
    logic [XLEN-1:0] regs [1:31];

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 1; i < 32; i = i + 1)
                regs[i] <= '0;
        end else if (we && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end

    // x0 is always zero. Optional write-first bypass (pipeline only).
    always_comb begin
        if (rs1_addr == 5'd0)                              rs1_data = '0;
        else if (WRITE_FIRST && we && rd_addr == rs1_addr) rs1_data = rd_data;
        else                                               rs1_data = regs[rs1_addr];

        if (rs2_addr == 5'd0)                              rs2_data = '0;
        else if (WRITE_FIRST && we && rd_addr == rs2_addr) rs2_data = rd_data;
        else                                               rs2_data = regs[rs2_addr];
    end
endmodule
