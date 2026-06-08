// mtimer.sv - CLINT-style core-local interruptor: machine timer + software IRQ.
//
// Standard RISC-V layout (see soc_map.svh): a free-running 64-bit `mtime`, a
// 64-bit `mtimecmp`, and a 1-bit `msip`. The machine *timer* interrupt is the
// level `mtime >= mtimecmp`; the machine *software* interrupt is `msip[0]`.
// Firmware acknowledges the timer by advancing mtimecmp (the level then drops).
//
// Register access uses the SoC's single-cycle convention: combinational read,
// word write gated by `sel & we`. mtime ticks once per TICK_DIV core clocks.
`include "soc_map.svh"

module mtimer #(
    parameter int TICK_DIV = 1            // core clocks per mtime increment
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sel,              // CLINT region selected this access
    input  logic        we,               // write strobe (with sel)
    input  logic [15:0] offs,             // addr[15:0]
    input  logic [31:0] wdata,
    output logic [31:0] rdata,            // combinational
    output logic        timer_irq,        // MTIP level
    output logic        sw_irq            // MSIP level
);
    logic [63:0] mtime, mtimecmp;
    logic        msip;
    logic [31:0] tickcnt;

    assign timer_irq = (mtime >= mtimecmp);
    assign sw_irq    = msip;

    // ---- combinational read -------------------------------------------------
    always_comb begin
        unique case (offs)
            `CLINT_MSIP     : rdata = {31'b0, msip};
            `CLINT_MTIMECMP : rdata = mtimecmp[31:0];
            `CLINT_MTIMECMPH: rdata = mtimecmp[63:32];
            `CLINT_MTIME    : rdata = mtime[31:0];
            `CLINT_MTIMEH   : rdata = mtime[63:32];
            default         : rdata = 32'h0;
        endcase
    end

    wire wr = sel && we;
    wire tick = (TICK_DIV <= 1) ? 1'b1 : (tickcnt == 32'(TICK_DIV - 1));

    // ---- registered state ---------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;  // no timer IRQ until armed
            msip     <= 1'b0;
            tickcnt  <= 32'd0;
        end else begin
            // prescaler
            if (TICK_DIV > 1)
                tickcnt <= tick ? 32'd0 : (tickcnt + 32'd1);

            // mtime: a write wins over the tick increment
            if      (wr && offs == `CLINT_MTIME)  mtime <= {mtime[63:32], wdata};
            else if (wr && offs == `CLINT_MTIMEH) mtime <= {wdata, mtime[31:0]};
            else if (tick)                        mtime <= mtime + 64'd1;

            if (wr && offs == `CLINT_MTIMECMP)  mtimecmp[31:0]  <= wdata;
            if (wr && offs == `CLINT_MTIMECMPH) mtimecmp[63:32] <= wdata;
            if (wr && offs == `CLINT_MSIP)      msip            <= wdata[0];
        end
    end
endmodule
