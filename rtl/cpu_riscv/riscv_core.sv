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
    output logic [XLEN-1:0] dbg_pc,
    // RVFI-lite retire interface (registered; one record per committed instr)
    output logic            rvfi_valid,
    output logic [XLEN-1:0] rvfi_pc,
    output logic [4:0]      rvfi_rd,
    output logic            rvfi_we,
    output logic [XLEN-1:0] rvfi_wdata
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
    logic        mem_read;      // a load (for misalignment checking)
    logic        mem_write;
    logic        branch;
    logic        jump;          // JAL/JALR (unconditional)
    logic        jalr;
    logic [4:0]  alu_op;
    logic [1:0]  wb_sel;        // 0=alu, 1=mem, 2=pc+4, 3=csr
    logic [XLEN-1:0] alu_b_imm; // selected immediate for ALU
    // SYSTEM / Zicsr decode
    logic        is_csr;        // a CSRR[W|S|C][I] instruction
    logic        is_ecall, is_ebreak, is_mret;
    logic        legal;         // instruction is a legal RV32IM/Zicsr encoding

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
        is_csr      = 1'b0;
        is_ecall    = 1'b0;
        is_ebreak   = 1'b0;
        is_mret     = 1'b0;
        legal       = 1'b1;
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
                        3'b100: alu_op = `ALU_DIV;
                        3'b101: alu_op = `ALU_DIVU;
                        3'b110: alu_op = `ALU_REM;
                        3'b111: alu_op = `ALU_REMU;
                        default: alu_op = `ALU_ADD;
                    endcase
                end else begin
                    // legal funct7: 0000000 (all f3); 0100000 only for SUB/SRA
                    legal = (funct7 == 7'b0000000) ||
                            (funct7 == 7'b0100000 && (funct3==3'b000 || funct3==3'b101));
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
                    3'b001: begin alu_op = `ALU_SLL; legal = (funct7==7'b0000000); end // SLLI
                    3'b101: begin alu_op = (funct7[5]) ? `ALU_SRA : `ALU_SRL;        // SRAI/SRLI
                            legal = (funct7==7'b0000000 || funct7==7'b0100000); end
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
                legal = (funct3==3'b000||funct3==3'b001||funct3==3'b010||
                         funct3==3'b100||funct3==3'b101);
            end
            `OPC_STORE: begin
                alu_src_imm = 1'b1;
                mem_write   = 1'b1;
                alu_op      = `ALU_ADD;   // address = rs1 + imm_s
                alu_b_imm   = imm_s;
                legal = (funct3==3'b000||funct3==3'b001||funct3==3'b010);
            end
            `OPC_BRANCH: begin
                branch    = 1'b1;
                alu_op    = `ALU_SUB;     // compare via subtract / flags
                alu_b_imm = imm_b;
                legal = (funct3!=3'b010 && funct3!=3'b011);
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
                legal = (funct3==3'b000);
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
            `OPC_MISCMEM: begin // FENCE / FENCE.I : architecturally a NOP here
                legal = (funct3==3'b000 || funct3==3'b001);
            end
            `OPC_SYSTEM: begin
                if (funct3 == `SYS_PRIV) begin
                    unique case (inst[31:20])
                        `PRIV_ECALL : is_ecall  = 1'b1;
                        `PRIV_EBREAK: is_ebreak = 1'b1;
                        `PRIV_MRET  : is_mret   = 1'b1;
                        `PRIV_WFI   : ;                   // WFI: NOP
                        default     : legal     = 1'b0;
                    endcase
                end else if (funct3 == 3'b100) begin
                    legal = 1'b0;                          // no f3=100 CSR op
                end else begin                             // CSRR[W|S|C][I]
                    is_csr    = 1'b1;
                    reg_write = 1'b1;                       // rd <- old CSR value
                    wb_sel    = 2'd3;                       // writeback from CSR
                end
            end
            default: legal = 1'b0;       // unknown opcode -> illegal instruction
        endcase
    end

    // ----------------------------------------------------------- register file
    // (write suppressed when the instruction traps; `trap` declared below)
    logic            trap;
    logic [XLEN-1:0] rs1_data, rs2_data, wb_data;
    regfile #(.XLEN(XLEN)) u_rf (
        .clk, .rst_n,
        .rs1_addr(rs1), .rs2_addr(rs2),
        .rs1_data(rs1_data), .rs2_data(rs2_data),
        .we(reg_write && !trap), .rd_addr(rd), .rd_data(wb_data)
    );

    // --------------------------------------------------------------- ALU
    logic [XLEN-1:0] alu_a, alu_b, alu_y;
    logic            alu_zero_unused;
    // AUIPC needs PC as operand A; everything else uses rs1.
    assign alu_a = (opcode == `OPC_AUIPC) ? pc : rs1_data;
    assign alu_b = alu_src_imm ? alu_b_imm : rs2_data;
    alu #(.XLEN(XLEN)) u_alu (
        .op(alu_op), .a(alu_a), .b(alu_b), .y(alu_y), .zero(alu_zero_unused)
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

    // --------------------------------------------------------- control targets
    logic [XLEN-1:0] branch_target, jal_target, jalr_target, ctrl_target;
    logic            take_ctrl;
    assign branch_target = pc + imm_b;
    assign jal_target    = pc + imm_j;
    assign jalr_target   = (rs1_data + imm_i) & ~32'h1; // clear LSB per spec
    assign take_ctrl     = jump || (branch && take_branch);
    assign ctrl_target   = jalr ? jalr_target : (jump ? jal_target : branch_target);

    // effective load/store address == ALU result (rs1 + imm) for LOAD/STORE
    wire [XLEN-1:0] mem_addr = alu_y;

    // ------------------------------------------------------------- CSR access
    logic [11:0]     csr_addr;
    logic [1:0]      csr_op;
    logic [XLEN-1:0] csr_wsrc, csr_rdata;
    logic            csr_we_intent, csr_illegal;
    logic [XLEN-1:0] csr_trap_target, csr_mret_target;
    assign csr_addr      = inst[31:20];
    assign csr_op        = funct3[1:0];
    assign csr_wsrc      = funct3[2] ? {27'b0, rs1} : rs1_data;   // *I uses zimm
    assign csr_we_intent = is_csr && ((csr_op == `CSR_RW) || (rs1 != 5'd0));

    // --------------------------------------------------------- trap detection
    logic [XLEN-1:0] trap_cause, trap_tval;
    logic            ld_ma, st_ma, insn_ma;
    assign ld_ma   = mem_read  && ((funct3==3'b010 && mem_addr[1:0]!=2'b00) ||
                                   ((funct3==3'b001||funct3==3'b101) && mem_addr[0]));
    assign st_ma   = mem_write && ((funct3==3'b010 && mem_addr[1:0]!=2'b00) ||
                                   (funct3==3'b001 && mem_addr[0]));
    assign insn_ma = take_ctrl && (ctrl_target[1:0] != 2'b00);
    always_comb begin
        trap = 1'b1;
        if      (!legal)                begin trap_cause = `CAUSE_ILLEGAL_INSN;  trap_tval = '0; end
        else if (is_csr && csr_illegal) begin trap_cause = `CAUSE_ILLEGAL_INSN;  trap_tval = '0; end
        else if (insn_ma)               begin trap_cause = `CAUSE_INSN_MISALIGN; trap_tval = ctrl_target; end
        else if (ld_ma)                 begin trap_cause = `CAUSE_LOAD_MISALIGN; trap_tval = mem_addr; end
        else if (st_ma)                 begin trap_cause = `CAUSE_STORE_MISALIGN;trap_tval = mem_addr; end
        else if (is_ecall)              begin trap_cause = `CAUSE_ECALL_M;       trap_tval = '0; end
        else if (is_ebreak)             begin trap_cause = `CAUSE_BREAKPOINT;    trap_tval = '0; end
        else                            begin trap = 1'b0; trap_cause = '0;      trap_tval = '0; end
    end

    csr #(.XLEN(XLEN)) u_csr (
        .clk, .rst_n,
        .csr_addr, .csr_op, .csr_wsrc,
        .csr_we(csr_we_intent),             // module suppresses write if csr_illegal
        .csr_rdata, .csr_illegal,
        .trap, .trap_cause, .trap_epc(pc), .trap_tval,
        .mret(is_mret),
        .trap_target(csr_trap_target), .mret_target(csr_mret_target),
        .sw_irq(1'b0), .timer_irq(1'b0), .ext_irq(1'b0),  // no interrupts in the SC core
        .irq_req(), .irq_cause(),                          // SC core never takes interrupts
        .instret_inc(!trap)                 // single-cycle: one retire/cycle unless trapping
    );

    // --------------------------------------------------------- next-PC logic
    always_comb begin
        if      (trap)        pc_next = csr_trap_target;     // synchronous trap -> mtvec
        else if (is_mret)     pc_next = csr_mret_target;     // MRET -> mepc
        else if (jalr)        pc_next = jalr_target;
        else if (jump)        pc_next = jal_target;          // JAL
        else if (take_branch) pc_next = branch_target;
        else                  pc_next = pc_plus4;
    end

    // ----------------------------------------------------------- data memory
    // Address from ALU; byte/half/word handled with byte-enables and shifting.
    logic [1:0] byte_off;
    assign dmem_addr = {alu_y[XLEN-1:2], 2'b00}; // word aligned to memory
    assign byte_off  = alu_y[1:0];

    always_comb begin
        dmem_we    = mem_write && !trap;   // misaligned store traps -> no write
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
            2'd3:    wb_data = csr_rdata;   // CSR read (CSRR[W|S|C][I])
            default: wb_data = alu_y;
        endcase
    end

    // ----------------------------------------------------- retire (RVFI-lite)
    // Registered so external monitors sample a stable, race-free commit record.
    // Single-cycle: exactly one instruction commits each cycle out of reset.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvfi_valid <= 1'b0;
            rvfi_pc    <= '0;
            rvfi_rd    <= '0;
            rvfi_we    <= 1'b0;
            rvfi_wdata <= '0;
        end else begin
            // Every instruction retires (one per cycle); a trapping instruction
            // commits with we=0 (its architectural GPR write is suppressed).
            rvfi_valid <= 1'b1;
            rvfi_pc    <= pc;
            rvfi_rd    <= rd;
            rvfi_we    <= reg_write && !trap && (rd != 5'd0);
            rvfi_wdata <= (reg_write && !trap && rd != 5'd0) ? wb_data : '0;
        end
    end
endmodule
