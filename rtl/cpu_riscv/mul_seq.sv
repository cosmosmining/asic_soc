// mul_seq.sv - sequential (multi-cycle) 32x32 -> 64 integer multiplier for RV32M.
// Shift-add of operand magnitudes (~XLEN cycles), with sign applied afterwards,
// so one unit serves MUL / MULH / MULHSU / MULHU. Replaces the combinational
// 32x32 multiplier that dominated the critical path and made std-cell technology
// mapping intractable -- the same area/timing trade the divider already makes.
//
// Handshake mirrors divider.sv: pulse `start` with operands + the per-operand
// signedness and `sel_high`; `busy` stays high until a one-cycle `done`, when
// `result` holds the selected 32-bit half of the product.
module mul_seq #(
    parameter int XLEN = 32
) (
    input  logic            clk,
    input  logic            rst_n,
    input  logic            start,
    input  logic            a_is_signed,   // treat a as signed (MUL/MULH/MULHSU)
    input  logic            b_is_signed,   // treat b as signed (MUL/MULH)
    input  logic            sel_high,      // 1=upper half (MULH*), 0=lower (MUL)
    input  logic [XLEN-1:0] a,
    input  logic [XLEN-1:0] b,
    output logic            busy,
    output logic            done,
    output logic [XLEN-1:0] result
);
    typedef enum logic [1:0] {IDLE, CALC, FIN} state_t;
    state_t state;

    logic [2*XLEN-1:0] prod, mcand;    // accumulator, shifting multiplicand
    logic [XLEN-1:0]   mplier;         // shifting multiplier
    logic              res_neg, sel_high_r;
    logic [5:0]        cnt;

    wire a_neg = a_is_signed && a[XLEN-1];
    wire b_neg = b_is_signed && b[XLEN-1];
    wire [XLEN-1:0] a_mag = a_neg ? (~a + 1'b1) : a;
    wire [XLEN-1:0] b_mag = b_neg ? (~b + 1'b1) : b;

    assign busy = (state != IDLE);

    // sign-corrected final product, then half select
    wire [2*XLEN-1:0] prod_signed = res_neg ? (~prod + 1'b1) : prod;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; done <= 1'b0; result <= '0;
        end else begin
            done <= 1'b0;
            unique case (state)
                IDLE: if (start) begin
                    prod       <= '0;
                    mcand      <= {{XLEN{1'b0}}, a_mag};
                    mplier     <= b_mag;
                    res_neg    <= a_neg ^ b_neg;
                    sel_high_r <= sel_high;
                    cnt        <= XLEN[5:0];
                    state      <= CALC;
                end
                CALC: begin
                    if (mplier[0]) prod <= prod + mcand;
                    mcand  <= mcand  << 1;
                    mplier <= mplier >> 1;
                    cnt    <= cnt - 1'b1;
                    if (cnt == 6'd1) state <= FIN;
                end
                FIN: begin
                    result <= sel_high_r ? prod_signed[2*XLEN-1:XLEN]
                                         : prod_signed[XLEN-1:0];
                    done   <= 1'b1;
                    state  <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
