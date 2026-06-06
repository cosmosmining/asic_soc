// axil_arbiter - round-robin AXI4-Lite arbiter: M masters -> 1 master.
//
// Read and write channels arbitrated independently. The grant is REGISTERED:
// when a channel is idle and any master requests, it latches the round-robin
// winner and locks it from that cycle until the response handshake (single
// outstanding), then rotates the pointer => no starvation. Registering the grant
// (rather than driving it combinationally from the request vector) keeps the
// routed master stable for the whole transaction, so a second master's VALID
// toggling cannot glitch the selection and double-issue an address.
`default_nettype none
module axil_arbiter #(
    parameter int M = 2
) (
    input  wire            clk,
    input  wire            rst_n,
    // ---- masters in (packed) ----
    input  wire [M*32-1:0] mi_awaddr,
    input  wire [M-1:0]    mi_awvalid,
    output wire [M-1:0]    mi_awready,
    input  wire [M*32-1:0] mi_wdata,
    input  wire [M*4-1:0]  mi_wstrb,
    input  wire [M-1:0]    mi_wvalid,
    output wire [M-1:0]    mi_wready,
    output wire [M*2-1:0]  mi_bresp,
    output wire [M-1:0]    mi_bvalid,
    input  wire [M-1:0]    mi_bready,
    input  wire [M*32-1:0] mi_araddr,
    input  wire [M-1:0]    mi_arvalid,
    output wire [M-1:0]    mi_arready,
    output wire [M*32-1:0] mi_rdata,
    output wire [M*2-1:0]  mi_rresp,
    output wire [M-1:0]    mi_rvalid,
    input  wire [M-1:0]    mi_rready,
    // ---- single master out ----
    output wire [31:0]     o_awaddr,
    output wire            o_awvalid,
    input  wire            o_awready,
    output wire [31:0]     o_wdata,
    output wire [3:0]      o_wstrb,
    output wire            o_wvalid,
    input  wire            o_wready,
    input  wire [1:0]      o_bresp,
    input  wire            o_bvalid,
    output wire            o_bready,
    output wire [31:0]     o_araddr,
    output wire            o_arvalid,
    input  wire            o_arready,
    input  wire [31:0]     o_rdata,
    input  wire [1:0]      o_rresp,
    input  wire            o_rvalid,
    output wire            o_rready
);
    localparam int SELW = (M > 1) ? $clog2(M) : 1;

    // round-robin pick: first set bit of `req` scanning from `start` (M power-of-2)
    function automatic [SELW-1:0] rr_pick(input [M-1:0] req, input [SELW-1:0] start);
        integer k; reg [SELW-1:0] c; reg found;
        begin
            rr_pick = start; found = 1'b0;
            for (k = 0; k < M; k = k + 1) begin
                c = SELW'(start + k[SELW-1:0]);
                if (!found && req[c]) begin rr_pick = c; found = 1'b1; end
            end
        end
    endfunction

    // ---- write channel (registered grant) ----
    reg            wlock;
    reg [SELW-1:0] wgrant, wrr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wlock <= 1'b0; wgrant <= '0; wrr <= '0; end
        else if (!wlock) begin
            if (|mi_awvalid) begin wgrant <= rr_pick(mi_awvalid, wrr); wlock <= 1'b1; end
        end else if (o_bvalid && o_bready) begin
            wlock <= 1'b0;
            wrr   <= (wgrant == SELW'(M-1)) ? '0 : SELW'(wgrant + 1'b1);
        end
    end

    assign o_awaddr  = mi_awaddr[wgrant*32 +: 32];
    assign o_awvalid = wlock ? mi_awvalid[wgrant] : 1'b0;
    assign o_wdata   = mi_wdata[wgrant*32 +: 32];
    assign o_wstrb   = mi_wstrb[wgrant*4 +: 4];
    assign o_wvalid  = wlock ? mi_wvalid[wgrant] : 1'b0;
    assign o_bready  = wlock ? mi_bready[wgrant] : 1'b0;

    // ---- read channel (registered grant) ----
    reg            rlock;
    reg [SELW-1:0] rgrant, rrr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rlock <= 1'b0; rgrant <= '0; rrr <= '0; end
        else if (!rlock) begin
            if (|mi_arvalid) begin rgrant <= rr_pick(mi_arvalid, rrr); rlock <= 1'b1; end
        end else if (o_rvalid && o_rready) begin
            rlock <= 1'b0;
            rrr   <= (rgrant == SELW'(M-1)) ? '0 : SELW'(rgrant + 1'b1);
        end
    end

    assign o_araddr  = mi_araddr[rgrant*32 +: 32];
    assign o_arvalid = rlock ? mi_arvalid[rgrant] : 1'b0;
    assign o_rready  = rlock ? mi_rready[rgrant] : 1'b0;

    // ---- master-facing fan-out ----
    genvar i;
    generate
        for (i = 0; i < M; i = i + 1) begin : g_mst
            assign mi_awready[i]      = (wlock && wgrant == i[SELW-1:0]) ? o_awready : 1'b0;
            assign mi_wready [i]      = (wlock && wgrant == i[SELW-1:0]) ? o_wready  : 1'b0;
            assign mi_bvalid [i]      = (wlock && wgrant == i[SELW-1:0]) ? o_bvalid  : 1'b0;
            assign mi_bresp  [i*2+:2]  = o_bresp;
            assign mi_arready[i]      = (rlock && rgrant == i[SELW-1:0]) ? o_arready : 1'b0;
            assign mi_rvalid [i]      = (rlock && rgrant == i[SELW-1:0]) ? o_rvalid  : 1'b0;
            assign mi_rdata  [i*32+:32] = o_rdata;
            assign mi_rresp  [i*2+:2]   = o_rresp;
        end
    endgenerate

`ifdef FORMAL
    // ---- safety properties (proved in riscv-soc-dv via yosys-smtbmc) ----
    function automatic integer count_ones(input [M-1:0] v);
        integer k; begin count_ones = 0;
            for (k = 0; k < M; k = k + 1) count_ones = count_ones + v[k];
        end
    endfunction
    // at most one master is selected on each response channel (no bus contention)
    always @(*) assert (count_ones(mi_awready) <= 1);
    always @(*) assert (count_ones(mi_arready) <= 1);
    always @(*) assert (count_ones(mi_bvalid)  <= 1);
    always @(*) assert (count_ones(mi_rvalid)  <= 1);
    // registered-grant property: the grant never changes mid-transaction (the
    // anti-glitch invariant that fixed the double-issue bug, see DESIGN_DECISIONS)
    reg fv = 1'b0; always @(posedge clk) fv <= 1'b1;
    always @(posedge clk) if (fv && rst_n && $past(rst_n) && $past(wlock))
        assert (wgrant == $past(wgrant));
    always @(posedge clk) if (fv && rst_n && $past(rst_n) && $past(rlock))
        assert (rgrant == $past(rgrant));
`endif
endmodule
`default_nettype wire
