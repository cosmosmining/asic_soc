// divider.sv - sequential (multi-cycle) 32-bit integer divider for RV32M.
// Restoring shift-subtract, ~XLEN cycles. Replaces the combinational divider
// that dominated area and the critical path. Handles signed/unsigned and the
// RISC-V corner cases (÷0, signed overflow) in a fast path.
//
// Handshake: pulse `start` for one cycle with operands valid; `busy` stays high
// until a one-cycle `done` pulse, at which point `result` holds the quotient
// (want_rem=0) or remainder (want_rem=1).
module divider #(
    parameter int XLEN = 32
) (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            start,
    input  logic            is_signed,   // DIV/REM vs DIVU/REMU
    input  logic            want_rem,    // 0=quotient, 1=remainder
    input  logic [XLEN-1:0] a,           // dividend
    input  logic [XLEN-1:0] b,           // divisor
    output logic            busy,
    output logic            done,
    output logic [XLEN-1:0] result
);
    localparam logic [XLEN-1:0] MIN_S = {1'b1, {(XLEN-1){1'b0}}};

    typedef enum logic [1:0] {IDLE, CALC, FIN} state_t;
    state_t state;

    logic [XLEN-1:0]  divisor_mag, quo;
    logic [XLEN:0]    rem;            // 1 guard bit for the shift-compare
    logic             quo_neg, rem_neg, want_rem_r;
    logic [5:0]       cnt;
    logic [XLEN-1:0]  q_final, r_final;

    wire [XLEN:0] sub = {rem[XLEN-1:0], quo[XLEN-1]};   // (rem<<1) | next dividend bit

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; done <= 1'b0; result <= '0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    want_rem_r <= want_rem;
                    // fast paths: divide-by-zero and signed overflow
                    if (b == '0) begin
                        result <= want_rem ? a : {XLEN{1'b1}};
                        done   <= 1'b1;            // 1-cycle latency
                        state  <= IDLE;
                    end else if (is_signed && a == MIN_S && (&b)) begin
                        result <= want_rem ? '0 : MIN_S;
                        done   <= 1'b1;
                        state  <= IDLE;
                    end else begin
                        divisor_mag <= (is_signed && b[XLEN-1]) ? (~b + 1'b1) : b;
                        quo         <= (is_signed && a[XLEN-1]) ? (~a + 1'b1) : a;
                        rem         <= '0;
                        quo_neg     <= is_signed && (a[XLEN-1] ^ b[XLEN-1]);
                        rem_neg     <= is_signed && a[XLEN-1];
                        cnt         <= XLEN[5:0];
                        state       <= CALC;
                    end
                end
                CALC: begin
                    if (sub >= {1'b0, divisor_mag}) begin
                        rem <= sub - {1'b0, divisor_mag};
                        quo <= {quo[XLEN-2:0], 1'b1};
                    end else begin
                        rem <= sub;
                        quo <= {quo[XLEN-2:0], 1'b0};
                    end
                    cnt <= cnt - 1'b1;
                    if (cnt == 6'd1) state <= FIN;
                end
                FIN: begin
                    result <= want_rem_r ? r_final : q_final;
                    done   <= 1'b1;
                    state  <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // sign fix-up of the magnitudes computed in CALC
    assign q_final = quo_neg ? (~quo + 1'b1)        : quo;
    assign r_final = rem_neg ? (~rem[XLEN-1:0] + 1'b1) : rem[XLEN-1:0];
endmodule
