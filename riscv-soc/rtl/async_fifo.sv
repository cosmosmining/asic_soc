// async_fifo — parameterized dual-clock FIFO (Cummings style).
//
// CDC showcase block. Write and read live in independent clock domains; the only
// signals that cross are the Gray-coded pointers, each passed through a 2-flop
// synchronizer (sync_2ff). Pointers are AW+1 bits: the extra MSB lets us tell
// "full" (pointers differ only in MSB) from "empty" (pointers equal) when the
// low AW address bits coincide.
//
// Why Gray code: a binary counter can flip many bits at once (e.g. 0111->1000),
// so a multi-bit synchronizer could sample a transient illegal value. Gray code
// changes exactly one bit per increment, so the synchronized pointer is always
// either the old or the new count -> the full/empty compare is always safe.
//
// Requires AW >= 2 (depth >= 4).
`default_nettype none
module async_fifo #(
    parameter int DW = 32,    // data width
    parameter int AW = 4      // address width; depth = 2**AW
) (
    // write clock domain
    input  wire           wclk,
    input  wire           wrst_n,
    input  wire           winc,    // request push (ignored when wfull)
    input  wire [DW-1:0]  wdata,
    output reg            wfull,
    // read clock domain
    input  wire           rclk,
    input  wire           rrst_n,
    input  wire           rinc,    // request pop (ignored when rempty)
    output wire [DW-1:0]  rdata,
    output reg            rempty
);
    localparam int DEPTH = 1 << AW;

    reg [DW-1:0] mem [0:DEPTH-1];

    // pointers (binary + Gray) per domain
    reg  [AW:0] wbin, wgray;
    reg  [AW:0] rbin, rgray;
    // opposite-domain Gray pointers, synchronized in
    wire [AW:0] wq2_rgray;   // read pointer seen by write domain
    wire [AW:0] rq2_wgray;   // write pointer seen by read domain

    // ---------------- write domain ----------------
    wire        wen       = winc & ~wfull;
    wire [AW:0] wbin_next = wbin + {{AW{1'b0}}, wen};
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
    // full: next write Gray equals read Gray with the top two bits inverted
    wire        wfull_next = (wgray_next == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= '0;
            wgray <= '0;
            wfull <= 1'b0;
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
            wfull <= wfull_next;
        end
    end

    always_ff @(posedge wclk) begin
        if (wen) mem[wbin[AW-1:0]] <= wdata;
    end

    // ---------------- read domain ----------------
    wire        ren        = rinc & ~rempty;
    wire [AW:0] rbin_next  = rbin + {{AW{1'b0}}, ren};
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;
    // empty: next read Gray equals synchronized write Gray
    wire        rempty_next = (rgray_next == rq2_wgray);

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin   <= '0;
            rgray  <= '0;
            rempty <= 1'b1;
        end else begin
            rbin   <= rbin_next;
            rgray  <= rgray_next;
            rempty <= rempty_next;
        end
    end

    assign rdata = mem[rbin[AW-1:0]];

    // ---------------- CDC: synchronize Gray pointers ----------------
    sync_2ff #(.WIDTH(AW+1)) u_sync_r2w (
        .clk(wclk), .rst_n(wrst_n), .d(rgray), .q(wq2_rgray));
    sync_2ff #(.WIDTH(AW+1)) u_sync_w2r (
        .clk(rclk), .rst_n(rrst_n), .d(wgray), .q(rq2_wgray));

`ifdef FORMAL
    // CDC-critical invariants. Proven standalone in formal/gray_inc.sv via
    // yosys-smtbmc + z3 (BMC base case + unbounded temporal induction); restated
    // here so a SymbiYosys multiclock run re-checks them in the full FIFO context.
    reg fpv_w = 1'b0; always_ff @(posedge wclk) fpv_w <= 1'b1;
    reg fpv_r = 1'b0; always_ff @(posedge rclk) fpv_r <= 1'b1;

    function automatic [31:0] popcount(input [AW:0] x);
        integer i; begin popcount = 0;
            for (i = 0; i <= AW; i = i + 1) popcount = popcount + x[i];
        end
    endfunction

    // each Gray pointer is the Gray code of its binary counterpart
    always @(*) assert (wgray == ((wbin >> 1) ^ wbin));
    always @(*) assert (rgray == ((rbin >> 1) ^ rbin));
    // consecutive Gray codes differ in at most one bit (safe to synchronize)
    always_ff @(posedge wclk) if (fpv_w && wrst_n && $past(wrst_n))
        assert (popcount(wgray ^ $past(wgray)) <= 1);
    always_ff @(posedge rclk) if (fpv_r && rrst_n && $past(rrst_n))
        assert (popcount(rgray ^ $past(rgray)) <= 1);
`endif
endmodule
`default_nettype wire
