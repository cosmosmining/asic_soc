// axil_xbar - AXI4-Lite 1xN interconnect (address decode + response routing).
//
// One master fans out to N slaves. Slave index = m_*addr[28 +: clog2(N)], so the
// SoC map is 0x0=rom(0), 0x1=sram(1), 0x2=uart(2), 0x3=timer(3). Address/data are
// broadcast to all slaves and the VALID/READY are gated by the selected index.
// A per-direction lock (single outstanding read + single outstanding write) holds
// the routed slave from address-accept until the response handshake, so a later
// address can't mis-route an in-flight B/R.
`default_nettype none
module axil_xbar #(
    parameter int N = 4
) (
    input  wire            clk,
    input  wire            rst_n,
    // ---- master side ----
    input  wire [31:0]     m_awaddr,
    input  wire            m_awvalid,
    output wire            m_awready,
    input  wire [31:0]     m_wdata,
    input  wire [3:0]      m_wstrb,
    input  wire            m_wvalid,
    output wire            m_wready,
    output wire [1:0]      m_bresp,
    output wire            m_bvalid,
    input  wire            m_bready,
    input  wire [31:0]     m_araddr,
    input  wire            m_arvalid,
    output wire            m_arready,
    output wire [31:0]     m_rdata,
    output wire [1:0]      m_rresp,
    output wire            m_rvalid,
    input  wire            m_rready,
    // ---- slave side (packed) ----
    output wire [N*32-1:0] s_awaddr,
    output wire [N-1:0]    s_awvalid,
    input  wire [N-1:0]    s_awready,
    output wire [N*32-1:0] s_wdata,
    output wire [N*4-1:0]  s_wstrb,
    output wire [N-1:0]    s_wvalid,
    input  wire [N-1:0]    s_wready,
    input  wire [N*2-1:0]  s_bresp,
    input  wire [N-1:0]    s_bvalid,
    output wire [N-1:0]    s_bready,
    output wire [N*32-1:0] s_araddr,
    output wire [N-1:0]    s_arvalid,
    input  wire [N-1:0]    s_arready,
    input  wire [N*32-1:0] s_rdata,
    input  wire [N*2-1:0]  s_rresp,
    input  wire [N-1:0]    s_rvalid,
    output wire [N-1:0]    s_rready
);
    localparam int SELW = (N > 1) ? $clog2(N) : 1;

    wire [SELW-1:0] aw_sel = m_awaddr[28 +: SELW];
    wire [SELW-1:0] ar_sel = m_araddr[28 +: SELW];

    // ---- write lock ----
    reg              wbusy;
    reg [SELW-1:0]   wsel_q;
    wire [SELW-1:0]  cw = wbusy ? wsel_q : aw_sel;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wbusy <= 1'b0; wsel_q <= '0; end
        else if (!wbusy) begin
            if (m_awvalid && m_awready) begin wbusy <= 1'b1; wsel_q <= aw_sel; end
        end else if (m_bvalid && m_bready) wbusy <= 1'b0;
    end

    // ---- read lock ----
    reg              rbusy;
    reg [SELW-1:0]   rsel_q;
    wire [SELW-1:0]  cr = rbusy ? rsel_q : ar_sel;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rbusy <= 1'b0; rsel_q <= '0; end
        else if (!rbusy) begin
            if (m_arvalid && m_arready) begin rbusy <= 1'b1; rsel_q <= ar_sel; end
        end else if (m_rvalid && m_rready) rbusy <= 1'b0;
    end

    // ---- master-facing response muxes ----
    assign m_awready = s_awready[cw];
    assign m_wready  = s_wready[cw];
    assign m_bvalid  = s_bvalid[cw];
    assign m_bresp   = s_bresp[cw*2 +: 2];
    assign m_arready = s_arready[cr];
    assign m_rvalid  = s_rvalid[cr];
    assign m_rdata   = s_rdata[cr*32 +: 32];
    assign m_rresp   = s_rresp[cr*2 +: 2];

    // ---- slave-facing fan-out ----
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_slv
            assign s_awaddr[i*32 +: 32] = m_awaddr;
            assign s_wdata [i*32 +: 32] = m_wdata;
            assign s_wstrb [i*4  +: 4]  = m_wstrb;
            assign s_araddr[i*32 +: 32] = m_araddr;
            assign s_awvalid[i] = (cw == i[SELW-1:0]) ? m_awvalid : 1'b0;
            assign s_wvalid [i] = (cw == i[SELW-1:0]) ? m_wvalid  : 1'b0;
            assign s_bready [i] = (cw == i[SELW-1:0]) ? m_bready  : 1'b0;
            assign s_arvalid[i] = (cr == i[SELW-1:0]) ? m_arvalid : 1'b0;
            assign s_rready [i] = (cr == i[SELW-1:0]) ? m_rready  : 1'b0;
        end
    endgenerate
endmodule
`default_nettype wire
