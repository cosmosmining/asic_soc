// uart_tx.sv - memory-mapped UART transmitter (8N1, configurable baud divisor).
//
// Writing a byte to UART_TXDATA (when not busy) serialises it on `tx`: one start
// bit (0), eight data bits LSB-first, one stop bit (1); the line idles high.
// STATUS bit0 reads back tx_busy so firmware can poll before the next write.
// CLKS_PER_BIT sets the baud rate (core_clk / CLKS_PER_BIT); keep it small in
// simulation. `tx_strobe`/`tx_byte` mirror each accepted byte for easy checking.
`include "soc_map.svh"

module uart_tx #(
    parameter int CLKS_PER_BIT = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sel,
    input  logic        we,
    input  logic [15:0] offs,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        tx,             // serial output (idle = 1)
    output logic        tx_strobe,      // 1-cycle pulse as a byte starts
    output logic [7:0]  tx_byte         // the byte being/just transmitted
);
    localparam int CW = (CLKS_PER_BIT < 2) ? 1 : $clog2(CLKS_PER_BIT);

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t        state;
    logic [CW-1:0] clkcnt;
    logic [2:0]    bitidx;
    logic [7:0]    shifter;

    wire busy     = (state != IDLE);
    wire wr_tx    = sel && we && (offs == `UART_TXDATA);
    wire load     = wr_tx && !busy;
    wire bit_done = (clkcnt == CW'(CLKS_PER_BIT - 1));

    assign tx_byte = shifter;

    // combinational read
    always_comb begin
        unique case (offs)
            `UART_STATUS: rdata = {31'b0, busy};
            `UART_TXDATA: rdata = {24'b0, shifter};
            default     : rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            clkcnt    <= '0;
            bitidx    <= 3'd0;
            shifter   <= 8'h00;
            tx        <= 1'b1;
            tx_strobe <= 1'b0;
        end else begin
            tx_strobe <= 1'b0;
            unique case (state)
                IDLE: begin
                    tx     <= 1'b1;
                    clkcnt <= '0;
                    bitidx <= 3'd0;
                    if (load) begin
                        shifter   <= wdata[7:0];
                        tx_strobe <= 1'b1;
                        state     <= START;
                    end
                end
                START: begin                    // drive start bit (0)
                    tx <= 1'b0;
                    if (bit_done) begin clkcnt <= '0; state <= DATA; end
                    else clkcnt <= clkcnt + 1'b1;
                end
                DATA: begin                     // 8 data bits, LSB first
                    tx <= shifter[bitidx];
                    if (bit_done) begin
                        clkcnt <= '0;
                        if (bitidx == 3'd7) state <= STOP;
                        else                bitidx <= bitidx + 3'd1;
                    end else clkcnt <= clkcnt + 1'b1;
                end
                STOP: begin                     // stop bit (1)
                    tx <= 1'b1;
                    if (bit_done) begin clkcnt <= '0; state <= IDLE; end
                    else clkcnt <= clkcnt + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
