// riscv_soc.sv - SoC top: RV32IM pipeline + I-cache + D-cache + AXI4-Lite
// interconnect + AXI4-Lite SRAM.
//
//   pipeline ── imem ──► I$ ─┐                       ┌─► (AXI4-Lite)
//            ── dmem ──► D$ ─┴─► axil_arb (2:1) ─────┴─► axi_sram
//
// The caches turn the core's stall-capable imem/dmem ports into AXI4-Lite line
// fills / write-throughs; the interconnect shares the single SRAM. The program
// image lives in u_sram.mem (load it with $readmemh from a testbench).
module riscv_soc #(
    parameter int XLEN       = 32,
    parameter int MEM_WORDS  = 4096,     // 16 KiB unified memory
    parameter int IC_LINES   = 64,
    parameter int DC_LINES   = 64,
    parameter int LINE_WORDS = 4
) (
    input  logic            clk,
    input  logic            rst_n,
    // debug / retire visibility (for verification)
    output logic [XLEN-1:0] dbg_pc,
    output logic            rvfi_valid,
    output logic [XLEN-1:0] rvfi_pc,
    output logic [4:0]      rvfi_rd,
    output logic            rvfi_we,
    output logic [XLEN-1:0] rvfi_wdata
);
    // ---------------- core <-> caches ----------------
    logic [XLEN-1:0] imem_addr, imem_rdata;
    logic            imem_ready;
    logic [XLEN-1:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]      dmem_be;
    logic            dmem_we, dmem_re, dmem_ready;

    riscv_pipeline #(.XLEN(XLEN)) u_cpu (
        .clk, .rst_n,
        .imem_addr, .imem_rdata, .imem_ready,
        .dmem_addr, .dmem_wdata, .dmem_be, .dmem_we, .dmem_re, .dmem_rdata, .dmem_ready,
        .dbg_pc,
        .rvfi_valid, .rvfi_pc, .rvfi_rd, .rvfi_we, .rvfi_wdata
    );

    // ---------------- AXI4-Lite: I$ master (m0) ----------------
    logic [XLEN-1:0] ic_araddr;  logic ic_arvalid, ic_arready;
    logic [XLEN-1:0] ic_rdata;   logic [1:0] ic_rresp; logic ic_rvalid, ic_rready;
    logic [XLEN-1:0] ic_awaddr;  logic ic_awvalid, ic_awready;
    logic [XLEN-1:0] ic_wdata;   logic [3:0] ic_wstrb; logic ic_wvalid, ic_wready;
    logic [1:0]      ic_bresp;   logic ic_bvalid, ic_bready;

    riscv_cache #(.AW(XLEN), .DW(XLEN), .LINES(IC_LINES), .LINE_WORDS(LINE_WORDS),
                  .WRITABLE(1'b0)) u_icache (
        .clk, .rst_n,
        .req(1'b1), .we(1'b0), .addr(imem_addr), .wdata('0), .be('0),
        .rdata(imem_rdata), .ready(imem_ready),
        .m_araddr(ic_araddr), .m_arvalid(ic_arvalid), .m_arready(ic_arready),
        .m_rdata(ic_rdata), .m_rresp(ic_rresp), .m_rvalid(ic_rvalid), .m_rready(ic_rready),
        .m_awaddr(ic_awaddr), .m_awvalid(ic_awvalid), .m_awready(ic_awready),
        .m_wdata(ic_wdata), .m_wstrb(ic_wstrb), .m_wvalid(ic_wvalid), .m_wready(ic_wready),
        .m_bresp(ic_bresp), .m_bvalid(ic_bvalid), .m_bready(ic_bready)
    );

    // ---------------- AXI4-Lite: D$ master (m1) ----------------
    logic [XLEN-1:0] dc_araddr;  logic dc_arvalid, dc_arready;
    logic [XLEN-1:0] dc_rdata;   logic [1:0] dc_rresp; logic dc_rvalid, dc_rready;
    logic [XLEN-1:0] dc_awaddr;  logic dc_awvalid, dc_awready;
    logic [XLEN-1:0] dc_wdata;   logic [3:0] dc_wstrb; logic dc_wvalid, dc_wready;
    logic [1:0]      dc_bresp;   logic dc_bvalid, dc_bready;

    riscv_cache #(.AW(XLEN), .DW(XLEN), .LINES(DC_LINES), .LINE_WORDS(LINE_WORDS),
                  .WRITABLE(1'b1)) u_dcache (
        .clk, .rst_n,
        .req(dmem_re || dmem_we), .we(dmem_we), .addr(dmem_addr),
        .wdata(dmem_wdata), .be(dmem_be), .rdata(dmem_rdata), .ready(dmem_ready),
        .m_araddr(dc_araddr), .m_arvalid(dc_arvalid), .m_arready(dc_arready),
        .m_rdata(dc_rdata), .m_rresp(dc_rresp), .m_rvalid(dc_rvalid), .m_rready(dc_rready),
        .m_awaddr(dc_awaddr), .m_awvalid(dc_awvalid), .m_awready(dc_awready),
        .m_wdata(dc_wdata), .m_wstrb(dc_wstrb), .m_wvalid(dc_wvalid), .m_wready(dc_wready),
        .m_bresp(dc_bresp), .m_bvalid(dc_bvalid), .m_bready(dc_bready)
    );

    // ---------------- interconnect -> SRAM ----------------
    logic [XLEN-1:0] s_araddr;  logic s_arvalid, s_arready;
    logic [XLEN-1:0] s_rdata;   logic [1:0] s_rresp; logic s_rvalid, s_rready;
    logic [XLEN-1:0] s_awaddr;  logic s_awvalid, s_awready;
    logic [XLEN-1:0] s_wdata;   logic [3:0] s_wstrb; logic s_wvalid, s_wready;
    logic [1:0]      s_bresp;   logic s_bvalid, s_bready;

    axil_arb #(.AW(XLEN), .DW(XLEN)) u_arb (
        .clk, .rst_n,
        .m0_araddr(ic_araddr), .m0_arvalid(ic_arvalid), .m0_arready(ic_arready),
        .m0_rdata(ic_rdata), .m0_rresp(ic_rresp), .m0_rvalid(ic_rvalid), .m0_rready(ic_rready),
        .m0_awaddr(ic_awaddr), .m0_awvalid(ic_awvalid), .m0_awready(ic_awready),
        .m0_wdata(ic_wdata), .m0_wstrb(ic_wstrb), .m0_wvalid(ic_wvalid), .m0_wready(ic_wready),
        .m0_bresp(ic_bresp), .m0_bvalid(ic_bvalid), .m0_bready(ic_bready),
        .m1_araddr(dc_araddr), .m1_arvalid(dc_arvalid), .m1_arready(dc_arready),
        .m1_rdata(dc_rdata), .m1_rresp(dc_rresp), .m1_rvalid(dc_rvalid), .m1_rready(dc_rready),
        .m1_awaddr(dc_awaddr), .m1_awvalid(dc_awvalid), .m1_awready(dc_awready),
        .m1_wdata(dc_wdata), .m1_wstrb(dc_wstrb), .m1_wvalid(dc_wvalid), .m1_wready(dc_wready),
        .m1_bresp(dc_bresp), .m1_bvalid(dc_bvalid), .m1_bready(dc_bready),
        .s_araddr, .s_arvalid, .s_arready,
        .s_rdata, .s_rresp, .s_rvalid, .s_rready,
        .s_awaddr, .s_awvalid, .s_awready,
        .s_wdata, .s_wstrb, .s_wvalid, .s_wready,
        .s_bresp, .s_bvalid, .s_bready
    );

    axi_sram #(.AW(XLEN), .DW(XLEN), .WORDS(MEM_WORDS)) u_sram (
        .clk, .rst_n,
        .awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wvalid(s_wvalid), .wready(s_wready),
        .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
        .araddr(s_araddr), .arvalid(s_arvalid), .arready(s_arready),
        .rdata(s_rdata), .rresp(s_rresp), .rvalid(s_rvalid), .rready(s_rready)
    );
endmodule
