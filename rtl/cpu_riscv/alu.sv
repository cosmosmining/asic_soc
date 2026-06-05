// alu.sv - RV32IM ALU. Combinational. Includes M-extension multiply ops.
// HAS_DIV: when 1 (single-cycle core) DIV/REM are combinational; when 0
// (pipeline) they are handled by the external multi-cycle divider and the ALU
// contains no divide hardware (huge area/timing saving).
`include "riscv_defs.svh"

module alu #(
    parameter int XLEN    = 32,
    parameter bit HAS_DIV = 1'b1,
    parameter bit HAS_MUL = 1'b1
) (
    input  logic [4:0]       op,
    input  logic [XLEN-1:0]  a,
    input  logic [XLEN-1:0]  b,
    output logic [XLEN-1:0]  y,
    output logic             zero
);
    logic signed [XLEN-1:0]   as, bs;
    assign as = a;
    assign bs = b;

    localparam logic [XLEN-1:0] MIN_S = {1'b1, {(XLEN-1){1'b0}}};

    // Optional combinational multiplier (single-cycle core only). When HAS_MUL=0
    // (pipeline) MUL/MULH/MULHSU/MULHU are handled by the external sequential
    // unit and no 32x32 multiply hardware is inferred here.
    logic [XLEN-1:0] mul_y;
    generate
        if (HAS_MUL) begin : g_mul
            logic [2*XLEN-1:0]        mul_uu;
            logic signed [2*XLEN-1:0] mul_ss;
            logic signed [2*XLEN-1:0] mul_su;
            always_comb begin
                mul_uu = a  * b;                      // unsigned x unsigned
                mul_ss = as * bs;                     // signed x signed
                mul_su = as * $signed({1'b0, b});     // signed x unsigned
                unique case (op)
                    `ALU_MUL:   mul_y = mul_ss[XLEN-1:0];
                    `ALU_MULH:  mul_y = mul_ss[2*XLEN-1:XLEN];
                    `ALU_MULHSU:mul_y = mul_su[2*XLEN-1:XLEN];
                    `ALU_MULHU: mul_y = mul_uu[2*XLEN-1:XLEN];
                    default:    mul_y = '0;
                endcase
            end
        end else begin : g_nomul
            assign mul_y = '0;        // pipeline: multiply done by external unit
        end
    endgenerate

    // Optional combinational divide unit (single-cycle core only).
    logic [XLEN-1:0] div_y;
    generate
        if (HAS_DIV) begin : g_div
            logic div0, ovf;
            assign div0 = (b == '0);
            assign ovf  = (a == MIN_S) && (&b);   // b == -1
            always_comb begin
                unique case (op)
                    `ALU_DIV:  div_y = div0 ? {XLEN{1'b1}} : (ovf ? MIN_S : $unsigned(as / bs));
                    `ALU_DIVU: div_y = div0 ? {XLEN{1'b1}} : (a / b);
                    `ALU_REM:  div_y = div0 ? a : (ovf ? '0 : $unsigned(as % bs));
                    `ALU_REMU: div_y = div0 ? a : (a % b);
                    default:   div_y = '0;
                endcase
            end
        end else begin : g_nodiv
            assign div_y = '0;        // pipeline: divide done by external unit
        end
    endgenerate

    always_comb begin
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
            `ALU_MUL, `ALU_MULH, `ALU_MULHSU, `ALU_MULHU: y = mul_y;
            `ALU_PASSB: y = b;
            `ALU_DIV, `ALU_DIVU, `ALU_REM, `ALU_REMU: y = div_y;
            default:    y = '0;
        endcase
    end

    assign zero = (y == '0);
endmodule
