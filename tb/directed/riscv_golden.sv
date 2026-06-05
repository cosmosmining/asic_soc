// riscv_golden.sv - independent behavioral RV32IM ISS (testbench-only).
// Purpose: a reference implementation written separately from the RTL so a
// differential ("golden-trace") comparison catches RTL microarchitecture bugs.
// At time 0 it executes the program to completion and publishes the expected
// retire trace (one entry per committed instruction, in program order).
//
// Halt convention: an instruction whose next-PC equals its own PC (e.g. the
// `jal x0, 0` self-loop) terminates trace generation.
module riscv_golden #(
    parameter int    XLEN     = 32,
    parameter int    WORDS    = 1024,
    parameter int    MAXSTEPS = 4096,
    parameter string PROG     = "tb/directed/programs/test_core.hex",
    parameter logic [31:0] RESET_PC = 32'h0000_0000
)();
    // architectural state
    logic [31:0] gmem [0:WORDS-1];
    logic [31:0] xreg [0:31];

    // published expected trace
    integer      n_exp;
    logic [31:0] exp_pc [0:MAXSTEPS-1];
    logic [4:0]  exp_rd [0:MAXSTEPS-1];
    logic        exp_we [0:MAXSTEPS-1];
    logic [31:0] exp_wd [0:MAXSTEPS-1];

    initial begin : iss
        integer      i, step;
        logic [31:0] pc, npc, inst;
        logic [6:0]  opc, f7;
        logic [4:0]  rd, rs1, rs2;
        logic [2:0]  f3;
        logic [31:0] a, b, imm_i, imm_s, imm_b, imm_u, imm_j;
        logic [31:0] addr, word, res;
        logic        we, taken;
        logic [1:0]  boff;
        logic signed [63:0] As, Bs, pss, psu;
        logic        [63:0] Au, Bu, puu;

        for (i = 0; i < WORDS; i = i + 1) gmem[i] = 32'h0;
        for (i = 0; i < 32;    i = i + 1) xreg[i] = 32'h0;
        $readmemh(PROG, gmem);

        pc    = RESET_PC;
        n_exp = 0;

        for (step = 0; step < MAXSTEPS; step = step + 1) begin
            inst = gmem[pc[31:2]];
            opc  = inst[6:0];
            rd   = inst[11:7];
            f3   = inst[14:12];
            rs1  = inst[19:15];
            rs2  = inst[24:20];
            f7   = inst[31:25];

            imm_i = {{20{inst[31]}}, inst[31:20]};
            imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
            imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
            imm_u = {inst[31:12], 12'b0};
            imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

            a = xreg[rs1];
            b = xreg[rs2];

            we    = 1'b0;
            res   = 32'h0;
            npc   = pc + 32'd4;

            case (opc)
                7'b0110111: begin we = 1'b1; res = imm_u; end                 // LUI
                7'b0010111: begin we = 1'b1; res = pc + imm_u; end            // AUIPC
                7'b1101111: begin we = 1'b1; res = pc + 32'd4; npc = pc + imm_j; end // JAL
                7'b1100111: begin we = 1'b1; res = pc + 32'd4;                 // JALR
                              npc = (a + imm_i) & ~32'h1; end
                7'b1100011: begin                                             // BRANCH
                    case (f3)
                        3'b000: taken = (a == b);
                        3'b001: taken = (a != b);
                        3'b100: taken = ($signed(a) <  $signed(b));
                        3'b101: taken = ($signed(a) >= $signed(b));
                        3'b110: taken = (a <  b);
                        3'b111: taken = (a >= b);
                        default: taken = 1'b0;
                    endcase
                    if (taken) npc = pc + imm_b;
                end
                7'b0000011: begin                                             // LOAD
                    we   = 1'b1;
                    addr = a + imm_i;
                    boff = addr[1:0];
                    word = gmem[addr[31:2]];
                    case (f3)
                        3'b000: res = {{24{word[8*boff+7]}}, word[8*boff +: 8]};      // LB
                        3'b001: res = {{16{word[16*boff[1]+15]}}, word[16*boff[1] +: 16]}; // LH
                        3'b010: res = word;                                          // LW
                        3'b100: res = {24'b0, word[8*boff +: 8]};                    // LBU
                        3'b101: res = {16'b0, word[16*boff[1] +: 16]};               // LHU
                        default: res = word;
                    endcase
                end
                7'b0100011: begin                                             // STORE
                    addr = a + imm_s;
                    boff = addr[1:0];
                    word = gmem[addr[31:2]];
                    case (f3)
                        3'b000: word[8*boff  +: 8]  = b[7:0];   // SB
                        3'b001: word[16*boff[1] +: 16] = b[15:0]; // SH
                        3'b010: word = b;                       // SW
                        default: ;
                    endcase
                    gmem[addr[31:2]] = word;
                end
                7'b0010011: begin                                            // OP-IMM
                    we = 1'b1;
                    case (f3)
                        3'b000: res = a + imm_i;                              // ADDI
                        3'b010: res = ($signed(a) < $signed(imm_i)) ? 32'd1 : 32'd0; // SLTI
                        3'b011: res = (a < imm_i) ? 32'd1 : 32'd0;            // SLTIU
                        3'b100: res = a ^ imm_i;                              // XORI
                        3'b110: res = a | imm_i;                              // ORI
                        3'b111: res = a & imm_i;                              // ANDI
                        3'b001: res = a << imm_i[4:0];                        // SLLI
                        3'b101: res = f7[5] ? ($signed(a) >>> imm_i[4:0])     // SRAI
                                            : (a >> imm_i[4:0]);              // SRLI
                        default: res = 32'h0;
                    endcase
                end
                7'b0110011: begin                                            // OP
                    we = 1'b1;
                    As = {{32{a[31]}}, a};  Bs = {{32{b[31]}}, b};
                    Au = {32'b0, a};        Bu = {32'b0, b};
                    pss = As * Bs;  psu = As * $signed(Bu);  puu = Au * Bu;
                    if (f7 == 7'b0000001) begin                              // M-ext
                        case (f3)
                            3'b000: res = pss[31:0];        // MUL
                            3'b001: res = pss[63:32];       // MULH
                            3'b010: res = psu[63:32];       // MULHSU
                            3'b011: res = puu[63:32];       // MULHU
                            default: res = 32'h0;           // DIV/REM TODO
                        endcase
                    end else begin
                        case (f3)
                            3'b000: res = f7[5] ? (a - b) : (a + b);          // SUB/ADD
                            3'b001: res = a << b[4:0];                        // SLL
                            3'b010: res = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0; // SLT
                            3'b011: res = (a < b) ? 32'd1 : 32'd0;            // SLTU
                            3'b100: res = a ^ b;                              // XOR
                            3'b101: res = f7[5] ? ($signed(a) >>> b[4:0])     // SRA
                                                : (a >> b[4:0]);              // SRL
                            3'b110: res = a | b;                             // OR
                            3'b111: res = a & b;                             // AND
                            default: res = 32'h0;
                        endcase
                    end
                end
                default: ; // NOP / unsupported
            endcase

            // commit to architectural regfile (x0 stays 0)
            if (we && rd != 5'd0) xreg[rd] = res;

            // record retire entry
            exp_pc[n_exp] = pc;
            exp_we[n_exp] = we && (rd != 5'd0);
            exp_rd[n_exp] = (we && rd != 5'd0) ? rd  : 5'd0;
            exp_wd[n_exp] = (we && rd != 5'd0) ? res : 32'h0;
            n_exp = n_exp + 1;

            if (npc == pc) begin
                step = MAXSTEPS;       // halt: self-loop reached
            end else begin
                pc = npc;
            end
        end
        $display("[golden] generated %0d expected retire records from %s", n_exp, PROG);
    end
endmodule
