// The SoC: the RV32I core with peripherals on its data bus.
//
// Every block here came from a separate project in this repository. What was
// missing was the thing that makes them a system — an address decoder and a
// memory map both sides agree on. That map is generated from
// `socgen/memmap.py` into `soc_map.svh`, so the decode below and the firmware
// header cannot drift apart.
//
// The decode is on the top nibble of the address. One four-bit comparison is a
// single LUT level, and an SoC with four peripherals does not need a finer
// split.
//
// The TRNG is deliberately absent from this file. It is VHDL, and mixing VHDL
// into a Verilator or Icarus elaboration needs a mixed-language flow that is
// not in this repository's toolchain. It attaches at synthesis; the map still
// reserves its window, and saying so is better than quietly pretending the
// simulation covers it.

`include "soc_map.svh"

module soc_top #(
    parameter int CLK_HZ = 50_000_000
) (
    input  logic clk,
    input  logic rst,

    output logic uart_tx,
    input  logic uart_rx,

    // Visible for the testbench and for a debug header on real hardware.
    output logic [31:0] dbg_dmem_addr,
    output logic        dbg_dmem_we,
    output logic [63:0] dbg_cycles,
    output logic [63:0] dbg_instret
);

    // ---- core ---------------------------------------------------------------

    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_be;
    logic        dmem_we;

    logic [31:0] perf_branches, perf_mispredicts, perf_stall_cycles;

    riscv_core u_core (
        .clk               (clk),
        .rst               (rst),
        .imem_addr         (imem_addr),
        .imem_data         (imem_data),
        .dmem_addr         (dmem_addr),
        .dmem_wdata        (dmem_wdata),
        .dmem_be           (dmem_be),
        .dmem_we           (dmem_we),
        .dmem_rdata        (dmem_rdata),
        .perf_cycles       (dbg_cycles),
        .perf_instret      (dbg_instret),
        .perf_branches     (perf_branches),
        .perf_mispredicts  (perf_mispredicts),
        .perf_stall_cycles (perf_stall_cycles)
    );

    imem u_imem (.clk(clk), .addr(imem_addr), .data(imem_data));

    assign dbg_dmem_addr = dmem_addr;
    assign dbg_dmem_we   = dmem_we;

    // ---- address decode -----------------------------------------------------

    logic sel_ram, sel_uart, sel_spi, sel_aes;

    always_comb begin
        sel_ram  = (dmem_addr[31:28] == RAM_BASE[31:28]);
        sel_uart = (dmem_addr[31:28] == UART_BASE[31:28]) &&
                   (dmem_addr[15:12] == UART_BASE[15:12]);
        sel_spi  = (dmem_addr[31:28] == SPI_BASE[31:28]) &&
                   (dmem_addr[15:12] == SPI_BASE[15:12]);
        sel_aes  = (dmem_addr[31:28] == AES_BASE[31:28]);
    end

    // ---- RAM ----------------------------------------------------------------

    logic [31:0] ram_rdata;

    dmem u_ram (
        .clk   (clk),
        .addr  (dmem_addr),
        .wdata (dmem_wdata),
        .be    (dmem_be),
        .we    (dmem_we && sel_ram),
        .rdata (ram_rdata)
    );

    // ---- UART, on its APB port ----------------------------------------------
    //
    // The UART speaks APB and the core does not. APB's two-phase handshake
    // collapses to a single cycle for a slave that always asserts pready, which
    // this one does, so setup and access can be driven from the same strobe.

    logic [31:0] uart_rdata;
    logic        uart_ready, uart_irq;
    logic        uart_access_q;

    always_ff @(posedge clk) begin
        uart_access_q <= rst ? 1'b0 : sel_uart;
    end

    uart_core #(.CLK_HZ(CLK_HZ)) u_uart (
        .clk     (clk),
        .rst     (rst),
        .psel    (sel_uart),
        .penable (uart_access_q),
        .pwrite  (dmem_we),
        .paddr   (dmem_addr[4:0]),
        .pwdata  (dmem_wdata),
        .prdata  (uart_rdata),
        .pready  (uart_ready),
        .uart_tx (uart_tx),
        .uart_rx (uart_rx),
        .irq     (uart_irq)
    );

    // ---- AES ----------------------------------------------------------------

    logic [31:0] aes_rdata;

    aes_regs u_aes (
        .clk   (clk),
        .rst   (rst),
        .sel   (sel_aes),
        .addr  (dmem_addr[11:0]),
        .wdata (dmem_wdata),
        .we    (dmem_we),
        .rdata (aes_rdata)
    );

    // ---- read mux -----------------------------------------------------------
    //
    // Registered one cycle behind the select, because RAM and the UART both
    // return their data a cycle after the address — muxing on the current
    // select would return the previous peripheral's data.

    logic sel_ram_q, sel_uart_q, sel_aes_q;

    always_ff @(posedge clk) begin
        sel_ram_q  <= sel_ram;
        sel_uart_q <= sel_uart;
        sel_aes_q  <= sel_aes;
    end

    always_comb begin
        if      (sel_uart_q) dmem_rdata = uart_rdata;
        else if (sel_aes_q)  dmem_rdata = aes_rdata;
        else if (sel_ram_q)  dmem_rdata = ram_rdata;
        // An unmapped read returns zero rather than X. X would propagate into
        // the pipeline and turn a wrong address into an unreadable waveform
        // half a screen later.
        else                 dmem_rdata = 32'h0000_0000;
    end

endmodule
