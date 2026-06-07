// soc_top.sv - the integrated SoC: RV32IM core + RAM + CLINT + UART + GPIO.
//
//   imem (fetch) ----------------------------------> RAM
//   dmem (load/store) --[ address decode ]--+------> RAM      0x0000_xxxx
//                                           +------> CLINT    0x0200_xxxx (mtime/cmp/msip)
//                                           +------> UART     0x1000_xxxx
//                                           +------> GPIO     0x1001_xxxx
//   CLINT.timer_irq / sw_irq ---------------------> CPU machine interrupts
//
// Single-cycle bus: every data access completes in the cycle it is issued
// (combinational read mux, registered writes in the targeted block). The CLINT
// machine timer drives the CPU's timer interrupt, exercising the trap/CSR path.
`include "soc_map.svh"

module soc_top #(
    parameter int    RAM_WORDS    = 4096,        // 16 KiB code+data
    parameter        INITFILE     = "",          // untyped: iverilog passthrough
    parameter int    UART_DIV     = 16,          // core clocks per UART bit
    parameter int    TICK_DIV     = 1,           // core clocks per mtime tick
    parameter int    GPIO_W       = 32,
    parameter int    SYNC_MEM     = 0,           // 1 = synchronous RAM (SRAM macro)
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic              clk,
    input  logic              rst_n,
    // GPIO
    output logic [GPIO_W-1:0] gpio_out,
    input  logic [GPIO_W-1:0] gpio_in,
    // UART
    output logic              uart_tx,
    output logic              uart_tx_strobe,    // 1-cycle pulse per byte (debug/monitor)
    output logic [7:0]        uart_tx_byte,
    // observation (RVFI-lite retire + PC), for testbenches
    output logic              dbg_timer_irq,
    output logic [31:0]       dbg_pc,
    output logic              rvfi_valid,
    output logic [31:0]       rvfi_pc,
    output logic [4:0]        rvfi_rd,
    output logic              rvfi_we,
    output logic [31:0]       rvfi_wdata
);
    // ---- CPU <-> memory wires ----------------------------------------------
    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_be;
    logic        dmem_we;
    logic        timer_irq, sw_irq;

    assign dbg_timer_irq = timer_irq;

    logic imem_rdy, dmem_rdy;
    riscv_pipeline #(.XLEN(32), .RESET_PC(RESET_PC)) u_cpu (
        .clk, .rst_n,
        .imem_addr, .imem_rdata, .imem_ready(imem_rdy),
        .dmem_addr, .dmem_wdata, .dmem_be, .dmem_we, .dmem_rdata, .dmem_ready(dmem_rdy),
        .sw_irq(sw_irq), .timer_irq(timer_irq), .ext_irq(1'b0),
        .dbg_pc,
        .rvfi_valid, .rvfi_pc, .rvfi_rd, .rvfi_we, .rvfi_wdata
    );

    // ---- address decode (data port) ----------------------------------------
    wire sel_ram   = (dmem_addr[31:16] == `RAM_PAGE);   // low 64 KiB -> RAM
    wire sel_clint = (dmem_addr[31:16] == `CLINT_PAGE);
    wire sel_uart  = (dmem_addr[31:16] == `UART_PAGE);
    wire sel_gpio  = (dmem_addr[31:16] == `GPIO_PAGE);
    wire [15:0] offs = dmem_addr[15:0];

    // ---- RAM (fetch + data): async single-cycle, or synchronous SRAM macro --
    logic [31:0] ram_rdata;
    logic        ram_i_ready, ram_d_ready;
    generate
        if (SYNC_MEM != 0) begin : g_sync_ram
            soc_ram_sync #(.WORDS(RAM_WORDS), .INITFILE(INITFILE)) u_ram (
                .clk, .rst_n,
                .i_addr(imem_addr), .i_rdata(imem_rdata), .i_ready(ram_i_ready),
                .d_addr(dmem_addr), .d_wdata(dmem_wdata), .d_be(dmem_be),
                .d_we(dmem_we && sel_ram), .d_rdata(ram_rdata), .d_ready(ram_d_ready)
            );
        end else begin : g_async_ram
            soc_ram #(.WORDS(RAM_WORDS), .INITFILE(INITFILE)) u_ram (
                .clk,
                .i_addr(imem_addr), .i_rdata(imem_rdata),
                .d_addr(dmem_addr), .d_wdata(dmem_wdata), .d_be(dmem_be),
                .d_we(dmem_we && sel_ram), .d_rdata(ram_rdata)
            );
            assign ram_i_ready = 1'b1;
            assign ram_d_ready = 1'b1;
        end
    endgenerate

    // memory-wait readiness to the CPU. Fetch is always RAM; for data, the
    // peripherals answer combinationally (ready=1) and only RAM carries latency.
    assign imem_rdy = ram_i_ready;
    assign dmem_rdy = sel_ram ? ram_d_ready : 1'b1;

    // ---- CLINT machine timer ------------------------------------------------
    logic [31:0] clint_rdata;
    mtimer #(.TICK_DIV(TICK_DIV)) u_clint (
        .clk, .rst_n,
        .sel(sel_clint), .we(dmem_we), .offs(offs), .wdata(dmem_wdata),
        .rdata(clint_rdata), .timer_irq(timer_irq), .sw_irq(sw_irq)
    );

    // ---- UART ---------------------------------------------------------------
    logic [31:0] uart_rdata;
    uart_tx #(.CLKS_PER_BIT(UART_DIV)) u_uart (
        .clk, .rst_n,
        .sel(sel_uart), .we(dmem_we), .offs(offs), .wdata(dmem_wdata),
        .rdata(uart_rdata),
        .tx(uart_tx), .tx_strobe(uart_tx_strobe), .tx_byte(uart_tx_byte)
    );

    // ---- GPIO ---------------------------------------------------------------
    logic [31:0] gpio_rdata;
    gpio #(.W(GPIO_W)) u_gpio (
        .clk, .rst_n,
        .sel(sel_gpio), .we(dmem_we), .offs(offs), .wdata(dmem_wdata),
        .rdata(gpio_rdata), .gpio_out(gpio_out), .gpio_in(gpio_in)
    );

    // ---- data read mux ------------------------------------------------------
    always_comb begin
        if      (sel_clint) dmem_rdata = clint_rdata;
        else if (sel_uart)  dmem_rdata = uart_rdata;
        else if (sel_gpio)  dmem_rdata = gpio_rdata;
        else                dmem_rdata = ram_rdata;     // default region: RAM
    end
endmodule
