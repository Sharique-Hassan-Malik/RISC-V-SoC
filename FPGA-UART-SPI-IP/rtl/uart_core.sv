// uart_core.sv — Parameterized UART IP core with APB register interface.
//
// ============================================================
// Parameters
// ============================================================
//   CLK_HZ        System clock frequency in Hz.
//   TX_FIFO_DEPTH TX FIFO depth (power of two, 4–256).
//   RX_FIFO_DEPTH RX FIFO depth (power of two, 4–256).
//   DIV_W         Width of the baud-rate divisor register (16 recommended).
//
// ============================================================
// APB Register Map (word-addressed, 4-byte stride)
// ============================================================
//   Offset 0x00  DATA_REG  [W] Write byte to TX FIFO  [R] Read byte from RX FIFO
//   Offset 0x04  STAT_REG  [R] Status flags (read-only)
//                  [0]  tx_full    — TX FIFO full
//                  [1]  tx_empty   — TX FIFO empty
//                  [2]  rx_full    — RX FIFO full
//                  [3]  rx_empty   — RX FIFO empty
//                  [4]  rx_overrun — RX byte was dropped (FIFO full)
//                  [5]  frame_err  — last received byte had a framing error
//                  [6]  parity_err — last received byte had a parity error
//   Offset 0x08  DIV_REG   [R/W] Baud rate divisor (DIV = CLK_HZ/baud - 1)
//   Offset 0x0C  CTRL_REG  [R/W] Frame format
//                  [2:0] data_bits — 5..8 (default 8)
//                  [4:3] parity    — 00=none 01=odd 10=even
//                  [5]   stop2     — 1 = two stop bits
//   Offset 0x10  IRQ_EN    [R/W] Interrupt enable mask
//                  [0] tx_empty IRQ enable
//                  [1] rx_not_empty IRQ enable
//                  [2] rx_overrun IRQ enable
//   Offset 0x14  IRQ_STAT  [R/W1C] Interrupt status (write 1 to clear)
//
// ============================================================
// Interrupt
// ============================================================
//   irq is asserted when any enabled IRQ condition is active.

