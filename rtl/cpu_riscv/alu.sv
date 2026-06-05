// alu.sv - RV32IM ALU. Combinational. Includes M-extension multiply ops.
`include "riscv_defs.svh"

module alu #(
    parameter int XLEN = 32
) (
    input  logic [3:0]       op,
    input  logic [XLEN-1:0]  a,
    input  logic [XLEN-1:0]  b,
    output logic [XLEN-1:0]  y,
    output logic             zero
);
    logic signed [XLEN-1:0]   as, bs;
    assign as = a;
    assign bs = b;
    logic [2*XLEN-1:0]        mul_uu;
    logic signed [2*XLEN-1:0] mul_ss;
    logic signed [2*XLEN-1:0] mul_su;

    always_comb begin
        mul_uu = a  * b;                                  // unsigned x unsigned
        mul_ss = as * bs;                                 // signed x signed
        mul_su = as * $signed({1'b0, b});                 // signed x unsigned

        unique case (op)
            `ALU_ADD:   y = a + b;
            `ALU_SUB:   y = a - b;
            `ALU_SLL:   y = a << b[4:0];
            `ALU_SLT:   y = (as < bs) ? 32'd1 : 32'd0;
            `ALU_SLTU:  y = (a  < b ) ? 32'd1 : 32'd0;
            `ALU_XOR:   y = a ^ b;
            `ALU_SRL:   y = a >> b[4:0];
            `ALU_SRA:   y = as >>> b[4:0];
            `ALU_OR:    y = a | b;
            `ALU_AND:   y = a & b;
            `ALU_MUL:   y = mul_ss[XLEN-1:0];
            `ALU_MULH:  y = mul_ss[2*XLEN-1:XLEN];
            `ALU_MULHSU:y = mul_su[2*XLEN-1:XLEN];
            `ALU_MULHU: y = mul_uu[2*XLEN-1:XLEN];
            `ALU_PASSB: y = b;
            default:    y = '0;
        endcase
    end

    assign zero = (y == '0);
endmodule
