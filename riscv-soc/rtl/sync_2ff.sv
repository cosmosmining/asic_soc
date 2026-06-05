// sync_2ff — two-flop synchronizer for a vector crossing INTO `clk`'s domain.
//
// Intended for Gray-coded buses where at most one bit changes per step: under
// metastability the sampled value resolves to either the old or the new code,
// never an illegal intermediate. Do NOT use on general binary multi-bit buses
// (multiple bits can change at once -> can latch a value that never existed).
//
// Timing/CDC note: this is the synchronizer the async_fifo relies on. Two FFs
// give one full destination clock for a metastable event to settle; MTBF scales
// exponentially with the added settling time. Apply a max-delay / set_false_path
// (false path is fine here because Gray guarantees correctness) on the `d` input
// in SDC so STA doesn't try to time the asynchronous launch.
`default_nettype none
module sync_2ff #(
    parameter int WIDTH = 1
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] d,      // launched by the other clock domain
    output reg  [WIDTH-1:0] q       // stable in `clk`'s domain
);
    reg [WIDTH-1:0] meta;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta <= '0;
            q    <= '0;
        end else begin
            meta <= d;     // capture stage (may go metastable)
            q    <= meta;  // settle stage
        end
    end
endmodule
`default_nettype wire
