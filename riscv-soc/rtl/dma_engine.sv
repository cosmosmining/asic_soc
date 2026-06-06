// dma_engine - 2-channel AXI4-Lite DMA.
//   * config: AXI4-Lite SLAVE. Per channel c in {0,1} at base c*0x10:
//       +0x0 SRC, +0x4 DST, +0x8 LEN (words), +0xC CTRL (bit0=start; read=busy)
//   * data:   AXI4-Lite MASTER. Copies LEN words SRC->DST, word at a time.
// One master datapath services both channels round-robin (alternates per word
// when both are active), so two outstanding copies make forward progress fairly.
//
// The config-slave WRITE path latches AW and W independently and commits when
// both are captured (not assuming they arrive the same cycle) so it is robust to
// AW/W skew introduced by the upstream round-robin arbiter.
`default_nettype none
module dma_engine (
    input  wire        clk,
    input  wire        rst_n,
    // ---- config slave ----
    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,
    // ---- data master ----
    output reg  [31:0] m_awaddr,
    output reg         m_awvalid,
    input  wire        m_awready,
    output reg  [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output reg         m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output reg         m_bready,
    output reg  [31:0] m_araddr,
    output reg         m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output reg         m_rready,
    output wire [1:0]  busy
);
    assign m_wstrb = 4'hf;

    reg [31:0] src [0:1];
    reg [31:0] dst [0:1];
    reg [31:0] len [0:1];
    reg [31:0] idx [0:1];
    reg [1:0]  active;
    reg        cur;
    assign busy = active;

    // decoupled AW/W capture (robust to arbiter-induced AW/W skew)
    reg        aw_hs, w_hs;
    reg [31:0] awaddr_q, wdata_q;
    wire       cfg_we  = aw_hs && w_hs && !s_bvalid;
    wire       cfg_ch  = awaddr_q[4];
    wire       rcfg_ch = s_araddr[4];

    localparam [2:0] D_IDLE=3'd0, D_AR=3'd1, D_R=3'd2, D_AW=3'd3, D_B=3'd4;
    reg [2:0] state;

    // ---- data-mover FSM + channel state + config-register writes ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= D_IDLE; cur <= 1'b0; active <= 2'b00;
            src[0]<=0; src[1]<=0; dst[0]<=0; dst[1]<=0;
            len[0]<=0; len[1]<=0; idx[0]<=0; idx[1]<=0;
            m_awvalid<=0; m_wvalid<=0; m_bready<=0; m_arvalid<=0; m_rready<=0;
            m_awaddr<=0; m_wdata<=0; m_araddr<=0;
        end else begin
            case (state)
                D_IDLE: begin
                    if (active[cur] && idx[cur] < len[cur]) begin
                        m_araddr  <= src[cur] + (idx[cur] << 2);
                        m_arvalid <= 1'b1;
                        state     <= D_AR;
                    end else if (active[cur]) begin
                        active[cur] <= 1'b0;
                        cur <= ~cur;
                    end else if (active[~cur]) begin
                        cur <= ~cur;
                    end
                end
                D_AR: if (m_arvalid && m_arready) begin
                    m_arvalid <= 1'b0; m_rready <= 1'b1; state <= D_R;
                end
                D_R: if (m_rvalid && m_rready) begin
                    m_rready  <= 1'b0;
                    m_awaddr  <= dst[cur] + (idx[cur] << 2);
                    m_wdata   <= m_rdata;
                    m_awvalid <= 1'b1; m_wvalid <= 1'b1;
                    state     <= D_AW;
                end
                D_AW: begin
                    if (m_awvalid && m_awready) m_awvalid <= 1'b0;
                    if (m_wvalid  && m_wready ) m_wvalid  <= 1'b0;
                    if ((!m_awvalid || m_awready) && (!m_wvalid || m_wready)) begin
                        m_bready <= 1'b1; state <= D_B;
                    end
                end
                default: if (m_bvalid && m_bready) begin   // D_B
                    m_bready <= 1'b0;
                    idx[cur] <= idx[cur] + 1;
                    if (idx[cur] + 1 >= len[cur]) active[cur] <= 1'b0;
                    cur   <= ~cur;
                    state <= D_IDLE;
                end
            endcase

            // config-register writes (after FSM so a 'start' is never dropped)
            if (cfg_we) begin
                case (awaddr_q[3:2])
                    2'd0:    src[cfg_ch] <= wdata_q;
                    2'd1:    dst[cfg_ch] <= wdata_q;
                    2'd2:    len[cfg_ch] <= wdata_q;
                    default: if (wdata_q[0]) begin    // CTRL start
                        active[cfg_ch] <= 1'b1;
                        idx[cfg_ch]    <= 32'b0;
                    end
                endcase
            end
        end
    end

    // ---- config slave: write handshake (decoupled AW/W capture) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_awready<=0; s_wready<=0; s_bvalid<=0; s_bresp<=2'b00;
            aw_hs<=0; w_hs<=0; awaddr_q<=0; wdata_q<=0;
        end else begin
            s_awready <= 1'b0; s_wready <= 1'b0;
            if (s_awvalid && !aw_hs && !s_bvalid) begin s_awready <= 1'b1; awaddr_q <= s_awaddr; aw_hs <= 1'b1; end
            if (s_wvalid  && !w_hs  && !s_bvalid) begin s_wready  <= 1'b1; wdata_q  <= s_wdata;  w_hs  <= 1'b1; end
            if (cfg_we) begin s_bvalid <= 1'b1; s_bresp <= 2'b00; aw_hs <= 1'b0; w_hs <= 1'b0; end
            else if (s_bvalid && s_bready) s_bvalid <= 1'b0;
        end
    end

    // ---- config slave: read handshake (registers + busy) ----
    wire rd_en = s_arvalid && !s_arready && !s_rvalid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_arready<=0; s_rvalid<=0; s_rdata<=32'b0; s_rresp<=2'b00;
        end else begin
            s_arready<=0;
            if (rd_en) begin
                s_arready <= 1'b1;
                case (s_araddr[3:2])
                    2'd0:    s_rdata <= src[rcfg_ch];
                    2'd1:    s_rdata <= dst[rcfg_ch];
                    2'd2:    s_rdata <= len[rcfg_ch];
                    default: s_rdata <= {31'b0, active[rcfg_ch]};
                endcase
            end
            if (s_arready)                 begin s_rvalid<=1; s_rresp<=2'b00; end
            else if (s_rvalid && s_rready)       s_rvalid<=0;
        end
    end

    wire _unused = &{1'b0, awaddr_q[31:5], awaddr_q[1:0], s_araddr[31:5], s_araddr[1:0],
                          s_wstrb, m_bresp, m_rresp, 1'b0};
endmodule
`default_nettype wire
