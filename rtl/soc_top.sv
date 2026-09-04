// The SoC: the RV32I core with peripherals on its data bus.
//
// Every block here came from a separate project in this repository. What was
// missing was the thing that makes them a system — an address decoder and a
// memory map both sides agree on. That map is generated from
// `socgen/memmap.py` into `soc_map.svh`, so the decode below and the firmware
// header cannot drift apart.
//
// The decode is on the top nibble of the address. One four-bit comparison is a
// single LUT level, and an SoC this size does not need a finer split.
//
// The CLINT is what lets an interrupt reach the core at all: the UART has had
// IRQ_EN and IRQ_STAT since it was written, and before the core had CSRs there
// was nothing on the other end of that line. See docs/traps.md.
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
        .perf_stall_cycles (perf_stall_cycles),
        .irq_timer         (clint_mtip),
        .irq_soft          (clint_msip),
        // The UART's own irq line, which had nowhere to go until the core grew
        // an mip. It is the machine *external* interrupt here: there is no
        // PLIC, so with one external source the two are the same thing.
        .irq_ext           (uart_irq)
    );

    imem u_imem (.clk(clk), .addr(imem_addr), .data(imem_data));

    assign dbg_dmem_addr = dmem_addr;
    assign dbg_dmem_we   = dmem_we;

    // ---- address decode -----------------------------------------------------

    logic sel_ram, sel_uart, sel_spi, sel_aes, sel_clint;

    always_comb begin
        sel_ram  = (dmem_addr[31:28] == RAM_BASE[31:28]);
        sel_clint = (dmem_addr[31:28] == CLINT_BASE[31:28]);
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

    // ---- CLINT --------------------------------------------------------------
    //
    // The timer and software interrupt. Its window is 64 kB rather than the
    // 4 kB the other peripherals get, because mtime sits at offset 0xBFF8 —
    // SiFive's layout, kept so existing firmware is not wrong here.

    logic [31:0] clint_rdata;
    logic        clint_mtip, clint_msip;

    clint u_clint (
        .clk   (clk),
        .rst   (rst),
        .sel   (sel_clint),
        .addr  (dmem_addr[15:0]),
        .we    (dmem_we),
        .wdata (dmem_wdata),
        .rdata (clint_rdata),
        .mtip  (clint_mtip),
        .msip  (clint_msip)
    );

    // ---- read mux -----------------------------------------------------------
    //
    // Registered one cycle behind the select, because RAM and the UART both
    // return their data a cycle after the address — muxing on the current
    // select would return the previous peripheral's data.

    logic sel_ram_q, sel_uart_q, sel_aes_q, sel_clint_q;

    always_ff @(posedge clk) begin
        sel_ram_q   <= sel_ram;
        sel_uart_q  <= sel_uart;
        sel_aes_q   <= sel_aes;
        sel_clint_q <= sel_clint;
    end

    always_comb begin
        if      (sel_uart_q)  dmem_rdata = uart_rdata;
        else if (sel_aes_q)   dmem_rdata = aes_rdata;
        else if (sel_clint_q) dmem_rdata = clint_rdata;
        else if (sel_ram_q)   dmem_rdata = ram_rdata;
        // An unmapped read returns zero rather than X. X would propagate into
        // the pipeline and turn a wrong address into an unreadable waveform
        // half a screen later.
        else                 dmem_rdata = 32'h0000_0000;
    end

endmodule
