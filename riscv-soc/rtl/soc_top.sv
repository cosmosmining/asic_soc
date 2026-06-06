// soc_top - AXI4-Lite SoC fabric: one master port -> xbar -> {boot ROM, SRAM,
// UART, timer}. The master port is driven by the CPU/DMA arbiter (later) or a
// directed TB master. Address map (by addr[29:28]):
//   0x0000_0000 boot ROM (read-only, INIT)   0x1000_0000 SRAM
//   0x2000_0000 UART                          0x3000_0000 timer
`default_nettype none
module soc_top #(
    parameter     ROM_INIT     = "",
    parameter int ROM_WORDS    = 1024,
    parameter int SRAM_WORDS   = 4096,
    parameter int UART_CLKS    = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    // master port (CPU/DMA/arbiter, or TB)
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
    // peripherals out
    output wire        uart_tx,
    output wire        timer_irq
);
    localparam int N = 4;

    wire [N*32-1:0] s_awaddr;  wire [N-1:0] s_awvalid; wire [N-1:0] s_awready;
    wire [N*32-1:0] s_wdata;   wire [N*4-1:0] s_wstrb; wire [N-1:0] s_wvalid; wire [N-1:0] s_wready;
    wire [N*2-1:0]  s_bresp;   wire [N-1:0] s_bvalid;  wire [N-1:0] s_bready;
    wire [N*32-1:0] s_araddr;  wire [N-1:0] s_arvalid; wire [N-1:0] s_arready;
    wire [N*32-1:0] s_rdata;   wire [N*2-1:0] s_rresp; wire [N-1:0] s_rvalid; wire [N-1:0] s_rready;

    axil_xbar #(.N(N)) u_xbar (
        .clk, .rst_n,
        .m_awaddr, .m_awvalid, .m_awready, .m_wdata, .m_wstrb, .m_wvalid, .m_wready,
        .m_bresp,  .m_bvalid,  .m_bready,  .m_araddr, .m_arvalid, .m_arready,
        .m_rdata,  .m_rresp,   .m_rvalid,  .m_rready,
        .s_awaddr, .s_awvalid, .s_awready, .s_wdata, .s_wstrb, .s_wvalid, .s_wready,
        .s_bresp,  .s_bvalid,  .s_bready,  .s_araddr, .s_arvalid, .s_arready,
        .s_rdata,  .s_rresp,   .s_rvalid,  .s_rready
    );

    // slave 0: boot ROM (read-only, preloaded)
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
endmodule
`default_nettype wire
