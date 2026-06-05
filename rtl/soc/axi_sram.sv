// axi_sram.sv - AXI4-Lite slave wrapping a single-port synchronous SRAM.
//
// Full AXI4-Lite (5 channels), 32-bit address/data, byte strobes. Handles one
// outstanding read or write; reads have a registered (1-cycle) data phase, the
// realistic latency a cache fill must tolerate. The backing array is exposed as
// `mem` so a testbench can $readmemh a program into it (word-addressed).
module axi_sram #(
    parameter int AW    = 32,
    parameter int DW    = 32,
    parameter int WORDS = 4096,                 // 16 KiB
    parameter logic [AW-1:0] BASE = 32'h0000_0000
) (
    input  logic          clk,
    input  logic          rst_n,
    // ---- AXI4-Lite write address ----
    input  logic [AW-1:0] awaddr,
    input  logic          awvalid,
    output logic          awready,
    // ---- AXI4-Lite write data ----
    input  logic [DW-1:0] wdata,
    input  logic [DW/8-1:0] wstrb,
    input  logic          wvalid,
    output logic          wready,
    // ---- AXI4-Lite write response ----
    output logic [1:0]    bresp,
    output logic          bvalid,
    input  logic          bready,
    // ---- AXI4-Lite read address ----
    input  logic [AW-1:0] araddr,
    input  logic          arvalid,
    output logic          arready,
    // ---- AXI4-Lite read data ----
    output logic [DW-1:0] rdata,
    output logic [1:0]    rresp,
    output logic          rvalid,
    input  logic          rready
);
    localparam int WIDX = $clog2(WORDS);
    logic [DW-1:0] mem [0:WORDS-1];

    wire [WIDX-1:0] w_index = WIDX'((awaddr - BASE) >> 2);
    wire [WIDX-1:0] r_index = WIDX'((araddr - BASE) >> 2);

    // ---------------- write channel: accept AW+W together, then respond ------
    typedef enum logic [1:0] {W_IDLE, W_RESP} wstate_t;
    wstate_t wst;
    assign awready = (wst == W_IDLE);
    assign wready  = (wst == W_IDLE);
    assign bresp   = 2'b00;                      // OKAY

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst <= W_IDLE; bvalid <= 1'b0;
        end else begin
            unique case (wst)
                W_IDLE: if (awvalid && wvalid) begin
                    for (int b = 0; b < DW/8; b++)
                        if (wstrb[b]) mem[w_index][8*b +: 8] <= wdata[8*b +: 8];
                    bvalid <= 1'b1;
                    wst    <= W_RESP;
                end
                W_RESP: if (bready) begin
                    bvalid <= 1'b0;
                    wst    <= W_IDLE;
                end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // ---------------- read channel: 1-cycle registered data ------------------
    typedef enum logic [1:0] {R_IDLE, R_DATA} rstate_t;
    rstate_t rst_r;
    assign arready = (rst_r == R_IDLE);
    assign rresp   = 2'b00;                      // OKAY

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_r <= R_IDLE; rvalid <= 1'b0; rdata <= '0;
        end else begin
            unique case (rst_r)
                R_IDLE: if (arvalid) begin
                    rdata  <= mem[r_index];
                    rvalid <= 1'b1;
                    rst_r  <= R_DATA;
                end
                R_DATA: if (rready) begin
                    rvalid <= 1'b0;
                    rst_r  <= R_IDLE;
                end
                default: rst_r <= R_IDLE;
            endcase
        end
    end
endmodule
