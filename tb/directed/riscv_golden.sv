// riscv_golden.sv - independent behavioral RV32IM + Zicsr/M-mode ISS (TB-only).
// Purpose: a reference implementation written separately from the RTL so a
// differential ("golden-trace") comparison catches RTL microarchitecture bugs.
// At time 0 it executes the program to completion and publishes the expected
// retire trace (one entry per committed instruction, in program order).
//
// Models, in addition to base RV32IM:
//   - Zicsr instructions (CSRRW/S/C and *I forms) over an M-mode CSR subset.
//   - Synchronous traps: illegal instruction, ECALL, EBREAK, and
//     instruction/load/store address-misaligned. MRET returns via mepc.
//   - The minstret performance counter (architectural; mcycle is
//     microarchitecture-dependent and therefore not part of the trace).
//
// Trace/trap convention: every executed instruction emits exactly one retire
// record at its PC; a trapping instruction records with we=0 (no GPR write).
// Counters: minstret counts non-trapping retirements; a CSR read returns the
// pre-increment value (the count of strictly-older retired instructions).
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
        string       progfile;
        logic [31:0] pc, npc, inst;
        logic [6:0]  opc, f7;
        logic [4:0]  rd, rs1, rs2;
        logic [2:0]  f3;
        logic [31:0] a, b, imm_i, imm_s, imm_b, imm_u, imm_j;
        logic [31:0] addr, word, res;
        logic signed [31:0] a_s, b_s;   // signed views (iverilog needs a real
                                        // signed var, not a $signed() cast, for
                                        // reliable >>> / signed compares)
        logic        we, taken;
        logic [1:0]  boff;
        logic signed [63:0] As, Bs, pss, psu;
        logic        [63:0] Au, Bu, puu;

        // ---- M-mode CSR state ----
        logic        st_mie, st_mpie;
        logic [31:0] mtvec, mscratch, mepc, mcause, mtval, mie;
        logic [63:0] minstret, mcycle;
        // ---- per-step trap / system bookkeeping ----
        logic        legal, trap, do_mret;
        logic [31:0] tcause, ttval, ttarget;
        logic [11:0] csr_a;
        logic [31:0] csr_old, csr_new, csr_src;
        logic        csr_wen, csr_ro, csr_impl;

        for (i = 0; i < WORDS; i = i + 1) gmem[i] = 32'h0;
        for (i = 0; i < 32;    i = i + 1) xreg[i] = 32'h0;
        if (!$value$plusargs("PROG=%s", progfile)) progfile = PROG;
        $readmemh(progfile, gmem);

        pc       = RESET_PC;
        n_exp    = 0;
        st_mie   = 1'b0; st_mpie = 1'b0;
        mtvec    = 32'h0; mscratch = 32'h0; mepc = 32'h0;
        mcause   = 32'h0; mtval    = 32'h0; mie  = 32'h0;
        minstret = 64'h0; mcycle   = 64'h0;

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
            a_s = a;
            b_s = b;

            we    = 1'b0;
            res   = 32'h0;
            npc   = pc + 32'd4;
            legal = 1'b1;
            trap  = 1'b0;
            do_mret = 1'b0;
            tcause = 32'h0; ttval = 32'h0;

            // ----------------------- decode legality (mirrors RTL exactly) ---
            case (opc)
                7'b0110111, 7'b0010111, 7'b1101111: legal = 1'b1;     // LUI/AUIPC/JAL
                7'b1100111: legal = (f3 == 3'b000);                   // JALR
                7'b1100011: legal = (f3 != 3'b010 && f3 != 3'b011);   // BRANCH
                7'b0000011: legal = (f3==3'b000||f3==3'b001||f3==3'b010||
                                     f3==3'b100||f3==3'b101);         // LOAD
                7'b0100011: legal = (f3==3'b000||f3==3'b001||f3==3'b010); // STORE
                7'b0010011: begin                                     // OP-IMM
                    if      (f3 == 3'b001) legal = (f7 == 7'b0000000);            // SLLI
                    else if (f3 == 3'b101) legal = (f7==7'b0000000||f7==7'b0100000); // SR*I
                    else                    legal = 1'b1;
                end
                7'b0110011: begin                                     // OP
                    if      (f7 == 7'b0000001) legal = 1'b1;          // M-ext
                    else if (f7 == 7'b0000000) legal = 1'b1;
                    else if (f7 == 7'b0100000) legal = (f3==3'b000||f3==3'b101); // SUB/SRA
                    else                        legal = 1'b0;
                end
                7'b0001111: legal = (f3==3'b000||f3==3'b001);         // FENCE/FENCE.I
                7'b1110011: begin                                     // SYSTEM
                    if (f3 == 3'b000)
                        legal = (inst[31:20]==12'h000 || inst[31:20]==12'h001 ||
                                 inst[31:20]==12'h302 || inst[31:20]==12'h105);
                    else
                        legal = (f3 != 3'b100);                       // CSR ops (not f3=100)
                end
                default: legal = 1'b0;
            endcase

            if (!legal) begin
                trap = 1'b1; tcause = 32'd2; ttval = 32'h0;           // illegal instruction
            end else begin
                case (opc)
                7'b0110111: begin we = 1'b1; res = imm_u; end                 // LUI
                7'b0010111: begin we = 1'b1; res = pc + imm_u; end            // AUIPC
                7'b1101111: begin                                            // JAL
                    ttarget = pc + imm_j;
                    if (ttarget[1:0] != 2'b00) begin trap=1'b1; tcause=32'd0; ttval=ttarget; end
                    else begin we = 1'b1; res = pc + 32'd4; npc = ttarget; end
                end
                7'b1100111: begin                                            // JALR
                    ttarget = (a + imm_i) & ~32'h1;
                    if (ttarget[1:0] != 2'b00) begin trap=1'b1; tcause=32'd0; ttval=ttarget; end
                    else begin we = 1'b1; res = pc + 32'd4; npc = ttarget; end
                end
                7'b1100011: begin                                            // BRANCH
                    case (f3)
                        3'b000: taken = (a == b);
                        3'b001: taken = (a != b);
                        3'b100: taken = (a_s <  b_s);
                        3'b101: taken = (a_s >= b_s);
                        3'b110: taken = (a <  b);
                        3'b111: taken = (a >= b);
                        default: taken = 1'b0;
                    endcase
                    if (taken) begin
                        ttarget = pc + imm_b;
                        if (ttarget[1:0] != 2'b00) begin trap=1'b1; tcause=32'd0; ttval=ttarget; end
                        else npc = ttarget;
                    end
                end
                7'b0000011: begin                                            // LOAD
                    addr = a + imm_i;
                    boff = addr[1:0];
                    if ((f3==3'b010 && addr[1:0]!=2'b00) ||
                        ((f3==3'b001||f3==3'b101) && addr[0]!=1'b0)) begin
                        trap=1'b1; tcause=32'd4; ttval=addr;                  // load misaligned
                    end else begin
                        we   = 1'b1;
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
                end
                7'b0100011: begin                                            // STORE
                    addr = a + imm_s;
                    boff = addr[1:0];
                    if ((f3==3'b010 && addr[1:0]!=2'b00) ||
                        (f3==3'b001 && addr[0]!=1'b0)) begin
                        trap=1'b1; tcause=32'd6; ttval=addr;                  // store misaligned
                    end else begin
                        word = gmem[addr[31:2]];
                        case (f3)
                            3'b000: word[8*boff  +: 8]  = b[7:0];   // SB
                            3'b001: word[16*boff[1] +: 16] = b[15:0]; // SH
                            3'b010: word = b;                       // SW
                            default: ;
                        endcase
                        gmem[addr[31:2]] = word;
                    end
                end
                7'b0010011: begin                                            // OP-IMM
                    we = 1'b1;
                    case (f3)
                        3'b000: res = a + imm_i;                              // ADDI
                        3'b010: res = (a_s < $signed(imm_i)) ? 32'd1 : 32'd0; // SLTI
                        3'b011: res = (a < imm_i) ? 32'd1 : 32'd0;            // SLTIU
                        3'b100: res = a ^ imm_i;                              // XORI
                        3'b110: res = a | imm_i;                              // ORI
                        3'b111: res = a & imm_i;                              // ANDI
                        3'b001: res = a << imm_i[4:0];                        // SLLI
                        3'b101: if (f7[5]) res = a_s >>> imm_i[4:0];          // SRAI
                                else       res = a   >>  imm_i[4:0];          // SRLI
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
                            3'b100: if (b == 32'h0)                          res = 32'hFFFFFFFF;  // DIV
                                    else if (a==32'h80000000 && b==32'hFFFFFFFF) res = 32'h80000000;
                                    else                                        res = a_s / b_s;
                            3'b101: res = (b == 32'h0) ? 32'hFFFFFFFF : (a / b);       // DIVU
                            3'b110: if (b == 32'h0)                          res = a;             // REM
                                    else if (a==32'h80000000 && b==32'hFFFFFFFF) res = 32'h0;
                                    else                                        res = a_s % b_s;
                            3'b111: res = (b == 32'h0) ? a : (a % b);                  // REMU
                            default: res = 32'h0;
                        endcase
                    end else begin
                        case (f3)
                            3'b000: res = f7[5] ? (a - b) : (a + b);          // SUB/ADD
                            3'b001: res = a << b[4:0];                        // SLL
                            3'b010: res = (a_s < b_s) ? 32'd1 : 32'd0;        // SLT
                            3'b011: res = (a < b) ? 32'd1 : 32'd0;            // SLTU
                            3'b100: res = a ^ b;                              // XOR
                            3'b101: if (f7[5]) res = a_s >>> b[4:0];          // SRA
                                    else       res = a   >>  b[4:0];          // SRL
                            3'b110: res = a | b;                             // OR
                            3'b111: res = a & b;                             // AND
                            default: res = 32'h0;
                        endcase
                    end
                end
                7'b0001111: ;                                                // FENCE: NOP
                7'b1110011: begin                                            // SYSTEM
                    if (f3 == 3'b000) begin
                        case (inst[31:20])
                            12'h000: begin trap=1'b1; tcause=32'd11; ttval=32'h0; end // ECALL
                            12'h001: begin trap=1'b1; tcause=32'd3;  ttval=32'h0; end // EBREAK
                            12'h302: begin do_mret = 1'b1; npc = mepc; end            // MRET
                            12'h105: ;                                               // WFI: NOP
                            default: ;
                        endcase
                    end else begin                                          // CSR R/W
                        csr_a   = inst[31:20];
                        csr_src = f3[2] ? {27'h0, rs1} : a;                  // *I uses zimm
                        // address legality (implemented set / write-to-RO)
                        case (csr_a)
                            12'h300,12'h301,12'h304,12'h305,12'h340,12'h341,
                            12'h342,12'h343,12'h344,12'hB00,12'hB02,12'hB80,
                            12'hB82,12'hF11,12'hF12,12'hF13,12'hF14: csr_impl = 1'b1;
                            default:                                 csr_impl = 1'b0;
                        endcase
                        csr_wen = (f3[1:0]==2'b01) ? 1'b1 :                  // RW always writes
                                  (f3[2] ? (rs1 != 5'd0) : (rs1 != 5'd0));   // RS/RC: src reg/uimm != 0
                        csr_ro  = (csr_a[11:10] == 2'b11);
                        if (!csr_impl || (csr_wen && csr_ro)) begin
                            trap=1'b1; tcause=32'd2; ttval=32'h0;            // illegal
                        end else begin
                            // read current value
                            case (csr_a)
                                12'h300: csr_old = (st_mpie<<7)|32'h00001800|(st_mie<<3);
                                12'h301: csr_old = 32'h40001100;            // misa RV32IM
                                12'h304: csr_old = mie;
                                12'h305: csr_old = mtvec;
                                12'h340: csr_old = mscratch;
                                12'h341: csr_old = mepc;
                                12'h342: csr_old = mcause;
                                12'h343: csr_old = mtval;
                                12'h344: csr_old = 32'h0;                   // mip
                                12'hB00: csr_old = mcycle[31:0];
                                12'hB02: csr_old = minstret[31:0];
                                12'hB80: csr_old = mcycle[63:32];
                                12'hB82: csr_old = minstret[63:32];
                                12'hF14: csr_old = 32'h0;                   // mhartid
                                default: csr_old = 32'h0;
                            endcase
                            we  = 1'b1; res = csr_old;
                            case (f3[1:0])
                                2'b01:   csr_new = csr_src;
                                2'b10:   csr_new = csr_old |  csr_src;
                                2'b11:   csr_new = csr_old & ~csr_src;
                                default: csr_new = csr_old;
                            endcase
                            if (csr_wen) begin
                                case (csr_a)
                                    12'h300: begin st_mie = csr_new[3]; st_mpie = csr_new[7]; end
                                    12'h304: mie      = csr_new & 32'h00000888;
                                    12'h305: mtvec    = csr_new;
                                    12'h340: mscratch = csr_new;
                                    12'h341: mepc     = {csr_new[31:1],1'b0};
                                    12'h342: mcause   = csr_new;
                                    12'h343: mtval    = csr_new;
                                    12'hB00: mcycle[31:0]    = csr_new;
                                    12'hB02: minstret[31:0]  = csr_new;
                                    12'hB80: mcycle[63:32]   = csr_new;
                                    12'hB82: minstret[63:32] = csr_new;
                                    default: ;                              // misa/RO WARL
                                endcase
                            end
                        end
                    end
                end
                default: ; // unreachable (illegal caught above)
                endcase
            end

            // ----------------------- trap entry overrides effects ------------
            if (trap) begin
                we    = 1'b0;                       // no architectural GPR write
                mepc  = {pc[31:1], 1'b0};
                mcause= tcause;
                mtval = ttval;
                st_mpie = st_mie;
                st_mie  = 1'b0;
                npc   = {mtvec[31:2], 2'b00};       // direct mode
            end else if (do_mret) begin
                st_mie  = st_mpie;
                st_mpie = 1'b1;
            end

            // ----------------------- commit + retire record ------------------
            if (we && rd != 5'd0) xreg[rd] = res;

            exp_pc[n_exp] = pc;
            exp_we[n_exp] = we && (rd != 5'd0);
            exp_rd[n_exp] = (we && rd != 5'd0) ? rd  : 5'd0;
            exp_wd[n_exp] = (we && rd != 5'd0) ? res : 32'h0;
            n_exp = n_exp + 1;

            // counters: minstret counts non-trapping retirements (post-read)
            mcycle = mcycle + 64'd1;
            if (!trap) minstret = minstret + 64'd1;

            if (npc == pc) begin
                step = MAXSTEPS;       // halt: self-loop reached
            end else begin
                pc = npc;
            end
        end
        $display("[golden] generated %0d expected retire records from %s", n_exp, PROG);
    end
endmodule
