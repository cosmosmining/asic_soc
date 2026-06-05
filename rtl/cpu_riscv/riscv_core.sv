// riscv_core.sv - single-cycle RV32IM core.
//
// This is iteration-1 of the RISC-V CPU: a correct, synthesizable single-cycle
// implementation. The 5-stage pipeline (with forwarding + hazard detection) will
// be built on top of this verified datapath. Memories are external (Harvard-ish:
// separate instruction fetch and data ports) so the same core drops onto either a
// TB BRAM model or the AXI memory subsystem via a thin adapter.
`include "riscv_defs.svh"

module riscv_core #(
    parameter int XLEN     = 32,
    parameter logic [XLEN-1:0] RESET_PC = 32'h0000_0000
) (
    input  logic            clk,
    input  logic            rst_n,
    // instruction fetch port (async read, word aligned)
    output logic [XLEN-1:0] imem_addr,
    input  logic [XLEN-1:0] imem_rdata,
    // data port (async read, sync write)
    output logic [XLEN-1:0] dmem_addr,
    output logic [XLEN-1:0] dmem_wdata,
    output logic [3:0]      dmem_be,     // byte enables for stores
    output logic            dmem_we,
    input  logic [XLEN-1:0] dmem_rdata,
    // debug visibility
    output logic [XLEN-1:0] dbg_pc
);
    // ---------------------------------------------------------------- PC
    logic [XLEN-1:0] pc, pc_next, pc_plus4;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc <= RESET_PC;
        else        pc <= pc_next;
    end
    assign pc_plus4  = pc + 32'd4;
    assign imem_addr = pc;
    assign dbg_pc    = pc;

    // ------------------------------------------------------------- decode
    logic [31:0] inst;
    assign inst = imem_rdata;

    logic [6:0] opcode;
    logic [4:0] rd;
    logic [2:0] funct3;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [6:0] funct7;
    assign opcode = inst[6:0];
    assign rd     = inst[11:7];
    assign funct3 = inst[14:12];
    assign rs1    = inst[19:15];
    assign rs2    = inst[24:20];
    assign funct7 = inst[31:25];

    // immediate generation
    logic [XLEN-1:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    assign imm_i = {{20{inst[31]}}, inst[31:20]};
    assign imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    assign imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    assign imm_u = {inst[31:12], 12'b0};
    assign imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

    // ------------------------------------------------------- control signals
    logic        reg_write;
    logic        alu_src_imm;   // ALU operand B = immediate
    logic        mem_read;
    logic        mem_write;
    logic        branch;
    logic        jump;          // JAL/JALR (unconditional)
    logic        jalr;
    logic [3:0]  alu_op;
    logic [1:0]  wb_sel;        // 0=alu, 1=mem, 2=pc+4, 3=imm_u(LUI)
    logic [XLEN-1:0] alu_b_imm; // selected immediate for ALU

    always_comb begin
        // defaults
        reg_write   = 1'b0;
        alu_src_imm = 1'b0;
        mem_read    = 1'b0;
        mem_write   = 1'b0;
        branch      = 1'b0;
        jump        = 1'b0;
        jalr        = 1'b0;
        alu_op      = `ALU_ADD;
        wb_sel      = 2'd0;
        alu_b_imm   = imm_i;

        unique case (opcode)
            `OPC_OP: begin // register-register
                reg_write = 1'b1;
                wb_sel    = 2'd0;
                if (funct7 == 7'b0000001) begin // M-extension
                    unique case (funct3)
                        3'b000: alu_op = `ALU_MUL;
                        3'b001: alu_op = `ALU_MULH;
                        3'b010: alu_op = `ALU_MULHSU;
                        3'b011: alu_op = `ALU_MULHU;
                        // DIV/REM not yet implemented -> treated as ADD (placeholder)
                        default: alu_op = `ALU_ADD;
                    endcase
                end else begin
                    unique case (funct3)
                        3'b000: alu_op = (funct7[5]) ? `ALU_SUB : `ALU_ADD;
                        3'b001: alu_op = `ALU_SLL;
                        3'b010: alu_op = `ALU_SLT;
                        3'b011: alu_op = `ALU_SLTU;
                        3'b100: alu_op = `ALU_XOR;
                        3'b101: alu_op = (funct7[5]) ? `ALU_SRA : `ALU_SRL;
                        3'b110: alu_op = `ALU_OR;
                        3'b111: alu_op = `ALU_AND;
                        default: alu_op = `ALU_ADD;
                    endcase
                end
            end
            `OPC_OPIMM: begin // register-immediate
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;
                wb_sel      = 2'd0;
                alu_b_imm   = imm_i;
                unique case (funct3)
                    3'b000: alu_op = `ALU_ADD;                       // ADDI
                    3'b010: alu_op = `ALU_SLT;                       // SLTI
                    3'b011: alu_op = `ALU_SLTU;                      // SLTIU
                    3'b100: alu_op = `ALU_XOR;                       // XORI
                    3'b110: alu_op = `ALU_OR;                        // ORI
                    3'b111: alu_op = `ALU_AND;                       // ANDI
                    3'b001: alu_op = `ALU_SLL;                       // SLLI
                    3'b101: alu_op = (funct7[5]) ? `ALU_SRA : `ALU_SRL; // SRAI/SRLI
                    default: alu_op = `ALU_ADD;
                endcase
            end
            `OPC_LOAD: begin
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;
                mem_read    = 1'b1;
                alu_op      = `ALU_ADD;   // address = rs1 + imm_i
                alu_b_imm   = imm_i;
                wb_sel      = 2'd1;       // from memory
            end
            `OPC_STORE: begin
                alu_src_imm = 1'b1;
                mem_write   = 1'b1;
                alu_op      = `ALU_ADD;   // address = rs1 + imm_s
                alu_b_imm   = imm_s;
            end
            `OPC_BRANCH: begin
                branch    = 1'b1;
                alu_op    = `ALU_SUB;     // compare via subtract / flags
                alu_b_imm = imm_b;
            end
            `OPC_JAL: begin
                reg_write = 1'b1;
                jump      = 1'b1;
                wb_sel    = 2'd2;         // rd = pc+4
            end
            `OPC_JALR: begin
                reg_write   = 1'b1;
                jump        = 1'b1;
                jalr        = 1'b1;
                alu_src_imm = 1'b1;
                alu_op      = `ALU_ADD;
                alu_b_imm   = imm_i;
                wb_sel      = 2'd2;
            end
            `OPC_LUI: begin
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;
                alu_op      = `ALU_PASSB;
                alu_b_imm   = imm_u;
                wb_sel      = 2'd0;
            end
            `OPC_AUIPC: begin
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;       // computed below as pc + imm_u
                alu_op      = `ALU_ADD;
                alu_b_imm   = imm_u;
                wb_sel      = 2'd0;
            end
            default: ; // NOP / unsupported: no architectural effect
        endcase
    end

    // ----------------------------------------------------------- register file
    logic [XLEN-1:0] rs1_data, rs2_data, wb_data;
    regfile #(.XLEN(XLEN)) u_rf (
        .clk, .rst_n,
        .rs1_addr(rs1), .rs2_addr(rs2),
        .rs1_data(rs1_data), .rs2_data(rs2_data),
        .we(reg_write), .rd_addr(rd), .rd_data(wb_data)
    );

    // --------------------------------------------------------------- ALU
    logic [XLEN-1:0] alu_a, alu_b, alu_y;
    logic            alu_zero;
    // AUIPC needs PC as operand A; everything else uses rs1.
    assign alu_a = (opcode == `OPC_AUIPC) ? pc : rs1_data;
    assign alu_b = alu_src_imm ? alu_b_imm : rs2_data;
    alu #(.XLEN(XLEN)) u_alu (
        .op(alu_op), .a(alu_a), .b(alu_b), .y(alu_y), .zero(alu_zero)
    );

    // ------------------------------------------------------- branch resolution
    logic eq, lt, ltu, take_branch;
    assign eq  = (rs1_data == rs2_data);
    assign lt  = ($signed(rs1_data) <  $signed(rs2_data));
    assign ltu = (rs1_data <  rs2_data);
    always_comb begin
        take_branch = 1'b0;
        if (branch) begin
            unique case (funct3)
                3'b000: take_branch =  eq;  // BEQ
                3'b001: take_branch = ~eq;  // BNE
                3'b100: take_branch =  lt;  // BLT
                3'b101: take_branch = ~lt;  // BGE
                3'b110: take_branch =  ltu; // BLTU
                3'b111: take_branch = ~ltu; // BGEU
                default: take_branch = 1'b0;
            endcase
        end
    end

    // --------------------------------------------------------- next-PC logic
    logic [XLEN-1:0] branch_target, jal_target, jalr_target;
    assign branch_target = pc + imm_b;
    assign jal_target    = pc + imm_j;
    assign jalr_target   = (rs1_data + imm_i) & ~32'h1; // clear LSB per spec
    always_comb begin
        if (jalr)                   pc_next = jalr_target;
        else if (jump)              pc_next = jal_target;     // JAL
        else if (take_branch)       pc_next = branch_target;
        else                        pc_next = pc_plus4;
    end

    // ----------------------------------------------------------- data memory
    // Address from ALU; byte/half/word handled with byte-enables and shifting.
    logic [1:0] byte_off;
    assign dmem_addr = {alu_y[XLEN-1:2], 2'b00}; // word aligned to memory
    assign byte_off  = alu_y[1:0];

    always_comb begin
        dmem_we    = mem_write;
        dmem_be    = 4'b0000;
        dmem_wdata = rs2_data;
        if (mem_write) begin
            unique case (funct3)
                3'b000: begin // SB
                    dmem_be    = 4'b0001 << byte_off;
                    dmem_wdata = rs2_data << (8*byte_off);
                end
                3'b001: begin // SH
                    dmem_be    = 4'b0011 << byte_off;
                    dmem_wdata = rs2_data << (8*byte_off);
                end
                3'b010: begin // SW
                    dmem_be    = 4'b1111;
                    dmem_wdata = rs2_data;
                end
                default: dmem_be = 4'b0000;
            endcase
        end
    end

    // load data formatting
    logic [XLEN-1:0] load_data;
    logic [7:0]      lb_byte;
    logic [15:0]     lh_half;
    always_comb begin
        lb_byte = dmem_rdata[8*byte_off +: 8];
        lh_half = dmem_rdata[16*byte_off[1] +: 16];
        unique case (funct3)
            3'b000:  load_data = {{24{lb_byte[7]}},  lb_byte};   // LB
            3'b001:  load_data = {{16{lh_half[15]}}, lh_half};   // LH
            3'b010:  load_data = dmem_rdata;                     // LW
            3'b100:  load_data = {24'b0, lb_byte};               // LBU
            3'b101:  load_data = {16'b0, lh_half};               // LHU
            default: load_data = dmem_rdata;
        endcase
    end

    // --------------------------------------------------------- write-back mux
    always_comb begin
        unique case (wb_sel)
            2'd0:    wb_data = alu_y;       // ALU result (incl. LUI/AUIPC)
            2'd1:    wb_data = load_data;   // load
            2'd2:    wb_data = pc_plus4;    // JAL/JALR link
            default: wb_data = alu_y;
        endcase
    end
endmodule
