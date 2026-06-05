// riscv_pipeline.sv - 5-stage in-order RV32IM pipeline (IF/ID/EX/MEM/WB).
//
// Built on the verified single-cycle datapath. Adds:
//   - full EX-stage forwarding from EX/MEM and MEM/WB
//   - load-use hazard detection with a 1-cycle stall + bubble
//   - branch/jump resolved in EX with a 2-cycle flush of younger instructions
//   - regfile write-first bypass (WB->ID same-cycle reads)
//
// Identical port list to riscv_core so the golden-trace TB validates both.
// Branch policy: predict-not-taken; redirect + flush on taken branch/jump.
`include "riscv_defs.svh"

module riscv_pipeline #(
    parameter int XLEN     = 32,
    parameter logic [XLEN-1:0] RESET_PC = 32'h0000_0000
) (
    input  logic            clk,
    input  logic            rst_n,
    output logic [XLEN-1:0] imem_addr,
    input  logic [XLEN-1:0] imem_rdata,
    output logic [XLEN-1:0] dmem_addr,
    output logic [XLEN-1:0] dmem_wdata,
    output logic [3:0]      dmem_be,
    output logic            dmem_we,
    input  logic [XLEN-1:0] dmem_rdata,
    output logic [XLEN-1:0] dbg_pc,
    output logic            rvfi_valid,
    output logic [XLEN-1:0] rvfi_pc,
    output logic [4:0]      rvfi_rd,
    output logic            rvfi_we,
    output logic [XLEN-1:0] rvfi_wdata
);
    localparam logic [1:0] WB_ALU = 2'd0, WB_MEM = 2'd1, WB_PC4 = 2'd2;

    // ============================================================ IF stage
    logic [XLEN-1:0] pc, pc_next;
    logic            stall;        // load-use hazard (freezes IF/ID + PC)
    logic            redirect;     // from EX: branch mispredict, flush + recover
    logic [XLEN-1:0] redirect_pc;
    logic            div_stall;    // multi-cycle divide in flight (freezes front-end)
    wire             front_stall = stall || div_stall;

    // ---- dynamic branch predictor: direct-mapped BTB + 2-bit BHT ------------
    // Tagged by the full pc[31:2], so a hit is always the exact same PC that
    // trained it (no cross-PC aliasing) -> predictions only fire for real,
    // previously-seen control transfers. Predict-taken redirects fetch early;
    // EX checks predicted-next-pc vs actual and flushes only on a mismatch.
    localparam int BPB = `BP_IDX_BITS;
    localparam int BPN = 1 << BPB;
    localparam int TAGW = XLEN - BPB - 2;
    logic              btb_valid  [0:BPN-1];
    logic              btb_uncond [0:BPN-1];
    logic [XLEN-1:0]   btb_target [0:BPN-1];
    logic [TAGW-1:0]   btb_tag    [0:BPN-1];
    logic [1:0]        bht        [0:BPN-1];

    logic [BPB-1:0]    if_idx;
    logic              predict_taken;
    logic [XLEN-1:0]   predict_target;
    assign if_idx         = pc[BPB+1:2];
    wire   if_hit         = btb_valid[if_idx] && (btb_tag[if_idx] == pc[XLEN-1:BPB+2]);
`ifdef BP_OFF
    assign predict_taken  = 1'b0;        // baseline: static predict-not-taken
`else
    assign predict_taken  = if_hit && (btb_uncond[if_idx] || bht[if_idx][1]);
