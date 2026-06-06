// soc_top - AXI4-Lite SoC: {external master, DMA} -> round-robin arbiter -> 1xN
// crossbar -> {boot ROM, SRAM, UART, timer, DMA-config}. The external master port
// is driven by the CPU (later) or a directed TB. The DMA is both a bus slave
// (its config registers) and a bus master (its data movement).
// Address map (addr[30:28]):
//   0 ROM(ro)  1 SRAM  2 UART  3 timer  4 DMA-config
`default_nettype none
module soc_top #(
    parameter     ROM_INIT     = "",
    parameter int ROM_WORDS    = 1024,
    parameter int SRAM_WORDS   = 4096,
    parameter int UART_CLKS    = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] m_awaddr,
    input  wire        m_awvalid,
    output wire        m_awready,
    input  wire [31:0] m_wdata,
    input  wire [3:0]  m_wstrb,
    input  wire        m_wvalid,
    output wire        m_wready,
    output wire [1:0]  m_bresp,
    output wire        m_bvalid,
    input  wire        m_bready,
    input  wire [31:0] m_araddr,
    input  wire        m_arvalid,
    output wire        m_arready,
    output wire [31:0] m_rdata,
    output wire [1:0]  m_rresp,
    output wire        m_rvalid,
    input  wire        m_rready,
    output wire        uart_tx,
    output wire        timer_irq
);
    localparam int NM = 2;   // masters: 0 = external, 1 = DMA
    localparam int N  = 5;   // slaves:  0 ROM, 1 SRAM, 2 UART, 3 timer, 4 DMA-cfg

    // ---- master-side packed bus (into arbiter) ----
    wire [NM*32-1:0] mi_awaddr;  wire [NM-1:0] mi_awvalid, mi_awready;
    wire [NM*32-1:0] mi_wdata;   wire [NM*4-1:0] mi_wstrb; wire [NM-1:0] mi_wvalid, mi_wready;
    wire [NM*2-1:0]  mi_bresp;   wire [NM-1:0] mi_bvalid, mi_bready;
    wire [NM*32-1:0] mi_araddr;  wire [NM-1:0] mi_arvalid, mi_arready;
    wire [NM*32-1:0] mi_rdata;   wire [NM*2-1:0] mi_rresp; wire [NM-1:0] mi_rvalid, mi_rready;

    // master 0 = external port
    assign mi_awaddr[0*32+:32] = m_awaddr;  assign mi_awvalid[0] = m_awvalid;  assign m_awready = mi_awready[0];
    assign mi_wdata[0*32+:32]  = m_wdata;   assign mi_wstrb[0*4+:4] = m_wstrb;
    assign mi_wvalid[0] = m_wvalid;         assign m_wready = mi_wready[0];
    assign m_bresp = mi_bresp[0*2+:2];      assign m_bvalid = mi_bvalid[0];    assign mi_bready[0] = m_bready;
    assign mi_araddr[0*32+:32] = m_araddr;  assign mi_arvalid[0] = m_arvalid;  assign m_arready = mi_arready[0];
    assign m_rdata = mi_rdata[0*32+:32];    assign m_rresp = mi_rresp[0*2+:2];
    assign m_rvalid = mi_rvalid[0];         assign mi_rready[0] = m_rready;
    // master 1 = DMA (connected at u_dma)

    // ---- arbiter output -> xbar master ----
    wire [31:0] x_awaddr; wire x_awvalid, x_awready;
    wire [31:0] x_wdata;  wire [3:0] x_wstrb; wire x_wvalid, x_wready;
    wire [1:0]  x_bresp;  wire x_bvalid, x_bready;
    wire [31:0] x_araddr; wire x_arvalid, x_arready;
    wire [31:0] x_rdata;  wire [1:0] x_rresp; wire x_rvalid, x_rready;

    axil_arbiter #(.M(NM)) u_arb (
        .clk, .rst_n,
        .mi_awaddr, .mi_awvalid, .mi_awready, .mi_wdata, .mi_wstrb, .mi_wvalid, .mi_wready,
        .mi_bresp,  .mi_bvalid,  .mi_bready,  .mi_araddr, .mi_arvalid, .mi_arready,
        .mi_rdata,  .mi_rresp,   .mi_rvalid,  .mi_rready,
        .o_awaddr(x_awaddr), .o_awvalid(x_awvalid), .o_awready(x_awready),
        .o_wdata(x_wdata), .o_wstrb(x_wstrb), .o_wvalid(x_wvalid), .o_wready(x_wready),
        .o_bresp(x_bresp), .o_bvalid(x_bvalid), .o_bready(x_bready),
        .o_araddr(x_araddr), .o_arvalid(x_arvalid), .o_arready(x_arready),
        .o_rdata(x_rdata), .o_rresp(x_rresp), .o_rvalid(x_rvalid), .o_rready(x_rready)
    );

    // ---- slave-side packed bus ----
    wire [N*32-1:0] s_awaddr;  wire [N-1:0] s_awvalid, s_awready;
    wire [N*32-1:0] s_wdata;   wire [N*4-1:0] s_wstrb; wire [N-1:0] s_wvalid, s_wready;
    wire [N*2-1:0]  s_bresp;   wire [N-1:0] s_bvalid, s_bready;
    wire [N*32-1:0] s_araddr;  wire [N-1:0] s_arvalid, s_arready;
    wire [N*32-1:0] s_rdata;   wire [N*2-1:0] s_rresp; wire [N-1:0] s_rvalid, s_rready;

    axil_xbar #(.N(N)) u_xbar (
        .clk, .rst_n,
        .m_awaddr(x_awaddr), .m_awvalid(x_awvalid), .m_awready(x_awready),
        .m_wdata(x_wdata), .m_wstrb(x_wstrb), .m_wvalid(x_wvalid), .m_wready(x_wready),
        .m_bresp(x_bresp), .m_bvalid(x_bvalid), .m_bready(x_bready),
        .m_araddr(x_araddr), .m_arvalid(x_arvalid), .m_arready(x_arready),
        .m_rdata(x_rdata), .m_rresp(x_rresp), .m_rvalid(x_rvalid), .m_rready(x_rready),
        .s_awaddr, .s_awvalid, .s_awready, .s_wdata, .s_wstrb, .s_wvalid, .s_wready,
        .s_bresp,  .s_bvalid,  .s_bready,  .s_araddr, .s_arvalid, .s_arready,
        .s_rdata,  .s_rresp,   .s_rvalid,  .s_rready
    );

    // slave 0: boot ROM
    axil_sram #(.DEPTH_WORDS(ROM_WORDS), .READONLY(1'b1), .INIT_FILE(ROM_INIT)) u_rom (
        .clk, .rst_n,
        .awaddr(s_awaddr[0*32+:32]), .awvalid(s_awvalid[0]), .awready(s_awready[0]),
        .wdata(s_wdata[0*32+:32]), .wstrb(s_wstrb[0*4+:4]), .wvalid(s_wvalid[0]), .wready(s_wready[0]),
        .bresp(s_bresp[0*2+:2]), .bvalid(s_bvalid[0]), .bready(s_bready[0]),
        .araddr(s_araddr[0*32+:32]), .arvalid(s_arvalid[0]), .arready(s_arready[0]),
        .rdata(s_rdata[0*32+:32]), .rresp(s_rresp[0*2+:2]), .rvalid(s_rvalid[0]), .rready(s_rready[0])
    );
    // slave 1: SRAM
    axil_sram #(.DEPTH_WORDS(SRAM_WORDS)) u_sram (
        .clk, .rst_n,
        .awaddr(s_awaddr[1*32+:32]), .awvalid(s_awvalid[1]), .awready(s_awready[1]),
        .wdata(s_wdata[1*32+:32]), .wstrb(s_wstrb[1*4+:4]), .wvalid(s_wvalid[1]), .wready(s_wready[1]),
        .bresp(s_bresp[1*2+:2]), .bvalid(s_bvalid[1]), .bready(s_bready[1]),
        .araddr(s_araddr[1*32+:32]), .arvalid(s_arvalid[1]), .arready(s_arready[1]),
        .rdata(s_rdata[1*32+:32]), .rresp(s_rresp[1*2+:2]), .rvalid(s_rvalid[1]), .rready(s_rready[1])
    );
    // slave 2: UART
    axil_uart #(.CLKS_PER_BIT(UART_CLKS)) u_uart (
        .clk, .rst_n,
        .awaddr(s_awaddr[2*32+:32]), .awvalid(s_awvalid[2]), .awready(s_awready[2]),
        .wdata(s_wdata[2*32+:32]), .wstrb(s_wstrb[2*4+:4]), .wvalid(s_wvalid[2]), .wready(s_wready[2]),
        .bresp(s_bresp[2*2+:2]), .bvalid(s_bvalid[2]), .bready(s_bready[2]),
        .araddr(s_araddr[2*32+:32]), .arvalid(s_arvalid[2]), .arready(s_arready[2]),
        .rdata(s_rdata[2*32+:32]), .rresp(s_rresp[2*2+:2]), .rvalid(s_rvalid[2]), .rready(s_rready[2]),
        .uart_tx(uart_tx)
    );
    // slave 3: timer
    axil_timer u_timer (
        .clk, .rst_n,
        .awaddr(s_awaddr[3*32+:32]), .awvalid(s_awvalid[3]), .awready(s_awready[3]),
        .wdata(s_wdata[3*32+:32]), .wstrb(s_wstrb[3*4+:4]), .wvalid(s_wvalid[3]), .wready(s_wready[3]),
        .bresp(s_bresp[3*2+:2]), .bvalid(s_bvalid[3]), .bready(s_bready[3]),
        .araddr(s_araddr[3*32+:32]), .arvalid(s_arvalid[3]), .arready(s_arready[3]),
        .rdata(s_rdata[3*32+:32]), .rresp(s_rresp[3*2+:2]), .rvalid(s_rvalid[3]), .rready(s_rready[3]),
        .irq(timer_irq)
    );
    // DMA: config = slave 4, data master = arbiter master 1
    dma_engine u_dma (
        .clk, .rst_n,
        .s_awaddr(s_awaddr[4*32+:32]), .s_awvalid(s_awvalid[4]), .s_awready(s_awready[4]),
        .s_wdata(s_wdata[4*32+:32]), .s_wstrb(s_wstrb[4*4+:4]), .s_wvalid(s_wvalid[4]), .s_wready(s_wready[4]),
        .s_bresp(s_bresp[4*2+:2]), .s_bvalid(s_bvalid[4]), .s_bready(s_bready[4]),
        .s_araddr(s_araddr[4*32+:32]), .s_arvalid(s_arvalid[4]), .s_arready(s_arready[4]),
        .s_rdata(s_rdata[4*32+:32]), .s_rresp(s_rresp[4*2+:2]), .s_rvalid(s_rvalid[4]), .s_rready(s_rready[4]),
        .m_awaddr(mi_awaddr[1*32+:32]), .m_awvalid(mi_awvalid[1]), .m_awready(mi_awready[1]),
        .m_wdata(mi_wdata[1*32+:32]), .m_wstrb(mi_wstrb[1*4+:4]), .m_wvalid(mi_wvalid[1]), .m_wready(mi_wready[1]),
        .m_bresp(mi_bresp[1*2+:2]), .m_bvalid(mi_bvalid[1]), .m_bready(mi_bready[1]),
        .m_araddr(mi_araddr[1*32+:32]), .m_arvalid(mi_arvalid[1]), .m_arready(mi_arready[1]),
        .m_rdata(mi_rdata[1*32+:32]), .m_rresp(mi_rresp[1*2+:2]), .m_rvalid(mi_rvalid[1]), .m_rready(mi_rready[1]),
        .busy(dma_busy)
    );

    wire [1:0] dma_busy;            // observable, not exported (poll via DMA status reg)
    wire _unused = &{1'b0, dma_busy, 1'b0};
endmodule
`default_nettype wire
