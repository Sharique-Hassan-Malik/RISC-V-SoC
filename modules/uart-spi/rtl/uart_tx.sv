// uart_tx.sv — UART transmit engine.
//
// Accepts bytes from the TX FIFO and serialises them at the configured
// baud rate.  All framing parameters are runtime-programmable via the
// cfg_* ports so the divider and frame shape can change between bytes.
//
// Frame format: [START] [DATA bits, LSB first] [PARITY?] [STOP bits]
//
// Parameters:
//   CLK_HZ      System clock frequency (for divider width calculation only).
//   DIV_W       Width of the baud-rate divider register (default 16).
//               DIV = CLK_HZ / baud - 1.
//
// cfg_div       Baud rate divisor (sampled at start of each frame).
// cfg_data_bits Number of data bits: 5, 6, 7 or 8.
// cfg_parity    2'b00 = none, 2'b01 = odd, 2'b10 = even.
// cfg_stop_bits 1 or 2 stop bits.
//
// tx_fifo_rd and tx_fifo_data interface to a sync_fifo external to this module.

`default_nettype none

module uart_tx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int DIV_W  = 16
) (
    input  logic             clk,
    input  logic             rst,

    // FIFO interface
    input  logic             tx_fifo_empty,
    input  logic [7:0]       tx_fifo_data,
    output logic             tx_fifo_rd,

    // Configuration (sampled at start of each new frame)
    input  logic [DIV_W-1:0] cfg_div,
    input  logic [2:0]       cfg_data_bits,  // 5..8
    input  logic [1:0]       cfg_parity,     // 00=none 01=odd 10=even
    input  logic             cfg_stop2,      // 1 = two stop bits

    // Serial output
    output logic             tx,
    output logic             tx_busy
);

    // ---- State machine --------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_START  = 3'd1,
        S_DATA   = 3'd2,
        S_PARITY = 3'd3,
        S_STOP1  = 3'd4,
        S_STOP2  = 3'd5
    } state_t;

    state_t          state = S_IDLE;
    logic [DIV_W-1:0] baud_cnt;
    logic             baud_tick;
    logic [7:0]       shift;
    logic [2:0]       bit_cnt;
    logic [2:0]       data_bits_m1;   // cfg_data_bits - 1 (latched)
    logic [1:0]       parity_cfg;
    logic             stop2;
    logic             parity_acc;

    assign baud_tick = (baud_cnt == '0);
    assign tx_busy   = (state != S_IDLE);

    // Baud counter
    always_ff @(posedge clk) begin
        if (rst) begin
            baud_cnt <= '0;
        end else if (state == S_IDLE) begin
            baud_cnt <= cfg_div;
        end else if (baud_tick) begin
            baud_cnt <= cfg_div;
        end else begin
            baud_cnt <= baud_cnt - 1'b1;
        end
    end

    // FIFO read: issue read one cycle before we need the data
    logic fetch_pending;
    always_ff @(posedge clk) begin
        if (rst) begin
            tx_fifo_rd    <= 1'b0;
            fetch_pending <= 1'b0;
        end else begin
            tx_fifo_rd <= 1'b0;
            if (state == S_IDLE && !tx_fifo_empty && !fetch_pending) begin
                tx_fifo_rd    <= 1'b1;
                fetch_pending <= 1'b1;
            end
            if (fetch_pending && state != S_IDLE)
                fetch_pending <= 1'b0;
        end
    end

    // Main FSM
    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            tx         <= 1'b1;
            shift      <= 8'hFF;
            bit_cnt    <= '0;
            parity_acc <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (fetch_pending) begin
                        // Latch configuration and data
                        shift        <= tx_fifo_data;
                        data_bits_m1 <= cfg_data_bits - 3'd1;
                        parity_cfg   <= cfg_parity;
                        stop2        <= cfg_stop2;
                        parity_acc   <= 1'b0;
                        bit_cnt      <= '0;
                        state        <= S_START;
                    end
                end

                S_START: if (baud_tick) begin
                    tx    <= 1'b0;   // start bit
                    state <= S_DATA;
                end

                S_DATA: if (baud_tick) begin
                    tx         <= shift[0];
                    parity_acc <= parity_acc ^ shift[0];
                    shift      <= {1'b1, shift[7:1]};  // LSB first
                    if (bit_cnt == data_bits_m1) begin
                        bit_cnt <= '0;
                        state   <= (parity_cfg != 2'b00) ? S_PARITY : S_STOP1;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                S_PARITY: if (baud_tick) begin
                    // Even parity: tx parity_acc; Odd parity: tx ~parity_acc
                    tx    <= (parity_cfg == 2'b01) ? ~parity_acc : parity_acc;
                    state <= S_STOP1;
                end

                S_STOP1: if (baud_tick) begin
                    tx    <= 1'b1;   // stop bit
                    state <= stop2 ? S_STOP2 : S_IDLE;
                end

                S_STOP2: if (baud_tick) begin
                    tx    <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
