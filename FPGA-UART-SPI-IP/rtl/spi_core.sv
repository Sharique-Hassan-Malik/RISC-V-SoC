// spi_core.sv — Parameterized SPI master IP core with APB register interface.
//
// ============================================================
// Parameters
// ============================================================
//   CLK_HZ        System clock frequency in Hz.
//   TX_FIFO_DEPTH TX FIFO depth (power of two, 4..256). Stores 32-bit words.
//   RX_FIFO_DEPTH RX FIFO depth (power of two).
//   CS_COUNT      Number of hardware chip-select outputs (1..8).
//   DIV_W         Clock divider width.
//   DATA_W        Max data width per transaction (default 32).
//
// ============================================================
// APB Register Map (word-addressed)
// ============================================================
//   0x00  DATA_TX   [W] Write 32-bit word to TX FIFO; starts transaction
//                       when not busy.
//   0x04  DATA_RX   [R] Read 32-bit word from RX FIFO.
//   0x08  STAT      [R] {tx_full, tx_empty, rx_full, rx_empty, busy}
//   0x0C  CTRL      [R/W]
//                  [7:0]  cfg_div       SCK half-period = div+1 clocks
//                  [9:8]  cfg_mode      SPI mode (CPOL CPHA)
//                  [15:10] cfg_bits     Bits per transaction (4..32)
//                  [16]   cfg_lsb_first
//                  [19:17] cfg_cs_sel   Which CS to assert (0..CS_COUNT-1)
//                  [20]   cfg_cs_pol    CS polarity (0=active-low, 1=active-high)
//   0x10  IRQ_EN    [R/W] {rx_not_empty_en, tx_empty_en}
//   0x14  IRQ_STAT  [R/W1C] {rx_not_empty, tx_empty}
//
// ============================================================
// Operation
// ============================================================
//   1. Set CTRL register (mode, divider, bit count, CS select).
//   2. Write data word to DATA_TX.  The core asserts the selected CS,
//      executes the SPI transaction, deasserts CS, and stores the RX
//      word in the RX FIFO.
//   3. Read DATA_RX to retrieve the received data.
//   Transactions execute back-to-back as long as data is in the TX FIFO.

