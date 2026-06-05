// riscv_core_sva.sv - SVA properties bound into the RV32IM core.
// Bound (not edited into RTL) so formal/sim can include or drop them freely.
// Use:  bind riscv_core riscv_core_sva u_sva (.*);
module riscv_core_sva #(
    parameter int XLEN = 32
) (
    input logic            clk,
    input logic            rst_n,
    input logic [XLEN-1:0] imem_addr,
    input logic [XLEN-1:0] dmem_addr,
    input logic [3:0]      dmem_be,
    input logic            dmem_we,
    input logic [XLEN-1:0] dbg_pc
);
    // PC is always word-aligned.
    a_pc_aligned: assert property (@(posedge clk) disable iff (!rst_n)
        imem_addr[1:0] == 2'b00)
        else $error("PC not word-aligned: 0x%08x", imem_addr);

    // Data address presented to memory is word-aligned (sub-word handled by be).
    a_dmem_aligned: assert property (@(posedge clk) disable iff (!rst_n)
        dmem_addr[1:0] == 2'b00)
        else $error("dmem_addr not word-aligned: 0x%08x", dmem_addr);

    // A store must assert at least one byte-enable.
    a_store_has_be: assert property (@(posedge clk) disable iff (!rst_n)
        dmem_we |-> (dmem_be != 4'b0000))
        else $error("store asserted with zero byte-enable");

    // No X on the program counter once out of reset.
    a_pc_known: assert property (@(posedge clk) disable iff (!rst_n)
        !$isunknown(dbg_pc))
        else $error("PC is X/Z out of reset");
endmodule
