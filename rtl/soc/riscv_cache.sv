// riscv_cache.sv - direct-mapped cache with an AXI4-Lite master back end.
//
// One parameterized block serves as both the I-cache (WRITABLE=0, read-only)
// and the D-cache (WRITABLE=1, write-through, no write-allocate). A miss fills a
// whole line as LINE_WORDS single-beat AXI4-Lite reads (AXI4-Lite has no
// bursts); a store writes through to memory and updates the line on a hit.
//
// Core side is a simple valid/ready handshake: `req` asserts an access for
// `addr`; `ready` is high the cycle the access completes (a hit completes in the
// same cycle, a miss/write after the AXI transactions). The core freezes while
// `req && !ready`, so all request inputs are held stable across a multi-cycle
// miss -- no request latching needed here.
module riscv_cache #(
    parameter int AW         = 32,
    parameter int DW         = 32,
    parameter int LINES      = 64,     // sets per cache (direct-mapped)
    parameter int LINE_WORDS = 4,      // words per line
    parameter bit WRITABLE   = 1'b0    // 0=I$ (read-only), 1=D$ (write-through)
) (
    input  logic            clk,
    input  logic            rst_n,
    // ---- core side ----
    input  logic            req,
    input  logic            we,        // store (WRITABLE only)
    input  logic [AW-1:0]   addr,      // byte address, word aligned
    input  logic [DW-1:0]   wdata,
    input  logic [DW/8-1:0] be,
    output logic [DW-1:0]   rdata,
    output logic            ready,
    // ---- AXI4-Lite master (to interconnect/SRAM) ----
    output logic [AW-1:0]   m_araddr,
    output logic            m_arvalid,
    input  logic            m_arready,
    input  logic [DW-1:0]   m_rdata,
    input  logic [1:0]      m_rresp,
    input  logic            m_rvalid,
    output logic            m_rready,
    output logic [AW-1:0]   m_awaddr,
    output logic            m_awvalid,
    input  logic            m_awready,
    output logic [DW-1:0]   m_wdata,
    output logic [DW/8-1:0] m_wstrb,
    output logic            m_wvalid,
    input  logic            m_wready,
    input  logic [1:0]      m_bresp,
    input  logic            m_bvalid,
    output logic            m_bready
);
    localparam int OFFW = $clog2(LINE_WORDS);
    localparam int IDXW = $clog2(LINES);
    localparam int TAGW = AW - IDXW - OFFW - 2;

    // address breakdown (byte addr): [1:0]=byte | [OFFW]=word | [IDXW]=index | tag
    wire [OFFW-1:0] woff   = addr[2 +: OFFW];
    wire [IDXW-1:0] index  = addr[2+OFFW +: IDXW];
    wire [TAGW-1:0] tag_in = addr[2+OFFW+IDXW +: TAGW];

    // storage
    logic               valid [0:LINES-1];
    logic [TAGW-1:0]    tagm  [0:LINES-1];
    logic [DW-1:0]      data  [0:LINES*LINE_WORDS-1];

    wire hit = valid[index] && (tagm[index] == tag_in);
    wire [IDXW+OFFW-1:0] hit_word = {index, woff};

    typedef enum logic [2:0] {IDLE, FILL_AR, FILL_R, WR_AW, WR_B} state_t;
    state_t state;
    logic [OFFW-1:0] fill_cnt;

    wire is_read  = req && !(WRITABLE && we);
    wire is_write = req &&  (WRITABLE && we);

    // ---- core-side outputs --------------------------------------------------
    always_comb begin
        rdata = data[hit_word];
        unique case (state)
            IDLE:  ready = !req || (is_read && hit);   // read hit (or no request)
            WR_B:  ready = m_bvalid;                    // store completes on B
            default: ready = 1'b0;                      // mid-miss / mid-write
        endcase
    end

    // ---- AXI master outputs -------------------------------------------------
    wire [AW-1:0] line_base = {tag_in, index, {(OFFW+2){1'b0}}};
    assign m_araddr  = line_base | (AW'(fill_cnt) << 2);
    assign m_arvalid = (state == FILL_AR);
    assign m_rready  = (state == FILL_R);
    assign m_awaddr  = {addr[AW-1:2], 2'b00};
    assign m_wdata   = wdata;
    assign m_wstrb   = be;
    assign m_awvalid = (state == WR_AW);
    assign m_wvalid  = (state == WR_AW);
    assign m_bready  = (state == WR_B);

    // ---- FSM + storage updates ---------------------------------------------
    integer k;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; fill_cnt <= '0;
            for (k = 0; k < LINES; k = k + 1) valid[k] <= 1'b0;
        end else begin
            unique case (state)
                IDLE: begin
                    if (is_read && !hit) begin
                        fill_cnt <= '0;
                        state    <= FILL_AR;
                    end else if (is_write) begin
                        state    <= WR_AW;
                    end
                end
                FILL_AR: if (m_arready) state <= FILL_R;
                FILL_R:  if (m_rvalid) begin
                    data[{index, fill_cnt}] <= m_rdata;
                    if (fill_cnt == OFFW'(LINE_WORDS-1)) begin
                        valid[index] <= 1'b1;
                        tagm[index]  <= tag_in;
                        state        <= IDLE;
                    end else begin
                        fill_cnt <= fill_cnt + 1'b1;
                        state    <= FILL_AR;
                    end
                end
                WR_AW: if (m_awready && m_wready) state <= WR_B;
                WR_B:  if (m_bvalid) begin
                    // write-through, no-allocate: update the line only on a hit
                    if (WRITABLE && hit) begin
                        for (k = 0; k < DW/8; k = k + 1)
                            if (be[k]) data[hit_word][8*k +: 8] <= wdata[8*k +: 8];
                    end
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
