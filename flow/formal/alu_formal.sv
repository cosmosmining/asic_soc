// alu_formal.sv - formal correctness harness for the RV32IM ALU.
//
// Instantiates the ALU with free inputs (op/a/b) and asserts the result equals
// an independent golden expression for every operation. The ALU is purely
// combinational, so a BMC depth of 1 is an exhaustive proof over all 2^69
// input combinations -- something no simulation could cover.
`include "riscv_defs.svh"

module alu_formal #(
    parameter int XLEN = 32
) (
    input  logic [4:0]      op,
    input  logic [XLEN-1:0] a,
    input  logic [XLEN-1:0] b
);
    logic [XLEN-1:0] y;
    logic            zero;

    // pipeline configuration: base ALU only (mul/div are external units)
    alu #(.XLEN(XLEN), .HAS_MUL(1'b0), .HAS_DIV(1'b0)) dut (
        .op(op), .a(a), .b(b), .y(y), .zero(zero)
    );

    logic signed [XLEN-1:0] as, bs;
    assign as = a;
    assign bs = b;

    // Independent golden references, each computed in its own properly-typed
    // assign so signedness is correct (in particular SRA must stay arithmetic --
    // inlining `as >>> b` inside a compare against unsigned `y` would silently
    // demote it to a logical shift).
    wire [XLEN-1:0] ref_add  = a + b;
    wire [XLEN-1:0] ref_sub  = a - b;
    wire [XLEN-1:0] ref_sll  = a << b[4:0];
    wire [XLEN-1:0] ref_srl  = a >> b[4:0];
    wire [XLEN-1:0] ref_sra  = as >>> b[4:0];
    wire [XLEN-1:0] ref_and  = a & b;
    wire [XLEN-1:0] ref_or   = a | b;
    wire [XLEN-1:0] ref_xor  = a ^ b;
    wire [XLEN-1:0] ref_slt  = {31'd0, as <  bs};
    wire [XLEN-1:0] ref_sltu = {31'd0, a  <  b };

    always_comb begin
        unique case (op)
            `ALU_ADD : a_add : assert (y == ref_add);
            `ALU_SUB : a_sub : assert (y == ref_sub);
            `ALU_SLL : a_sll : assert (y == ref_sll);
            `ALU_SRL : a_srl : assert (y == ref_srl);
            `ALU_SRA : a_sra : assert (y == ref_sra);
            `ALU_AND : a_and : assert (y == ref_and);
            `ALU_OR  : a_or  : assert (y == ref_or);
            `ALU_XOR : a_xor : assert (y == ref_xor);
            `ALU_SLT : a_slt : assert (y == ref_slt);
            `ALU_SLTU: a_sltu: assert (y == ref_sltu);
            `ALU_PASSB:a_passb:assert (y == b);
            default  : ;   // mul/div ops: handled by external units (y forced 0)
        endcase
        // the zero flag must always reflect the result
        a_zero : assert (zero == (y == '0));
    end
endmodule
