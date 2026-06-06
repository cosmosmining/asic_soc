// axil_arb.sv - 2-master -> 1-slave AXI4-Lite interconnect.
//
// Shares one AXI4-Lite slave (the SRAM) between two masters (the I-cache and
// D-cache). Transaction-level arbitration: when the bus is free it grants a
// requester (D-cache prioritised, since it also writes), locks the grant for
// the duration of that read or write, then re-arbitrates. One outstanding
// transaction at a time -- simple and deadlock-free.
module axil_arb #(
    parameter int AW = 32,
    parameter int DW = 32
) (
    input  logic clk,
    input  logic rst_n,
    // ===== master 0 (I-cache: reads only) =====
    input  logic [AW-1:0] m0_araddr,  input  logic m0_arvalid, output logic m0_arready,
    output logic [DW-1:0] m0_rdata,   output logic [1:0] m0_rresp, output logic m0_rvalid, input logic m0_rready,
    input  logic [AW-1:0] m0_awaddr,  input  logic m0_awvalid, output logic m0_awready,
    input  logic [DW-1:0] m0_wdata,   input  logic [DW/8-1:0] m0_wstrb, input logic m0_wvalid, output logic m0_wready,
    output logic [1:0]    m0_bresp,   output logic m0_bvalid,  input  logic m0_bready,
    // ===== master 1 (D-cache: reads + writes) =====
    input  logic [AW-1:0] m1_araddr,  input  logic m1_arvalid, output logic m1_arready,
    output logic [DW-1:0] m1_rdata,   output logic [1:0] m1_rresp, output logic m1_rvalid, input logic m1_rready,
    input  logic [AW-1:0] m1_awaddr,  input  logic m1_awvalid, output logic m1_awready,
    input  logic [DW-1:0] m1_wdata,   input  logic [DW/8-1:0] m1_wstrb, input logic m1_wvalid, output logic m1_wready,
    output logic [1:0]    m1_bresp,   output logic m1_bvalid,  input  logic m1_bready,
    // ===== slave (to SRAM) =====
    output logic [AW-1:0] s_araddr,   output logic s_arvalid, input  logic s_arready,
    input  logic [DW-1:0] s_rdata,    input  logic [1:0] s_rresp, input logic s_rvalid, output logic s_rready,
    output logic [AW-1:0] s_awaddr,   output logic s_awvalid, input  logic s_awready,
    output logic [DW-1:0] s_wdata,    output logic [DW/8-1:0] s_wstrb, output logic s_wvalid, input logic s_wready,
    input  logic [1:0]    s_bresp,    input  logic s_bvalid,  output logic s_bready
);
    typedef enum logic [1:0] {FREE, RD, WR} st_t;
    st_t state;
    logic sel;                         // granted master id (0 or 1)

    wire m0_wants = m0_arvalid;                  // I$: reads only
    wire m1_wants = m1_arvalid || m1_awvalid;    // D$: reads or writes

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= FREE; sel <= 1'b0;
        end else unique case (state)
            FREE: begin
                // priority to D$ (master 1); a write is signalled by awvalid
                if      (m1_awvalid) begin sel <= 1'b1; state <= WR; end
                else if (m1_arvalid) begin sel <= 1'b1; state <= RD; end
                else if (m0_arvalid) begin sel <= 1'b0; state <= RD; end
            end
            RD: if (s_rvalid && s_rready) state <= FREE;   // read data accepted
            WR: if (s_bvalid && s_bready) state <= FREE;   // write resp accepted
            default: state <= FREE;
        endcase
    end

    wire grant1_rd = (state == RD) && sel;
    wire grant0_rd = (state == RD) && !sel;
    wire grant1_wr = (state == WR) && sel;       // only D$ writes

    // ---- slave-side muxes (driven by the granted master) -------------------
    assign s_araddr  = grant1_rd ? m1_araddr  : m0_araddr;
    assign s_arvalid = grant0_rd ? m0_arvalid : (grant1_rd ? m1_arvalid : 1'b0);
    assign s_rready  = grant0_rd ? m0_rready  : (grant1_rd ? m1_rready  : 1'b0);
    assign s_awaddr  = m1_awaddr;
    assign s_awvalid = grant1_wr ? m1_awvalid : 1'b0;
    assign s_wdata   = m1_wdata;
    assign s_wstrb   = m1_wstrb;
    assign s_wvalid  = grant1_wr ? m1_wvalid  : 1'b0;
    assign s_bready  = grant1_wr ? m1_bready  : 1'b0;

    // ---- master 0 (I$) responses (only ever reads) -------------------------
    assign m0_arready = grant0_rd ? s_arready : 1'b0;
    assign m0_rdata   = s_rdata;
    assign m0_rresp   = s_rresp;
    assign m0_rvalid  = grant0_rd ? s_rvalid  : 1'b0;
    assign m0_awready = 1'b0;
    assign m0_wready  = 1'b0;
    assign m0_bresp   = 2'b00;
    assign m0_bvalid  = 1'b0;

    // ---- master 1 (D$) responses -------------------------------------------
    assign m1_arready = grant1_rd ? s_arready : 1'b0;
    assign m1_rdata   = s_rdata;
    assign m1_rresp   = s_rresp;
    assign m1_rvalid  = grant1_rd ? s_rvalid  : 1'b0;
    assign m1_awready = grant1_wr ? s_awready : 1'b0;
    assign m1_wready  = grant1_wr ? s_wready  : 1'b0;
    assign m1_bresp   = s_bresp;
    assign m1_bvalid  = grant1_wr ? s_bvalid  : 1'b0;
endmodule