`default_nettype none

module uart_core #(
    parameter int CLK_HZ        = 50_000_000,
    parameter int TX_FIFO_DEPTH = 16,
    parameter int RX_FIFO_DEPTH = 16,
    parameter int DIV_W         = 16
) (
    input  logic        clk,
    input  logic        rst,

    // APB slave interface
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [4:0]  paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,

    // Serial pins
    output logic        uart_tx,
    input  logic        uart_rx,

    // Interrupt
    output logic        irq
);

    // ---- Register file --------------------------------------------------
    logic [DIV_W-1:0] reg_div    = DIV_W'(CLK_HZ / 115200 - 1);
    logic [5:0]       reg_ctrl   = 6'b000_10_111;  // 8N1 default
    logic [2:0]       reg_irqen  = 3'b0;
    logic [2:0]       reg_irqstat = 3'b0;

    wire [2:0]  cfg_data_bits = reg_ctrl[2:0];
    wire [1:0]  cfg_parity    = reg_ctrl[4:3];
    wire        cfg_stop2     = reg_ctrl[5];

    // ---- TX FIFO --------------------------------------------------------
    logic       tx_fifo_wr, tx_fifo_rd;
    logic [7:0] tx_fifo_wdata, tx_fifo_rdata;
    logic       tx_fifo_full, tx_fifo_empty;

    sync_fifo #(.WIDTH(8), .DEPTH(TX_FIFO_DEPTH)) u_tx_fifo (
        .clk(clk), .rst(rst),
        .wr_en(tx_fifo_wr), .wr_data(tx_fifo_wdata),
        .rd_en(tx_fifo_rd), .rd_data(tx_fifo_rdata),
        .full(tx_fifo_full), .empty(tx_fifo_empty),
        .almost_full(), .almost_empty(), .count()
    );

    // ---- RX FIFO (10-bit: {parity_err, framing_err, data}) --------------
    logic        rx_fifo_wr, rx_fifo_rd;
    logic [9:0]  rx_fifo_wdata, rx_fifo_rdata;
    logic        rx_fifo_full, rx_fifo_empty;

    sync_fifo #(.WIDTH(10), .DEPTH(RX_FIFO_DEPTH)) u_rx_fifo (
        .clk(clk), .rst(rst),
        .wr_en(rx_fifo_wr), .wr_data(rx_fifo_wdata),
        .rd_en(rx_fifo_rd), .rd_data(rx_fifo_rdata),
        .full(rx_fifo_full), .empty(rx_fifo_empty),
        .almost_full(), .almost_empty(), .count()
    );

    // ---- UART TX engine -------------------------------------------------
    uart_tx #(.CLK_HZ(CLK_HZ), .DIV_W(DIV_W)) u_tx (
        .clk(clk), .rst(rst),
        .tx_fifo_empty(tx_fifo_empty),
        .tx_fifo_data(tx_fifo_rdata),
        .tx_fifo_rd(tx_fifo_rd),
        .cfg_div(reg_div),
        .cfg_data_bits(cfg_data_bits),
        .cfg_parity(cfg_parity),
        .cfg_stop2(cfg_stop2),
        .tx(uart_tx), .tx_busy()
    );

    // ---- UART RX engine -------------------------------------------------
    logic rx_overrun;

    uart_rx #(.CLK_HZ(CLK_HZ), .DIV_W(DIV_W)) u_rx (
        .clk(clk), .rst(rst),
        .rx(uart_rx),
        .rx_fifo_full(rx_fifo_full),
        .rx_fifo_wr(rx_fifo_wr),
        .rx_fifo_data(rx_fifo_wdata),
        .cfg_div(reg_div),
        .cfg_data_bits(cfg_data_bits),
        .cfg_parity(cfg_parity),
        .cfg_stop2(cfg_stop2),
        .rx_overrun(rx_overrun)
    );

    // ---- APB register interface -----------------------------------------
    logic apb_wr = psel && penable && pwrite;
    logic apb_rd = psel && !pwrite;

    assign pready     = 1'b1;   // zero-wait-state

    // Register reads
    always_comb begin
        prdata = 32'd0;
        rx_fifo_rd = 1'b0;
        case (paddr[4:2])
            3'd0: begin   // DATA_REG read
                prdata     = {22'd0, rx_fifo_rdata};
                rx_fifo_rd = apb_rd;
            end
            3'd1: prdata = {25'd0,
                            rx_fifo_rdata[9],   // parity_err
                            rx_fifo_rdata[8],   // framing_err
                            rx_overrun,
                            rx_fifo_empty,
                            rx_fifo_full,
                            tx_fifo_empty,
                            tx_fifo_full};
            3'd2: prdata = {{(32-DIV_W){1'b0}}, reg_div};
            3'd3: prdata = {26'd0, reg_ctrl};
            3'd4: prdata = {29'd0, reg_irqen};
            3'd5: prdata = {29'd0, reg_irqstat};
            default: prdata = 32'd0;
        endcase
    end

    // Register writes
    always_ff @(posedge clk) begin
        tx_fifo_wr    <= 1'b0;
        tx_fifo_wdata <= 8'h00;
        reg_irqstat   <= reg_irqstat & ~(apb_wr && (paddr[4:2] == 3'd5)
                                        ? pwdata[2:0] : 3'b0);

        if (rst) begin
            reg_div     <= DIV_W'(CLK_HZ / 115200 - 1);
            reg_ctrl    <= 6'b000_10_111;
            reg_irqen   <= 3'b0;
            reg_irqstat <= 3'b0;
        end else if (apb_wr) begin
            case (paddr[4:2])
                3'd0: begin   // DATA_REG write → push to TX FIFO
                    if (!tx_fifo_full) begin
                        tx_fifo_wr    <= 1'b1;
                        tx_fifo_wdata <= pwdata[7:0];
                    end
                end
                3'd2: reg_div    <= pwdata[DIV_W-1:0];
                3'd3: reg_ctrl   <= pwdata[5:0];
                3'd4: reg_irqen  <= pwdata[2:0];
                3'd5: reg_irqstat <= reg_irqstat & ~pwdata[2:0];  // W1C
                default: ;
            endcase
        end

        // IRQ status update
        if (tx_fifo_empty)   reg_irqstat[0] <= 1'b1;
        if (!rx_fifo_empty)  reg_irqstat[1] <= 1'b1;
        if (rx_overrun)      reg_irqstat[2] <= 1'b1;
    end

    assign irq = |(reg_irqstat & reg_irqen);

endmodule

`default_nettype wire
