// csr.sv - machine-mode CSR file (Zicsr + a privileged-spec subset).
//
// Holds the architectural CSR state and provides:
//   - CSR instruction access: combinational read of the addressed CSR + a
//     registered read-modify-write (CSRRW/CSRRS/CSRRC and their *I forms).
//   - Trap entry: latch mepc/mcause/mtval and push the interrupt-enable stack
//     (mstatus.MIE -> MPIE, MIE<-0), exposing the mtvec target to the core.
//   - MRET: pop the stack (MIE<-MPIE, MPIE<-1) and expose mepc to the core.
//   - Performance counters: 64-bit mcycle (every clock) and minstret (every
//     retired instruction). A CSR write to a counter takes precedence over the
//     same-cycle auto-increment.
//
// Only machine mode is implemented, so mstatus.MPP reads a constant 2'b11.
// The core guarantees that at most one of {csr_we, trap, mret} is asserted for
// a given instruction.
`include "riscv_defs.svh"

module csr #(
    parameter int XLEN = 32,
    parameter logic [XLEN-1:0] HARTID = '0
) (
    input  logic            clk,
    input  logic            rst_n,

    // ---- CSR instruction port (read combinational, write registered) -------
    input  logic [11:0]     csr_addr,
    input  logic [1:0]      csr_op,        // CSR_RW / CSR_RS / CSR_RC
    input  logic [XLEN-1:0] csr_wsrc,      // rs1 value or zero-extended uimm
    input  logic            csr_we,        // perform the write side this cycle
    output logic [XLEN-1:0] csr_rdata,     // current value of the addressed CSR
    output logic            csr_illegal,   // unimplemented addr, or write to RO

    // ---- trap / MRET control (registered effects) --------------------------
    input  logic            trap,          // take a synchronous trap this cycle
    input  logic [XLEN-1:0] trap_cause,
    input  logic [XLEN-1:0] trap_epc,
    input  logic [XLEN-1:0] trap_tval,
    input  logic            mret,          // retire an MRET this cycle
    output logic [XLEN-1:0] trap_target,   // {mtvec base, 2'b00} (direct mode)
    output logic [XLEN-1:0] mret_target,   // mepc, for the core to redirect to

    // ---- counters ----------------------------------------------------------
    input  logic            instret_inc    // one real instruction retired
);
    // -------------------------------------------------- architectural state
    logic                mstatus_mie, mstatus_mpie;
    logic [XLEN-1:0]     mtvec, mscratch, mepc, mcause, mtval;
    logic [XLEN-1:0]     mie;                 // MSIE(3)/MTIE(7)/MEIE(11)
    logic [63:0]         mcycle, minstret;

    // -------------------------------------------------- CSR read (combinational)
    // mstatus: only MIE(3), MPIE(7), MPP(12:11)=11 are meaningful here.
    wire [XLEN-1:0] mstatus_rd = (XLEN'(mstatus_mpie) << 7) |
                                 (32'h0000_1800)            |   // MPP = 11
                                 (XLEN'(mstatus_mie)  << 3);

    always_comb begin
        unique case (csr_addr)
            `CSR_MSTATUS : csr_rdata = mstatus_rd;
            `CSR_MISA    : csr_rdata = `MISA_RV32IM;
            `CSR_MIE     : csr_rdata = mie;
            `CSR_MTVEC   : csr_rdata = mtvec;
            `CSR_MSCRATCH: csr_rdata = mscratch;
            `CSR_MEPC    : csr_rdata = mepc;
            `CSR_MCAUSE  : csr_rdata = mcause;
            `CSR_MTVAL   : csr_rdata = mtval;
            `CSR_MIP     : csr_rdata = '0;                 // no pending sources
            `CSR_MCYCLE  : csr_rdata = mcycle[31:0];
            `CSR_MCYCLEH : csr_rdata = mcycle[63:32];
            `CSR_MINSTRET: csr_rdata = minstret[31:0];
            `CSR_MINSTRETH:csr_rdata = minstret[63:32];
            `CSR_MVENDORID,
            `CSR_MARCHID,
            `CSR_MIMPID  : csr_rdata = '0;
            `CSR_MHARTID : csr_rdata = HARTID;
            default      : csr_rdata = '0;
        endcase
    end

    // Address legality: must be implemented; a write to a read-only CSR
    // (addr[11:10]==11) is illegal. misa is WARL here (writes ignored, legal).
    logic addr_implemented;
    always_comb begin
        unique case (csr_addr)
            `CSR_MSTATUS, `CSR_MISA, `CSR_MIE, `CSR_MTVEC, `CSR_MSCRATCH,
            `CSR_MEPC, `CSR_MCAUSE, `CSR_MTVAL, `CSR_MIP, `CSR_MCYCLE,
            `CSR_MCYCLEH, `CSR_MINSTRET, `CSR_MINSTRETH, `CSR_MVENDORID,
            `CSR_MARCHID, `CSR_MIMPID, `CSR_MHARTID: addr_implemented = 1'b1;
            default:                                 addr_implemented = 1'b0;
        endcase
    end
    assign csr_illegal = !addr_implemented ||
                         (csr_we && (csr_addr[11:10] == 2'b11));   // RO write

    // Read-modify-write next value for the addressed CSR.
    logic [XLEN-1:0] csr_wval;
    always_comb begin
        unique case (csr_op)
            `CSR_RW: csr_wval = csr_wsrc;
            `CSR_RS: csr_wval = csr_rdata |  csr_wsrc;
            `CSR_RC: csr_wval = csr_rdata & ~csr_wsrc;
            default: csr_wval = csr_rdata;
        endcase
    end
    wire do_write = csr_we && !csr_illegal;

    // -------------------------------------------------- targets to the core
    assign trap_target = {mtvec[XLEN-1:2], 2'b00};   // direct mode
    assign mret_target = mepc;

    // -------------------------------------------------- registered next state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mtvec        <= '0;
            mscratch     <= '0;
            mepc         <= '0;
            mcause       <= '0;
            mtval        <= '0;
            mie          <= '0;
            mcycle       <= '0;
            minstret     <= '0;
        end else begin
            // --- counters: an explicit write wins over the auto-increment ---
            if      (do_write && csr_addr == `CSR_MCYCLE)  mcycle <= {mcycle[63:32], csr_wval};
            else if (do_write && csr_addr == `CSR_MCYCLEH) mcycle <= {csr_wval, mcycle[31:0]};
            else                                           mcycle <= mcycle + 64'd1;

            if      (do_write && csr_addr == `CSR_MINSTRET)  minstret <= {minstret[63:32], csr_wval};
            else if (do_write && csr_addr == `CSR_MINSTRETH) minstret <= {csr_wval, minstret[31:0]};
            else if (instret_inc)                            minstret <= minstret + 64'd1;

            // --- trap entry / MRET / ordinary CSR writes (mutually exclusive) ---
            if (trap) begin
                mepc         <= {trap_epc[XLEN-1:1], 1'b0};   // IALIGN=32 -> [1:0]=0
                mcause       <= trap_cause;
                mtval        <= trap_tval;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (do_write) begin
                unique case (csr_addr)
                    `CSR_MSTATUS : begin
                        mstatus_mie  <= csr_wval[3];
                        mstatus_mpie <= csr_wval[7];
                    end
                    `CSR_MIE     : mie      <= csr_wval & 32'h0000_0888; // MSIE/MTIE/MEIE
                    `CSR_MTVEC   : mtvec    <= csr_wval;
                    `CSR_MSCRATCH: mscratch <= csr_wval;
                    `CSR_MEPC    : mepc     <= {csr_wval[XLEN-1:1], 1'b0};
                    `CSR_MCAUSE  : mcause   <= csr_wval;
                    `CSR_MTVAL   : mtval    <= csr_wval;
                    default      : ; // misa/mip/counters/RO handled elsewhere or WARL no-op
                endcase
            end
        end
    end
endmodule
