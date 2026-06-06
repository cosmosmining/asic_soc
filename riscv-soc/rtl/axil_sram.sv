// axil_sram - AXI4-Lite slave: word-addressable RAM (or ROM if READONLY).
//
// Canonical decoupled handshake: AW+W accepted with a 1-cycle READY pulse, then
// BVALID asserts the *following* cycle and holds until BREADY. Reads symmetric
// (ARREADY pulse, then RVALID). This 1-cycle AW->B separation is what lets a
// simple crossbar lock the routed slave for the duration of a transaction.
// Byte strobes honored; writes to a READONLY instance return SLVERR.
// DEPTH_WORDS must be a power of two.
`default_nettype none
module axil_sram #(
    parameter int DEPTH_WORDS = 1024,     // 32-bit words; 1024 => 4 KB
    parameter bit READONLY    = 1'b0,
    parameter     INIT_FILE   = ""
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] awaddr,
    input  wire        awvalid,
    output reg         awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output reg         wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [31:0] araddr,
    input  wire        arvalid,
    output reg         arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rvalid,
    input  wire        rready
);
    localparam int AW = $clog2(DEPTH_WORDS);

    reg [31:0] mem [0:DEPTH_WORDS-1];
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

    wire [AW-1:0] w_idx = awaddr[AW+1:2];
    wire [AW-1:0] r_idx = araddr[AW+1:2];

    // ---- write channel ----
    wire wr_en = awvalid && wvalid && !awready && !bvalid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bresp <= 2'b00;
        end else begin
            awready <= 1'b0; wready <= 1'b0;
            if (wr_en) begin
                awready <= 1'b1; wready <= 1'b1;
                if (!READONLY) begin
                    if (wstrb[0]) mem[w_idx][7:0]   <= wdata[7:0];
                    if (wstrb[1]) mem[w_idx][15:8]  <= wdata[15:8];
                    if (wstrb[2]) mem[w_idx][23:16] <= wdata[23:16];
                    if (wstrb[3]) mem[w_idx][31:24] <= wdata[31:24];
                end
            end
            if (awready) begin                 // cycle after accept
                bvalid <= 1'b1;
                bresp  <= READONLY ? 2'b10 : 2'b00;
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // ---- read channel ----
    wire rd_en = arvalid && !arready && !rvalid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 1'b0; rvalid <= 1'b0; rdata <= 32'b0; rresp <= 2'b00;
        end else begin
            arready <= 1'b0;
            if (rd_en) begin
                arready <= 1'b1;
                rdata   <= mem[r_idx];
            end
            if (arready) begin                 // cycle after accept
                rvalid <= 1'b1; rresp <= 2'b00;
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    wire _unused = &{1'b0, awaddr[31:AW+2], awaddr[1:0],
                          araddr[31:AW+2], araddr[1:0], 1'b0};
endmodule
`default_nettype wire