`endif
    assign predict_target = btb_target[if_idx];

    always_comb begin
        if      (redirect)       pc_next = redirect_pc;     // mispredict recovery
        else if (front_stall)    pc_next = pc;              // load-use / divide hold
        else if (predict_taken)  pc_next = predict_target;  // predicted taken
        else                     pc_next = pc + 32'd4;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc <= RESET_PC;
        else        pc <= pc_next;
    end
    assign imem_addr = pc;
    assign dbg_pc    = pc;

    // ====================================================== IF/ID register
    logic            de_valid;
    logic [XLEN-1:0] de_pc;
    logic [31:0]     de_inst;
    logic            de_pred_taken;     // prediction made for this fetch
    logic [XLEN-1:0] de_pred_target;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_valid      <= 1'b0;
            de_pc         <= '0;
            de_inst       <= 32'h0;
            de_pred_taken <= 1'b0;
        end else if (redirect) begin
            de_valid      <= 1'b0;      // flush younger (wrong-path) instruction
            de_inst       <= 32'h0;
            de_pred_taken <= 1'b0;
        end else if (front_stall) begin
            // hold IF/ID (load-use or divide)
        end else begin
            de_valid       <= 1'b1;
            de_pc          <= pc;
            de_inst        <= imem_rdata;
            de_pred_taken  <= predict_taken;
            de_pred_target <= predict_target;
        end
    end

    // ============================================================ ID stage
    logic [6:0] opcode;
    logic [4:0] de_rd;
    logic [2:0] funct3;
    logic [4:0] de_rs1;
    logic [4:0] de_rs2;
    logic [6:0] funct7;
    assign opcode = de_inst[6:0];
    assign de_rd  = de_inst[11:7];
    assign funct3 = de_inst[14:12];
    assign de_rs1 = de_inst[19:15];
    assign de_rs2 = de_inst[24:20];
    assign funct7 = de_inst[31:25];

    logic [XLEN-1:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    assign imm_i = {{20{de_inst[31]}}, de_inst[31:20]};
    assign imm_s = {{20{de_inst[31]}}, de_inst[31:25], de_inst[11:7]};
    assign imm_b = {{19{de_inst[31]}}, de_inst[31], de_inst[7], de_inst[30:25], de_inst[11:8], 1'b0};
    assign imm_u = {de_inst[31:12], 12'b0};
    assign imm_j = {{11{de_inst[31]}}, de_inst[31], de_inst[19:12], de_inst[20], de_inst[30:21], 1'b0};

    // control bundle (combinational decode)
    logic        c_reg_write, c_alu_src_imm, c_mem_read, c_mem_write;
    logic        c_branch, c_jump, c_jalr, c_use_pc;
    logic        c_uses_rs1, c_uses_rs2;
    logic [4:0]  c_alu_op;
    logic [1:0]  c_wb_sel;
    logic [XLEN-1:0] c_imm_alu;
    // SYSTEM / Zicsr decode
    logic        c_is_csr, c_is_ecall, c_is_ebreak, c_is_mret, c_legal;

    always_comb begin
        c_reg_write   = 1'b0; c_alu_src_imm = 1'b0;
        c_mem_read    = 1'b0; c_mem_write   = 1'b0;
        c_branch      = 1'b0; c_jump        = 1'b0; c_jalr = 1'b0; c_use_pc = 1'b0;
        c_uses_rs1    = 1'b0; c_uses_rs2    = 1'b0;
        c_alu_op      = `ALU_ADD; c_wb_sel  = WB_ALU;
        c_imm_alu     = imm_i;
        c_is_csr      = 1'b0; c_is_ecall = 1'b0; c_is_ebreak = 1'b0;
        c_is_mret     = 1'b0; c_legal    = 1'b1;

        unique case (opcode)
            `OPC_OP: begin
                c_reg_write = 1'b1; c_uses_rs1 = 1'b1; c_uses_rs2 = 1'b1;
                if (funct7 == 7'b0000001) begin
                    unique case (funct3)
                        3'b000: c_alu_op = `ALU_MUL;
                        3'b001: c_alu_op = `ALU_MULH;
                        3'b010: c_alu_op = `ALU_MULHSU;
                        3'b011: c_alu_op = `ALU_MULHU;
                        3'b100: c_alu_op = `ALU_DIV;
                        3'b101: c_alu_op = `ALU_DIVU;
                        3'b110: c_alu_op = `ALU_REM;
                        3'b111: c_alu_op = `ALU_REMU;
                        default: c_alu_op = `ALU_ADD;
                    endcase
                end else begin
                    c_legal = (funct7 == 7'b0000000) ||
                              (funct7 == 7'b0100000 && (funct3==3'b000 || funct3==3'b101));
                    unique case (funct3)
                        3'b000: c_alu_op = funct7[5] ? `ALU_SUB : `ALU_ADD;
                        3'b001: c_alu_op = `ALU_SLL;
                        3'b010: c_alu_op = `ALU_SLT;
                        3'b011: c_alu_op = `ALU_SLTU;
                        3'b100: c_alu_op = `ALU_XOR;
                        3'b101: c_alu_op = funct7[5] ? `ALU_SRA : `ALU_SRL;
                        3'b110: c_alu_op = `ALU_OR;
                        3'b111: c_alu_op = `ALU_AND;
                        default: c_alu_op = `ALU_ADD;
                    endcase
                end
            end
            `OPC_OPIMM: begin
                c_reg_write = 1'b1; c_alu_src_imm = 1'b1; c_uses_rs1 = 1'b1;
                c_imm_alu = imm_i;
                unique case (funct3)
                    3'b000: c_alu_op = `ALU_ADD;
                    3'b010: c_alu_op = `ALU_SLT;
                    3'b011: c_alu_op = `ALU_SLTU;
                    3'b100: c_alu_op = `ALU_XOR;
                    3'b110: c_alu_op = `ALU_OR;
                    3'b111: c_alu_op = `ALU_AND;
                    3'b001: begin c_alu_op = `ALU_SLL; c_legal = (funct7==7'b0000000); end
                    3'b101: begin c_alu_op = funct7[5] ? `ALU_SRA : `ALU_SRL;
                            c_legal = (funct7==7'b0000000 || funct7==7'b0100000); end
                    default: c_alu_op = `ALU_ADD;
                endcase
            end
            `OPC_LOAD: begin
                c_reg_write = 1'b1; c_alu_src_imm = 1'b1; c_mem_read = 1'b1;
                c_uses_rs1 = 1'b1; c_imm_alu = imm_i; c_wb_sel = WB_MEM;
                c_legal = (funct3==3'b000||funct3==3'b001||funct3==3'b010||
                           funct3==3'b100||funct3==3'b101);
            end
            `OPC_STORE: begin
                c_alu_src_imm = 1'b1; c_mem_write = 1'b1;
                c_uses_rs1 = 1'b1; c_uses_rs2 = 1'b1; c_imm_alu = imm_s;
                c_legal = (funct3==3'b000||funct3==3'b001||funct3==3'b010);
            end
            `OPC_BRANCH: begin
                c_branch = 1'b1; c_uses_rs1 = 1'b1; c_uses_rs2 = 1'b1;
                c_legal = (funct3!=3'b010 && funct3!=3'b011);
            end
            `OPC_JAL: begin
                c_reg_write = 1'b1; c_jump = 1'b1; c_wb_sel = WB_PC4;
            end
            `OPC_JALR: begin
                c_reg_write = 1'b1; c_jump = 1'b1; c_jalr = 1'b1;
                c_alu_src_imm = 1'b1; c_uses_rs1 = 1'b1;
                c_imm_alu = imm_i; c_wb_sel = WB_PC4;
                c_legal = (funct3==3'b000);
            end
            `OPC_LUI: begin
                c_reg_write = 1'b1; c_alu_src_imm = 1'b1;
                c_alu_op = `ALU_PASSB; c_imm_alu = imm_u; c_wb_sel = WB_ALU;
            end
            `OPC_AUIPC: begin
                c_reg_write = 1'b1; c_alu_src_imm = 1'b1; c_use_pc = 1'b1;
                c_alu_op = `ALU_ADD; c_imm_alu = imm_u; c_wb_sel = WB_ALU;
            end
            `OPC_MISCMEM: begin // FENCE / FENCE.I : NOP
                c_legal = (funct3==3'b000 || funct3==3'b001);
            end
            `OPC_SYSTEM: begin
                if (funct3 == `SYS_PRIV) begin
                    unique case (de_inst[31:20])
                        `PRIV_ECALL : c_is_ecall  = 1'b1;
                        `PRIV_EBREAK: c_is_ebreak = 1'b1;
                        `PRIV_MRET  : c_is_mret   = 1'b1;
                        `PRIV_WFI   : ;                    // WFI: NOP
                        default     : c_legal     = 1'b0;
                    endcase
                end else if (funct3 == 3'b100) begin
                    c_legal = 1'b0;
                end else begin                              // CSRR[W|S|C][I]
                    c_is_csr   = 1'b1;
                    c_reg_write= 1'b1;                       // rd <- old CSR value
                    c_wb_sel   = WB_ALU;                     // routed via ex_result
                    c_uses_rs1 = ~funct3[2];                 // reg forms read rs1
                end
            end
            default: c_legal = 1'b0;       // unknown opcode -> illegal
        endcase
    end

    // register file (read in ID, write from WB, write-first bypass)
    logic [XLEN-1:0] rf_rs1, rf_rs2, wb_wdata;
    logic            wb_valid, wb_reg_write;
    logic [4:0]      wb_rd;
    regfile #(.XLEN(XLEN), .WRITE_FIRST(1'b1)) u_rf (
        .clk, .rst_n,
        .rs1_addr(de_rs1), .rs2_addr(de_rs2),
        .rs1_data(rf_rs1), .rs2_data(rf_rs2),
        .we(wb_valid && wb_reg_write), .rd_addr(wb_rd), .rd_data(wb_wdata)
    );

    // ====================================================== ID/EX register
    logic            ex_valid;
    logic [XLEN-1:0] ex_pc, ex_rs1_data, ex_rs2_data, ex_imm_alu, ex_imm_b, ex_imm_j;
    logic [4:0]      ex_rs1, ex_rs2, ex_rd;
    logic [2:0]      ex_funct3;
    logic [4:0]      ex_alu_op;
    logic [1:0]      ex_wb_sel;
    logic            ex_reg_write, ex_alu_src_imm, ex_mem_read, ex_mem_write;
    logic            ex_branch, ex_jump, ex_jalr, ex_use_pc;
    logic            ex_pred_taken;
    logic [XLEN-1:0] ex_pred_target;
    // SYSTEM / Zicsr carried to EX
    logic            ex_is_csr, ex_is_ecall, ex_is_ebreak, ex_is_mret, ex_legal;
    logic [11:0]     ex_csr_addr;
    logic [1:0]      ex_csr_op;
    logic            ex_csr_is_imm;

    // bubble when stalling (load-use) or flushing (redirect kills de).
    // Kept as a *synchronous* clear, separate from the async reset, so DFF
    // inference stays clean.
    wire ex_bubble = stall || redirect;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid      <= 1'b0;
            ex_reg_write  <= 1'b0;
            ex_mem_read   <= 1'b0;
            ex_mem_write  <= 1'b0;
            ex_branch     <= 1'b0;
            ex_jump       <= 1'b0;
            ex_jalr       <= 1'b0;
            ex_rd         <= 5'd0;
            ex_pred_taken <= 1'b0;
            ex_is_csr     <= 1'b0; ex_is_ecall <= 1'b0;
            ex_is_ebreak  <= 1'b0; ex_is_mret  <= 1'b0; ex_legal <= 1'b1;
        end else if (div_stall) begin
            // hold the divide instruction in EX until the divider completes
        end else if (ex_bubble) begin
            ex_valid      <= 1'b0;
            ex_reg_write  <= 1'b0;
            ex_mem_read   <= 1'b0;
            ex_mem_write  <= 1'b0;
            ex_branch     <= 1'b0;
            ex_jump       <= 1'b0;
            ex_jalr       <= 1'b0;
            ex_rd         <= 5'd0;
            ex_pred_taken <= 1'b0;
            ex_is_csr     <= 1'b0; ex_is_ecall <= 1'b0;
            ex_is_ebreak  <= 1'b0; ex_is_mret  <= 1'b0; ex_legal <= 1'b1;
        end else begin
            ex_pred_taken <= de_pred_taken;
            ex_pred_target<= de_pred_target;
            ex_valid      <= de_valid;
            ex_pc         <= de_pc;
            ex_rs1_data   <= rf_rs1;
            ex_rs2_data   <= rf_rs2;
            ex_imm_alu    <= c_imm_alu;
            ex_imm_b      <= imm_b;
            ex_imm_j      <= imm_j;
            ex_rs1        <= de_rs1;
            ex_rs2        <= de_rs2;
            ex_rd         <= de_rd;
            ex_funct3     <= funct3;
            ex_alu_op     <= c_alu_op;
            ex_wb_sel     <= c_wb_sel;
            ex_reg_write  <= c_reg_write;
            ex_alu_src_imm<= c_alu_src_imm;
            ex_mem_read   <= c_mem_read;
            ex_mem_write  <= c_mem_write;
            ex_branch     <= c_branch;
            ex_jump       <= c_jump;
            ex_jalr       <= c_jalr;
            ex_use_pc     <= c_use_pc;
            ex_is_csr     <= c_is_csr;
            ex_is_ecall   <= c_is_ecall;
            ex_is_ebreak  <= c_is_ebreak;
            ex_is_mret    <= c_is_mret;
            ex_legal      <= c_legal;
            ex_csr_addr   <= de_inst[31:20];
            ex_csr_op     <= funct3[1:0];
            ex_csr_is_imm <= funct3[2];
        end
    end

    // ============================================================ EX stage
    // forwarding sources
    logic [XLEN-1:0] em_alu_y, em_pc4, em_store_data;
    logic [4:0]      em_rd;
    logic            em_valid, em_reg_write, em_mem_write;
    logic [1:0]      em_wb_sel;
    logic [2:0]      em_funct3;

    logic [XLEN-1:0] em_fwd_val;
    assign em_fwd_val = (em_wb_sel == WB_PC4) ? em_pc4 : em_alu_y;

    logic em_can_fwd, wb_can_fwd;
    assign em_can_fwd = em_valid && em_reg_write && (em_rd != 5'd0) && (em_wb_sel != WB_MEM);
    assign wb_can_fwd = wb_valid && wb_reg_write && (wb_rd != 5'd0);

    logic [XLEN-1:0] fwd_a, fwd_b;
    always_comb begin
        // operand A
        if      (em_can_fwd && em_rd == ex_rs1) fwd_a = em_fwd_val;
        else if (wb_can_fwd && wb_rd == ex_rs1) fwd_a = wb_wdata;
        else                                    fwd_a = ex_rs1_data;
        // operand B (also store data)
        if      (em_can_fwd && em_rd == ex_rs2) fwd_b = em_fwd_val;
        else if (wb_can_fwd && wb_rd == ex_rs2) fwd_b = wb_wdata;
        else                                    fwd_b = ex_rs2_data;
    end

    logic [XLEN-1:0] alu_a, alu_b, alu_y;
    logic            alu_zero_unused;
    assign alu_a = ex_use_pc ? ex_pc : fwd_a;
    assign alu_b = ex_alu_src_imm ? ex_imm_alu : fwd_b;
    // pipeline ALU has no multiply/divide hardware; M-ext goes to the sequential
    // units below (smaller area, shorter critical path, tractable std-cell map).
    alu #(.XLEN(XLEN), .HAS_DIV(1'b0), .HAS_MUL(1'b0)) u_alu (
        .op(ex_alu_op), .a(alu_a), .b(alu_b), .y(alu_y), .zero(alu_zero_unused)
    );

    // ---- multi-cycle divider (DIV/DIVU/REM/REMU) ----------------------------
    wire div_op    = (ex_alu_op == `ALU_DIV)  || (ex_alu_op == `ALU_DIVU) ||
                     (ex_alu_op == `ALU_REM)  || (ex_alu_op == `ALU_REMU);
    wire ex_is_div = ex_valid && div_op;
    wire div_is_signed = (ex_alu_op == `ALU_DIV) || (ex_alu_op == `ALU_REM);
    wire div_want_rem  = (ex_alu_op == `ALU_REM) || (ex_alu_op == `ALU_REMU);
    logic            div_busy, div_done;
    logic [XLEN-1:0] div_result;
    wire             div_start = ex_is_div && !div_busy && !div_done;
    wire             div_stall_w = ex_is_div && !div_done;

    divider #(.XLEN(XLEN)) u_div (
        .clk, .rst_n,
        .start(div_start), .is_signed(div_is_signed), .want_rem(div_want_rem),
        .a(fwd_a), .b(fwd_b),
        .busy(div_busy), .done(div_done), .result(div_result)
    );

    // ---- multi-cycle multiplier (MUL/MULH/MULHSU/MULHU) ---------------------
    wire mul_op    = (ex_alu_op == `ALU_MUL)  || (ex_alu_op == `ALU_MULH) ||
                     (ex_alu_op == `ALU_MULHSU) || (ex_alu_op == `ALU_MULHU);
    wire ex_is_mul = ex_valid && mul_op;
    wire mul_a_signed = (ex_alu_op == `ALU_MUL) || (ex_alu_op == `ALU_MULH) ||
                        (ex_alu_op == `ALU_MULHSU);
    wire mul_b_signed = (ex_alu_op == `ALU_MUL) || (ex_alu_op == `ALU_MULH);
    wire mul_sel_high = (ex_alu_op != `ALU_MUL);     // MUL=low half, MULH*=high
    logic            mul_busy, mul_done;
    logic [XLEN-1:0] mul_result;
    wire             mul_start = ex_is_mul && !mul_busy && !mul_done;
    wire             mul_stall_w = ex_is_mul && !mul_done;

    mul_seq #(.XLEN(XLEN)) u_mul (
        .clk, .rst_n,
        .start(mul_start), .a_is_signed(mul_a_signed), .b_is_signed(mul_b_signed),
        .sel_high(mul_sel_high), .a(fwd_a), .b(fwd_b),
        .busy(mul_busy), .done(mul_done), .result(mul_result)
    );

    // any multi-cycle EX unit in flight freezes the front-end + holds EX
    assign div_stall = div_stall_w || mul_stall_w;

    // EX result feeding EX/MEM: CSR read, else multiply/divide result, else ALU
    // (csr_rdata declared in the CSR block below).
    wire [XLEN-1:0] ex_result = ex_is_csr ? csr_rdata :
                                mul_op    ? mul_result :
                                div_op    ? div_result : alu_y;

    // branch resolution (uses forwarded operands)
    logic eq, lt, ltu, take_branch;
    assign eq  = (fwd_a == fwd_b);
    assign lt  = ($signed(fwd_a) <  $signed(fwd_b));
    assign ltu = (fwd_a < fwd_b);
    always_comb begin
        take_branch = 1'b0;
        if (ex_branch) begin
            unique case (ex_funct3)
                3'b000: take_branch =  eq;
                3'b001: take_branch = ~eq;
                3'b100: take_branch =  lt;
                3'b101: take_branch = ~lt;
                3'b110: take_branch =  ltu;
                3'b111: take_branch = ~ltu;
                default: take_branch = 1'b0;
            endcase
        end
    end

    // actual control outcome
    wire             ex_is_ctrl   = ex_branch || ex_jump;
    wire             actual_taken = ex_jump || (ex_branch && take_branch);
    logic [XLEN-1:0] actual_target;
    always_comb begin
        if      (ex_jalr) actual_target = (fwd_a + ex_imm_alu) & ~32'h1;
        else if (ex_jump) actual_target = ex_pc + ex_imm_j;     // JAL
        else              actual_target = ex_pc + ex_imm_b;     // taken branch
    end
    wire [XLEN-1:0] actual_nextpc = actual_taken    ? actual_target  : (ex_pc + 32'd4);
    wire [XLEN-1:0] pred_nextpc   = ex_pred_taken   ? ex_pred_target : (ex_pc + 32'd4);

    // ------------------------------ CSR access + trap resolution (EX) --------
    logic [XLEN-1:0] csr_rdata, csr_trap_target, csr_mret_target;
    logic            csr_illegal;
    logic [XLEN-1:0] csr_wsrc;
    assign csr_wsrc = ex_csr_is_imm ? {27'b0, ex_rs1} : fwd_a;   // *I uses zimm
    wire csr_we_intent = ex_is_csr && ((ex_csr_op == `CSR_RW) || (ex_rs1 != 5'd0));

    // address-misalignment (effective address == alu_y for loads/stores)
    wire ld_ma = ex_mem_read  && ((ex_funct3==3'b010 && alu_y[1:0]!=2'b00) ||
                                  ((ex_funct3==3'b001||ex_funct3==3'b101) && alu_y[0]));
    wire st_ma = ex_mem_write && ((ex_funct3==3'b010 && alu_y[1:0]!=2'b00) ||
                                  (ex_funct3==3'b001 && alu_y[0]));
    wire insn_ma = actual_taken && (actual_target[1:0] != 2'b00);

    logic            trap;
    logic [XLEN-1:0] trap_cause, trap_tval;
    always_comb begin
        trap = 1'b1;
        if      (!ex_legal)                begin trap_cause = `CAUSE_ILLEGAL_INSN;  trap_tval = '0; end
        else if (ex_is_csr && csr_illegal) begin trap_cause = `CAUSE_ILLEGAL_INSN;  trap_tval = '0; end
        else if (insn_ma)                  begin trap_cause = `CAUSE_INSN_MISALIGN; trap_tval = actual_target; end
        else if (ld_ma)                    begin trap_cause = `CAUSE_LOAD_MISALIGN; trap_tval = alu_y; end
        else if (st_ma)                    begin trap_cause = `CAUSE_STORE_MISALIGN;trap_tval = alu_y; end
        else if (ex_is_ecall)              begin trap_cause = `CAUSE_ECALL_M;       trap_tval = '0; end
        else if (ex_is_ebreak)             begin trap_cause = `CAUSE_BREAKPOINT;    trap_tval = '0; end
        else                               begin trap = 1'b0; trap_cause = '0;      trap_tval = '0; end
    end
    wire ex_trap    = ex_valid && trap;
    wire ex_do_mret = ex_valid && ex_is_mret;

    csr #(.XLEN(XLEN)) u_csr (
        .clk, .rst_n,
        .csr_addr(ex_csr_addr), .csr_op(ex_csr_op), .csr_wsrc(csr_wsrc),
        .csr_we(ex_valid && csr_we_intent),     // module suppresses on csr_illegal
        .csr_rdata(csr_rdata), .csr_illegal(csr_illegal),
        .trap(ex_trap), .trap_cause(trap_cause), .trap_epc(ex_pc), .trap_tval(trap_tval),
        .mret(ex_do_mret),
        .trap_target(csr_trap_target), .mret_target(csr_mret_target),
        .instret_inc(ex_valid && !div_stall && !ex_trap)   // counts EX-stage retirements
    );

    // Redirect on: synchronous trap (-> mtvec), MRET (-> mepc), or a branch
    // mispredict (fetched-next-pc != real-next-pc).
    assign redirect = ex_trap || ex_do_mret ||
                      (ex_valid && (actual_nextpc != pred_nextpc));
    always_comb begin
        if      (ex_trap)    redirect_pc = csr_trap_target;
        else if (ex_do_mret) redirect_pc = csr_mret_target;
        else                 redirect_pc = actual_nextpc;
    end

    // ---- predictor update (train BTB/BHT on resolved control transfers) -----
    wire [BPB-1:0] ex_idx = ex_pc[BPB+1:2];
    integer bi;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (bi = 0; bi < BPN; bi = bi + 1) begin
                btb_valid[bi]  <= 1'b0;
                btb_uncond[bi] <= 1'b0;
                bht[bi]        <= 2'b01;     // weakly not-taken
            end
        end else if (ex_valid && ex_is_ctrl && !ex_trap) begin
            if (actual_taken) begin          // allocate / refresh target on taken
                btb_valid[ex_idx]  <= 1'b1;
                btb_uncond[ex_idx] <= ex_jump;
                btb_tag[ex_idx]    <= ex_pc[XLEN-1:BPB+2];
                btb_target[ex_idx] <= actual_target;
            end
            // 2-bit saturating counter (branches only; jumps use the uncond bit)
            if (ex_branch) begin
                if (actual_taken) bht[ex_idx] <= (bht[ex_idx] == 2'b11) ? 2'b11 : bht[ex_idx] + 2'b01;
                else              bht[ex_idx] <= (bht[ex_idx] == 2'b00) ? 2'b00 : bht[ex_idx] - 2'b01;
            end
        end
    end

    // load-use hazard: a load in EX feeding a source of the instr in ID
    assign stall = ex_valid && ex_mem_read && (ex_rd != 5'd0) &&
                   ((c_uses_rs1 && de_rs1 == ex_rd) ||
                    (c_uses_rs2 && de_rs2 == ex_rd));

    // ====================================================== EX/MEM register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            em_valid     <= 1'b0;
            em_reg_write <= 1'b0;
            em_mem_write <= 1'b0;
            em_rd        <= 5'd0;
        end else if (div_stall) begin
            // insert a bubble into MEM while the divide is still computing
            em_valid     <= 1'b0;
            em_reg_write <= 1'b0;
            em_mem_write <= 1'b0;
        end else begin
            // A trapping instruction still retires (em_valid=1, for RVFI) but its
            // architectural GPR/memory writes are suppressed.
            em_valid     <= ex_valid;
            em_reg_write <= ex_valid && ex_reg_write && !ex_trap;
            em_mem_write <= ex_valid && ex_mem_write && !ex_trap;
            em_alu_y     <= ex_result;          // CSR read / divide result / ALU
            em_pc4       <= ex_pc + 32'd4;
            em_store_data<= fwd_b;
            em_rd        <= ex_rd;
            em_funct3    <= ex_funct3;
            em_wb_sel    <= ex_wb_sel;
        end
    end

    // ============================================================ MEM stage
    logic [1:0] byte_off;
    assign dmem_addr = {em_alu_y[XLEN-1:2], 2'b00};
    assign byte_off  = em_alu_y[1:0];
    assign dmem_we   = em_mem_write;

    always_comb begin
        dmem_be    = 4'b0000;
        dmem_wdata = em_store_data;
        if (em_mem_write) begin
            unique case (em_funct3)
                3'b000: begin dmem_be = 4'b0001 << byte_off; dmem_wdata = em_store_data << (8*byte_off); end
                3'b001: begin dmem_be = 4'b0011 << byte_off; dmem_wdata = em_store_data << (8*byte_off); end
                3'b010: begin dmem_be = 4'b1111;             dmem_wdata = em_store_data; end
                default: dmem_be = 4'b0000;
            endcase
        end
    end

    logic [XLEN-1:0] load_data;
    logic [7:0]      lb_byte;
    logic [15:0]     lh_half;
    always_comb begin
        lb_byte = dmem_rdata[8*byte_off +: 8];
        lh_half = dmem_rdata[16*byte_off[1] +: 16];
        unique case (em_funct3)
            3'b000:  load_data = {{24{lb_byte[7]}},  lb_byte};
            3'b001:  load_data = {{16{lh_half[15]}}, lh_half};
            3'b010:  load_data = dmem_rdata;
            3'b100:  load_data = {24'b0, lb_byte};
            3'b101:  load_data = {16'b0, lh_half};
            default: load_data = dmem_rdata;
        endcase
    end

    // writeback value selection (in MEM, latched into MEM/WB)
    logic [XLEN-1:0] em_wb_data;
    always_comb begin
        unique case (em_wb_sel)
            WB_ALU:  em_wb_data = em_alu_y;
            WB_MEM:  em_wb_data = load_data;
            WB_PC4:  em_wb_data = em_pc4;
            default: em_wb_data = em_alu_y;
        endcase
    end

    // ====================================================== MEM/WB register
    logic [XLEN-1:0] wb_pc_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_valid     <= 1'b0;
            wb_reg_write <= 1'b0;
            wb_rd        <= 5'd0;
            wb_wdata     <= '0;
        end else begin
            wb_valid     <= em_valid;
            wb_reg_write <= em_valid && em_reg_write && (em_rd != 5'd0);
            wb_rd        <= em_rd;
            wb_wdata     <= em_wb_data;
        end
    end

    // ============================================================ WB / RVFI
    assign rvfi_valid = wb_valid;
    assign rvfi_pc    = wb_pc_r;
    assign rvfi_rd    = wb_rd;
    assign rvfi_we    = wb_valid && wb_reg_write;
    assign rvfi_wdata = wb_reg_write ? wb_wdata : '0;

    // carry PC down the pipe for RVFI (debug/trace only)
    logic [XLEN-1:0] em_pc_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            em_pc_r <= '0;
            wb_pc_r <= '0;
        end else begin
            em_pc_r <= ex_pc;
            wb_pc_r <= em_pc_r;
        end
    end
endmodule
