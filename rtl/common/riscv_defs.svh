// riscv_defs.svh - shared RV32IM encoding constants
`ifndef RISCV_DEFS_SVH
`define RISCV_DEFS_SVH

// Major opcodes (inst[6:0])
`define OPC_LUI     7'b0110111
`define OPC_AUIPC   7'b0010111
`define OPC_JAL     7'b1101111
`define OPC_JALR    7'b1100111
`define OPC_BRANCH  7'b1100011
`define OPC_LOAD    7'b0000011
`define OPC_STORE   7'b0100011
`define OPC_OPIMM   7'b0010011
`define OPC_OP      7'b0110011
`define OPC_SYSTEM  7'b1110011

// ALU operation select
`define ALU_ADD   4'd0
`define ALU_SUB   4'd1
`define ALU_SLL   4'd2
`define ALU_SLT   4'd3
`define ALU_SLTU  4'd4
`define ALU_XOR   4'd5
`define ALU_SRL   4'd6
`define ALU_SRA   4'd7
`define ALU_OR    4'd8
`define ALU_AND   4'd9
// M-extension
`define ALU_MUL    4'd10
`define ALU_MULH   4'd11
`define ALU_MULHSU 4'd12
`define ALU_MULHU  4'd13
`define ALU_PASSB  4'd14  // pass operand B (for LUI)
// Branch predictor BTB/BHT index width (entries = 2**BP_IDX_BITS)
`define BP_IDX_BITS 4

`define ALU_DIV    5'd15
`define ALU_DIVU   5'd16
`define ALU_REM    5'd17
`define ALU_REMU   5'd18

`endif
