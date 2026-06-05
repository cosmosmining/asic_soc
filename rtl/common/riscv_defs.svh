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
`define OPC_MISCMEM 7'b0001111   // FENCE / FENCE.I
`define OPC_SYSTEM  7'b1110011   // CSR + ECALL/EBREAK/MRET/WFI

// ALU operation select (5 bits -- the `op` port and all carriers are [4:0],
// so every encoding is sized 5 bits to keep RTL width-clean).
`define ALU_ADD    5'd0
`define ALU_SUB    5'd1
`define ALU_SLL    5'd2
`define ALU_SLT    5'd3
`define ALU_SLTU   5'd4
`define ALU_XOR    5'd5
`define ALU_SRL    5'd6
`define ALU_SRA    5'd7
`define ALU_OR     5'd8
`define ALU_AND    5'd9
// M-extension
`define ALU_MUL    5'd10
`define ALU_MULH   5'd11
`define ALU_MULHSU 5'd12
`define ALU_MULHU  5'd13
`define ALU_PASSB  5'd14  // pass operand B (for LUI)
`define ALU_DIV    5'd15
`define ALU_DIVU   5'd16
`define ALU_REM    5'd17
`define ALU_REMU   5'd18

// Branch predictor BTB/BHT index width (entries = 2**BP_IDX_BITS)
`define BP_IDX_BITS 4

// ---------------------------------------------------------------------------
// Zicsr + machine-mode privileged subset
// ---------------------------------------------------------------------------
// SYSTEM (opcode 1110011) funct3 encodings
`define SYS_PRIV   3'b000   // ECALL/EBREAK/MRET/WFI (selected by imm[11:0])
`define SYS_CSRRW  3'b001
`define SYS_CSRRS  3'b010
`define SYS_CSRRC  3'b011
`define SYS_CSRRWI 3'b101
`define SYS_CSRRSI 3'b110
`define SYS_CSRRCI 3'b111

// PRIV imm[11:0] selectors (funct3==000)
`define PRIV_ECALL  12'h000
`define PRIV_EBREAK 12'h001
`define PRIV_MRET   12'h302
`define PRIV_WFI    12'h105

// CSR read-modify-write op (derived from funct3[1:0])
`define CSR_RW 2'b01
`define CSR_RS 2'b10
`define CSR_RC 2'b11

// CSR addresses (machine mode)
`define CSR_MSTATUS  12'h300
`define CSR_MISA     12'h301
`define CSR_MIE      12'h304
`define CSR_MTVEC    12'h305
`define CSR_MSCRATCH 12'h340
`define CSR_MEPC     12'h341
`define CSR_MCAUSE   12'h342
`define CSR_MTVAL    12'h343
`define CSR_MIP      12'h344
`define CSR_MCYCLE   12'hB00
`define CSR_MINSTRET 12'hB02
`define CSR_MCYCLEH  12'hB80
`define CSR_MINSTRETH 12'hB82
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID  12'hF12
`define CSR_MIMPID   12'hF13
`define CSR_MHARTID  12'hF14

// Trap causes (mcause; interrupt bit [31] = 0 for these synchronous exceptions)
`define CAUSE_INSN_MISALIGN 32'd0
`define CAUSE_ILLEGAL_INSN  32'd2
`define CAUSE_BREAKPOINT    32'd3
`define CAUSE_LOAD_MISALIGN 32'd4
`define CAUSE_STORE_MISALIGN 32'd6
`define CAUSE_ECALL_M       32'd11

// misa for RV32IM (MXL=01 @[31:30], 'I'=bit8, 'M'=bit12)
`define MISA_RV32IM 32'h4000_1100

`endif