`default_nettype none

module spi_core #(
    parameter int CLK_HZ        = 50_000_000,
    parameter int TX_FIFO_DEPTH = 8,
    parameter int RX_FIFO_DEPTH = 8,
    parameter int CS_COUNT      = 1,
    parameter int DIV_W         = 8,
    parameter int DATA_W        = 32
) (
    input  logic        clk,
    input  logic        rst,

    // APB slave
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [4:0]  paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,

    // SPI pins
    output logic                  sck,
    output logic                  mosi,
    input  logic                  miso,
    output logic [CS_COUNT-1:0]   cs_n,   // active-low by default

    // Interrupt
    output logic        irq
);

    // ---- Registers -------------------------------------------------------
    logic [DIV_W-1:0] reg_div       = '0;
    logic [1:0]       reg_mode      = 2'b00;
    logic [5:0]       reg_bits      = 6'd8;
    logic             reg_lsb_first = 1'b0;
    logic [2:0]       reg_cs_sel    = '0;
    logic             reg_cs_pol    = 1'b0;   // 0 = active-low
    logic [1:0]       reg_irqen     = 2'b0;
    logic [1:0]       reg_irqstat   = 2'b0;

    // ---- TX FIFO (32-bit words) -----------------------------------------
    logic        tx_fifo_wr, tx_fifo_rd;
    logic [31:0] tx_fifo_wdata, tx_fifo_rdata;
    logic        tx_fifo_full, tx_fifo_empty;

    sync_fifo #(.WIDTH(32), .DEPTH(TX_FIFO_DEPTH)) u_tx_fifo (
        .clk(clk), .rst(rst),
        .wr_en(tx_fifo_wr), .wr_data(tx_fifo_wdata),
        .rd_en(tx_fifo_rd), .rd_data(tx_fifo_rdata),
        .full(tx_fifo_full), .empty(tx_fifo_empty),
        .almost_full(), .almost_empty(), .count()
    );

    // ---- RX FIFO (32-bit words) -----------------------------------------
    logic        rx_fifo_wr, rx_fifo_rd;
    logic [31:0] rx_fifo_wdata, rx_fifo_rdata;
    logic        rx_fifo_full, rx_fifo_empty;

    sync_fifo #(.WIDTH(32), .DEPTH(RX_FIFO_DEPTH)) u_rx_fifo (
        .clk(clk), .rst(rst),
        .wr_en(rx_fifo_wr), .wr_data(rx_fifo_wdata),
        .rd_en(rx_fifo_rd), .rd_data(rx_fifo_rdata),
        .full(rx_fifo_full), .empty(rx_fifo_empty),
        .almost_full(), .almost_empty(), .count()
    );

    // ---- SPI master engine ----------------------------------------------
    logic             spi_start, spi_done, spi_busy;
    logic [DATA_W-1:0] spi_tx_data, spi_rx_data;

    spi_master #(.CLK_HZ(CLK_HZ), .DIV_W(DIV_W), .DATA_W(DATA_W)) u_spi (
        .clk(clk), .rst(rst),
        .start(spi_start), .tx_data(spi_tx_data),
        .rx_data(spi_rx_data), .done(spi_done), .busy(spi_busy),
        .cfg_div(reg_div), .cfg_mode(reg_mode),
        .cfg_bits(reg_bits), .cfg_lsb_first(reg_lsb_first),
        .sck(sck), .mosi(mosi), .miso(miso)
    );

    // ---- Transaction sequencer ------------------------------------------
    logic [2:0] active_cs;   // latched when transaction starts

    always_ff @(posedge clk) begin
        spi_start    <= 1'b0;
        tx_fifo_rd   <= 1'b0;
        rx_fifo_wr   <= 1'b0;

        if (rst) begin
            cs_n <= {CS_COUNT{1'b1}};
        end else begin
            if (!spi_busy && !tx_fifo_empty && !spi_start) begin
                // Pull from TX FIFO and start a transaction
                spi_tx_data <= tx_fifo_rdata;
                active_cs   <= reg_cs_sel;
                tx_fifo_rd  <= 1'b1;
                spi_start   <= 1'b1;
                // Assert CS
                cs_n[reg_cs_sel] <= reg_cs_pol;   // active level
            end

            if (spi_done) begin
                rx_fifo_wdata <= spi_rx_data;
                rx_fifo_wr    <= 1'b1;
                // Deassert CS (back to idle level)
                cs_n[active_cs] <= ~reg_cs_pol;
            end
        end
    end

    // ---- APB interface --------------------------------------------------
    assign pready    = 1'b1;

    always_comb begin
        prdata     = 32'd0;
        rx_fifo_rd = 1'b0;
        case (paddr[4:2])
            3'd0: ;   // write-only TX
            3'd1: begin
                prdata     = {{(32-DATA_W){1'b0}}, rx_fifo_rdata[DATA_W-1:0]};
                rx_fifo_rd = psel && !pwrite;
            end
            3'd2: prdata = {27'd0, spi_busy, rx_fifo_empty, rx_fifo_full,
                                   tx_fifo_empty, tx_fifo_full};
            3'd3: prdata = {11'd0, reg_cs_pol, reg_cs_sel, reg_lsb_first,
                                   reg_bits, reg_mode, reg_div};
            3'd4: prdata = {30'd0, reg_irqen};
            3'd5: prdata = {30'd0, reg_irqstat};
            default: prdata = 32'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        tx_fifo_wr    <= 1'b0;
        tx_fifo_wdata <= '0;

        if (rst) begin
            reg_div     <= '0;
            reg_mode    <= 2'b00;
            reg_bits    <= 6'd8;
            reg_lsb_first <= 1'b0;
            reg_cs_sel  <= '0;
            reg_cs_pol  <= 1'b0;
            reg_irqen   <= 2'b0;
            reg_irqstat <= 2'b0;
        end else begin
            if (psel && penable && pwrite) begin
                case (paddr[4:2])
                    3'd0: if (!tx_fifo_full) begin
                              tx_fifo_wr    <= 1'b1;
                              tx_fifo_wdata <= pwdata;
                          end
                    3'd3: begin
                        reg_div       <= pwdata[DIV_W-1:0];
                        reg_mode      <= pwdata[DIV_W+1:DIV_W];
                        reg_bits      <= pwdata[DIV_W+7:DIV_W+2];
                        reg_lsb_first <= pwdata[DIV_W+8];
                        reg_cs_sel    <= pwdata[DIV_W+11:DIV_W+9];
                        reg_cs_pol    <= pwdata[DIV_W+12];
                    end
                    3'd4: reg_irqen   <= pwdata[1:0];
                    3'd5: reg_irqstat <= reg_irqstat & ~pwdata[1:0];
                    default: ;
                endcase
            end

            // IRQ status
            if (tx_fifo_empty)   reg_irqstat[0] <= 1'b1;
            if (!rx_fifo_empty)  reg_irqstat[1] <= 1'b1;
        end
    end

    assign irq = |(reg_irqstat & reg_irqen);

endmodule

`default_nettype wire
