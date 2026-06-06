// axil_uart - AXI4-Lite UART transmitter (canonical decoupled handshake).
//   reg 0x0 TXDATA (W): write a byte -> serialized on uart_tx (8N1)
//   reg 0x4 STATUS (R): bit0 = tx_busy
// CLKS_PER_BIT sets the baud (clk/CLKS_PER_BIT). Small default for fast sim.
`default_nettype none
module axil_uart #(
    parameter int CLKS_PER_BIT = 16
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
    input  wire        rready,
    output reg         uart_tx
);
    localparam int CW = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    wire wr_en   = awvalid && wvalid && !awready && !bvalid;
    wire load_tx = wr_en && (awaddr[3:0] == 4'h0) && !busy;

    // ---- TX serializer (8N1) ----
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;
    reg [1:0]    tstate;
    reg [CW-1:0] clkcnt;
    reg [2:0]    bitidx;
    reg [7:0]    shifter;
    reg          busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate <= S_IDLE; uart_tx <= 1'b1; busy <= 1'b0;
            clkcnt <= '0; bitidx <= 3'd0; shifter <= 8'd0;
        end else begin
            case (tstate)
                S_IDLE: begin
                    uart_tx <= 1'b1;
                    if (load_tx) begin
                        shifter <= wdata[7:0]; busy <= 1'b1;
                        clkcnt <= '0; tstate <= S_START;
                    end
                end
                S_START: begin
                    uart_tx <= 1'b0;
                    if (clkcnt == CW'(CLKS_PER_BIT-1)) begin
                        clkcnt <= '0; bitidx <= 3'd0; tstate <= S_DATA;
                    end else clkcnt <= clkcnt + 1'b1;
                end
                S_DATA: begin
                    uart_tx <= shifter[bitidx];
                    if (clkcnt == CW'(CLKS_PER_BIT-1)) begin
                        clkcnt <= '0;
                        if (bitidx == 3'd7) tstate <= S_STOP;
                        else                bitidx <= bitidx + 1'b1;
                    end else clkcnt <= clkcnt + 1'b1;
                end
                default: begin // S_STOP
                    uart_tx <= 1'b1;
                    if (clkcnt == CW'(CLKS_PER_BIT-1)) begin
                        busy <= 1'b0; tstate <= S_IDLE;
                    end else clkcnt <= clkcnt + 1'b1;
                end
            endcase
        end
    end

    // ---- AXI4-Lite write handshake ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bresp <= 2'b00;
        end else begin
            awready <= 1'b0; wready <= 1'b0;
            if (wr_en) begin awready <= 1'b1; wready <= 1'b1; end
            if (awready)               begin bvalid <= 1'b1; bresp <= 2'b00; end
            else if (bvalid && bready)       bvalid <= 1'b0;
        end
    end

    // ---- AXI4-Lite read handshake (STATUS) ----
    wire rd_en = arvalid && !arready && !rvalid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 1'b0; rvalid <= 1'b0; rdata <= 32'b0; rresp <= 2'b00;
        end else begin
            arready <= 1'b0;
            if (rd_en) begin
                arready <= 1'b1;
                rdata   <= (araddr[3:0] == 4'h4) ? {31'b0, busy} : 32'b0;
            end
            if (arready)               begin rvalid <= 1'b1; rresp <= 2'b00; end
            else if (rvalid && rready)       rvalid <= 1'b0;
        end
    end

    wire _unused = &{1'b0, awaddr[31:4], araddr[31:4], wstrb, wdata[31:8], 1'b0};
endmodule
`default_nettype wire
