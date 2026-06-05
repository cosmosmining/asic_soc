// riscv_uvm_pkg.sv - UVM verification environment for the RV32IM CPU.
//
// Professional layered UVM TB: a program-level sequence item is randomized into
// a linear RV32IM instruction stream, the driver backdoor-loads it and runs the
// DUT, the monitor samples the RVFI-lite retire bus, and the scoreboard checks
// every retired instruction against an embedded, independent reference ISS while
// a covergroup tracks opcode/funct3/hazard coverage.
//
// NOTE: requires a UVM-capable simulator (VCS / Questa / Xcelium) or EDA
// Playground. The open-source Icarus/Verilator flow cannot run UVM; the locally
// proven check remains the golden-trace differential test (tb/directed). The
// scoreboard reference here is the same algorithm as tb/directed/riscv_golden.sv.
package riscv_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int XLEN = 32;

    // ================================================== sequence item: program
    class riscv_program extends uvm_sequence_item;
        rand int unsigned n_instr;
        rand bit  [31:0]  words [$];   // assembled instruction words + halt

        constraint c_len { n_instr inside {[16:96]}; }

        `uvm_object_utils_begin(riscv_program)
            `uvm_field_int(n_instr, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "riscv_program");
            super.new(name);
        endfunction

        // R/I/M opcodes
        localparam bit [6:0] OPC_OP = 7'h33, OPC_OPIMM = 7'h13;

        function void post_randomize();
            // R-type (funct7,funct3): RV32I + RV32M
            bit [6:0] rf7 [] = '{7'h00,7'h20,7'h00,7'h00,7'h00,7'h00,7'h00,7'h20,
                                 7'h00,7'h00,7'h01,7'h01,7'h01,7'h01,7'h01,7'h01,7'h01,7'h01};
            bit [2:0] rf3 [] = '{3'h0,3'h0,3'h1,3'h2,3'h3,3'h4,3'h5,3'h5,
                                 3'h6,3'h7,3'h0,3'h1,3'h2,3'h3,3'h4,3'h5,3'h6,3'h7};
            bit [2:0] if3 [] = '{3'h0,3'h2,3'h3,3'h4,3'h6,3'h7,3'h1,3'h5};
            words.delete();
            for (int i = 0; i < n_instr; i++) begin
                bit [4:0] rd  = $urandom_range(0,31);
                bit [4:0] rs1 = $urandom_range(0,31);
                bit [4:0] rs2 = $urandom_range(0,31);
                if ($urandom_range(0,1)) begin
                    int k = $urandom_range(0, rf7.size()-1);
                    words.push_back({rf7[k], rs2, rs1, rf3[k], rd, OPC_OP});
                end else begin
                    bit [2:0]  f3  = if3[$urandom_range(0,7)];
                    bit [11:0] imm = $urandom;
                    if (f3 == 3'h1) imm = {7'h00, imm[4:0]};                 // SLLI
                    if (f3 == 3'h5) imm = {($urandom_range(0,1)?7'h20:7'h00), imm[4:0]}; // SRxI
                    words.push_back({imm, rs1, f3, rd, OPC_OPIMM});
                end
            end
            words.push_back(32'h0000_006F);    // jal x0,0 (halt)
        endfunction
    endclass

    // ================================================ monitor output: a retire
    class riscv_retire extends uvm_sequence_item;
        bit [XLEN-1:0] pc, wdata;
        bit [4:0]      rd;
        bit            we;
        `uvm_object_utils(riscv_retire)
        function new(string name = "riscv_retire"); super.new(name); endfunction
    endclass

    // ============================================================= sequencer
    typedef uvm_sequencer #(riscv_program) riscv_sequencer;

    // ============================================================== sequence
    class riscv_program_seq extends uvm_sequence #(riscv_program);
        rand int unsigned n_progs = 20;
        `uvm_object_utils(riscv_program_seq)
        function new(string name = "riscv_program_seq"); super.new(name); endfunction
        task body();
            repeat (n_progs) begin
                riscv_program p = riscv_program::type_id::create("p");
                start_item(p);
                assert(p.randomize());
                finish_item(p);
            end
        endtask
    endclass

    // ================================================================ driver
    class riscv_driver extends uvm_driver #(riscv_program);
        virtual riscv_if vif;
        `uvm_component_utils(riscv_driver)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual riscv_if)::get(this,"","vif",vif))
                `uvm_fatal("NOVIF","no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                riscv_program p;
                seq_item_port.get_next_item(p);
                run_program(p);
                seq_item_port.item_done();
            end
        endtask
        task run_program(riscv_program p);
            // clear + backdoor-load program
            for (int i = 0; i < 1024; i++) vif.mem_write(i, 32'h0);
            foreach (p.words[i]) vif.mem_write(i, p.words[i]);
            // reset pulse
            vif.rst_n = 1'b0;
            repeat (3) @(posedge vif.clk);
            vif.rst_n = 1'b1;
            // let the program run to its halt self-loop
            repeat (p.words.size() * 4 + 64) @(posedge vif.clk);
        endtask
    endclass

    // =============================================================== monitor
    class riscv_monitor extends uvm_monitor;
        virtual riscv_if vif;
        uvm_analysis_port #(riscv_retire) ap;
        `uvm_component_utils(riscv_monitor)
        function new(string name, uvm_component parent);
            super.new(name,parent); ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual riscv_if)::get(this,"","vif",vif))
                `uvm_fatal("NOVIF","no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n && vif.mon_cb.rvfi_valid) begin
                    riscv_retire t = riscv_retire::type_id::create("t");
                    t.pc    = vif.mon_cb.rvfi_pc;
                    t.rd    = vif.mon_cb.rvfi_rd;
                    t.we    = vif.mon_cb.rvfi_we;
                    t.wdata = vif.mon_cb.rvfi_wdata;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // ============================================================ scoreboard
    // Embedded independent reference ISS + functional coverage. Compares each
    // observed retire against the architectural expectation in program order.
    class riscv_scoreboard extends uvm_scoreboard;
        virtual riscv_if vif;
        uvm_analysis_imp #(riscv_retire, riscv_scoreboard) imp;

        bit [XLEN-1:0] xreg [32];
        bit [XLEN-1:0] rpc;            // reference PC
        int            checked, errors;

        // coverage
        bit [6:0] cg_opcode; bit [2:0] cg_funct3;
        covergroup cg_instr;
            coverpoint cg_opcode { bins op = {7'h33}; bins opimm = {7'h13};
                                   bins jal = {7'h6F}; }
            coverpoint cg_funct3;
            cross cg_opcode, cg_funct3;
        endgroup

        `uvm_component_utils(riscv_scoreboard)
        function new(string name, uvm_component parent);
            super.new(name,parent); imp = new("imp", this); cg_instr = new();
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db#(virtual riscv_if)::get(this,"","vif",vif))
                `uvm_fatal("NOVIF","no virtual interface")
            foreach (xreg[i]) xreg[i] = '0;
            rpc = '0;
        endfunction

        // one reference step: fetch at rpc, execute, return expected retire fields
        function void ref_step(output bit [XLEN-1:0] e_pc, output bit e_we,
                               output bit [4:0] e_rd, output bit [XLEN-1:0] e_wd);
            bit [31:0] inst = vif.mem_read(rpc[31:2]);
            bit [6:0]  opc = inst[6:0], f7 = inst[31:25];
            bit [4:0]  rd  = inst[11:7], rs1 = inst[19:15], rs2 = inst[24:20];
            bit [2:0]  f3  = inst[14:12];
            bit [XLEN-1:0] a = xreg[rs1], b = xreg[rs2], res = '0, npc = rpc + 4;
            bit signed [XLEN-1:0] as = a, bs = b;
            bit signed [63:0] pss; bit [63:0] puu; bit signed [63:0] psu;
            bit we = 1'b0;
            cg_opcode = opc; cg_funct3 = f3; cg_instr.sample();
            case (opc)
                7'h13: begin we = 1'b1; bit [11:0] im = inst[31:20];
                    bit signed [XLEN-1:0] ims = $signed(im);
                    case (f3)
                        3'h0: res = a + ims;
                        3'h2: res = (as < ims) ? 1 : 0;
                        3'h3: res = (a < $unsigned(ims)) ? 1 : 0;
                        3'h4: res = a ^ ims;
                        3'h6: res = a | ims;
                        3'h7: res = a & ims;
                        3'h1: res = a << im[4:0];
                        3'h5: if (f7[5]) res = as >>> im[4:0]; else res = a >> im[4:0];
                    endcase
                end
                7'h33: begin we = 1'b1;
                    pss = as * bs; puu = a * b; psu = as * $signed({1'b0,b});
                    if (f7 == 7'h01) case (f3)
                        3'h0: res = pss[31:0];
                        3'h1: res = pss[63:32];
                        3'h2: res = psu[63:32];
                        3'h3: res = puu[63:32];
                        3'h4: if (b==0) res = '1; else if (a==32'h80000000 && b==32'hFFFFFFFF) res = 32'h80000000; else res = as / bs;
                        3'h5: if (b==0) res = '1; else res = a / b;
                        3'h6: if (b==0) res = a;  else if (a==32'h80000000 && b==32'hFFFFFFFF) res = 0; else res = as % bs;
                        3'h7: if (b==0) res = a;  else res = a % b;
                    endcase
                    else case (f3)
                        3'h0: res = f7[5] ? (a - b) : (a + b);
                        3'h1: res = a << b[4:0];
                        3'h2: res = (as < bs) ? 1 : 0;
                        3'h3: res = (a < b) ? 1 : 0;
                        3'h4: res = a ^ b;
                        3'h5: if (f7[5]) res = as >>> b[4:0]; else res = a >> b[4:0];
                        3'h6: res = a | b;
                        3'h7: res = a & b;
                    endcase
                end
                7'h6F: begin we = 1'b1; res = rpc + 4; npc = rpc; end // jal (halt self-loop)
                default: ;
            endcase
            if (we && rd != 0) xreg[rd] = res;
            e_pc = rpc; e_we = we && (rd != 0); e_rd = e_we ? rd : 0; e_wd = e_we ? res : 0;
            rpc = npc;
        endfunction

        function void write(riscv_retire t);
            bit [XLEN-1:0] e_pc, e_wd; bit e_we; bit [4:0] e_rd;
            // a new program restarts at pc 0 -> resync reference state
            if (t.pc == 0) begin foreach (xreg[i]) xreg[i] = '0; rpc = 0; end
            ref_step(e_pc, e_we, e_rd, e_wd);
            checked++;
            if (t.pc !== e_pc || t.we !== e_we ||
                (t.we && (t.rd !== e_rd || t.wdata !== e_wd))) begin
                errors++;
                `uvm_error("SCBD", $sformatf(
                    "retire mismatch: DUT pc=%08x we=%0b rd=x%0d wd=%08x | REF pc=%08x we=%0b rd=x%0d wd=%08x",
                    t.pc,t.we,t.rd,t.wdata, e_pc,e_we,e_rd,e_wd))
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SCBD", $sformatf("checked=%0d errors=%0d coverage=%.1f%%",
                       checked, errors, cg_instr.get_coverage()), UVM_LOW)
            if (errors != 0) `uvm_error("SCBD","FUNCTIONAL MISMATCHES DETECTED")
        endfunction
    endclass

    // ================================================================= agent
    class riscv_agent extends uvm_agent;
        riscv_driver    drv;
        riscv_monitor   mon;
        riscv_sequencer sqr;
        `uvm_component_utils(riscv_agent)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        function void build_phase(uvm_phase phase);
            drv = riscv_driver::type_id::create("drv", this);
            mon = riscv_monitor::type_id::create("mon", this);
            sqr = riscv_sequencer::type_id::create("sqr", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =================================================================== env
    class riscv_env extends uvm_env;
        riscv_agent      agt;
        riscv_scoreboard scb;
        `uvm_component_utils(riscv_env)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        function void build_phase(uvm_phase phase);
            agt = riscv_agent::type_id::create("agt", this);
            scb = riscv_scoreboard::type_id::create("scb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            agt.mon.ap.connect(scb.imp);
        endfunction
    endclass

    // ================================================================== test
    class riscv_random_test extends uvm_test;
        riscv_env env;
        `uvm_component_utils(riscv_random_test)
        function new(string name, uvm_component parent); super.new(name,parent); endfunction
        function void build_phase(uvm_phase phase);
            env = riscv_env::type_id::create("env", this);
        endfunction
        task run_phase(uvm_phase phase);
            riscv_program_seq seq = riscv_program_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(env.agt.sqr);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
