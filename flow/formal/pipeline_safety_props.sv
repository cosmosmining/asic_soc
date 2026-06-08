// pipeline_safety_props.sv - yosys/SMT-friendly safety properties for the core.
//
// The same invariants as formal/assertions/riscv_core_sva.sv, written as clocked
// immediate assertions so the open-source yosys formal front end parses them
// ($isunknown is dropped -- formal is 2-state, so it is vacuous there).
module pipeline_safety_props (
    input logic        clk,
    input logic        rst_n,
    input logic [31:0] imem_addr,
    input logic [31:0] dmem_addr,
    input logic [3:0]  dmem_be,
    input logic        dmem_we
);
    always @(posedge clk) begin
        if (rst_n) begin
            a_pc_aligned   : assert (imem_addr[1:0] == 2'b00);
            a_dmem_aligned : assert (dmem_addr[1:0] == 2'b00);
            a_store_has_be : assert (!dmem_we || (dmem_be != 4'b0000));
        end
    end
endmodule
