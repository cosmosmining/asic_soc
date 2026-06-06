// axil_timer - AXI4-Lite timer with compare interrupt (canonical handshake).
//   reg 0x0 MTIME    (RW): free-running counter (increments when enabled)
//   reg 0x4 CTRL     (RW): bit0 = enable
//   reg 0x8 MTIMECMP (RW): compare value
// irq asserts while enabled and MTIME >= MTIMECMP.
`default_nettype none
module axil_timer (
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
    output wire        irq
);
    reg [31:0] mtime, mtimecmp;
    reg        enable;

    wire wr_en = awvalid && wvalid && !awready && !bvalid;

    // ---- registers: free-run + register writes ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime <= 32'd0; mtimecmp <= 32'hFFFF_FFFF; enable <= 1'b0;
        end else begin
            if (enable) mtime <= mtime + 32'd1;
            if (wr_en) begin
                case (awaddr[3:0])
                    4'h0:    mtime    <= wdata;   // write overrides the increment
                    4'h4:    enable   <= wdata[0];
                    4'h8:    mtimecmp <= wdata;
                    default: ;
                endcase
            end
        end
    end

    assign irq = enable && (mtime >= mtimecmp);

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

    // ---- AXI4-Lite read handshake ----
    wire rd_en = arvalid && !arready && !rvalid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 1'b0; rvalid <= 1'b0; rdata <= 32'b0; rresp <= 2'b00;
        end else begin
            arready <= 1'b0;
            if (rd_en) begin
                arready <= 1'b1;
                case (araddr[3:0])
                    4'h0:    rdata <= mtime;
                    4'h4:    rdata <= {31'b0, enable};
                    4'h8:    rdata <= mtimecmp;
                    default: rdata <= 32'b0;
                endcase
            end
            if (arready)               begin rvalid <= 1'b1; rresp <= 2'b00; end
            else if (rvalid && rready)       rvalid <= 1'b0;
        end
    end

    wire _unused = &{1'b0, awaddr[31:4], araddr[31:4], wstrb, 1'b0};
endmodule
`default_nettype wire
