// uart_rx.sv — UART receive engine with 3× oversampling and majority vote.
//
// Samples the RX input 16× per bit period (oversampling ratio fixed at 16).
// The baud divisor should be set to CLK_HZ / (baud × 16) - 1 for the
// oversample clock, or equivalently cfg_div = CLK_HZ / baud - 1 and the
// internal oversample count divides by 16.
//
// For simplicity this implementation uses 16× oversampling with a divide-by-16
// on the baud divider: the sample clock ticks at 16× baud, and each bit is
// sampled at tick 7 (the centre of the bit period).
//
// Majority vote: bits 6, 7, 8 (out of 0–15) are read and two-of-three voting
// applied to filter noise.
//
// Flags set in rx_flags when a byte is pushed to the RX FIFO:
//   rx_flags[0] = framing error (stop bit was not 1)
//   rx_flags[1] = parity error
// Flags accompany the data byte into the FIFO (9-bit entry: {flags, data}).

`default_nettype none

module uart_rx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int DIV_W  = 16
) (
    input  logic              clk,
    input  logic              rst,

    // Serial input (asynchronous — synchronised internally)
    input  logic              rx,

    // FIFO write interface (data + flags)
    input  logic              rx_fifo_full,
    output logic              rx_fifo_wr,
    output logic [9:0]        rx_fifo_data,   // {parity_err, framing_err, byte}

    // Configuration
    input  logic [DIV_W-1:0]  cfg_div,         // CLK_HZ / baud - 1
    input  logic [2:0]        cfg_data_bits,
    input  logic [1:0]        cfg_parity,
    input  logic              cfg_stop2,

    // Status
    output logic              rx_overrun        // FIFO full on received byte
);

    // ---- 2-FF input synchroniser ----------------------------------------
    logic rx_s1 = 1'b1, rx_s2 = 1'b1, rx_s3 = 1'b1;
    always_ff @(posedge clk) begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
        rx_s3 <= rx_s2;
    end
    wire rx_sync = rx_s3;

    // ---- 16× oversample clock tick --------------------------------------
    logic [DIV_W-1:0] sample_cnt;
    logic [3:0]       bit_phase;     // 0..15 within each bit period
    logic             sample_tick;

    // sample_tick fires at the system clock rate; we divide cfg_div+1 by 16
    // to get the oversample period.
    // Oversample divisor = (cfg_div + 1) / 16, subtract 1.
    // For exact results cfg_div should be CLK_HZ / baud - 1, and we internally
    // use a separate counter that counts to (cfg_div+1)/16 - 1.
    logic [DIV_W-1:0] os_div;
    assign os_div = (cfg_div >> 4);   // ≈ CLK_HZ / (baud × 16)

    logic [DIV_W-1:0] os_cnt;
    assign sample_tick = (os_cnt == '0);

    always_ff @(posedge clk) begin
        if (rst)
            os_cnt <= os_div;
        else if (sample_tick)
            os_cnt <= os_div;
        else
            os_cnt <= os_cnt - 1'b1;
    end

    // ---- FSM -----------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_START  = 3'd1,
        S_DATA   = 3'd2,
        S_PARITY = 3'd3,
        S_STOP   = 3'd4
    } rx_state_t;

    rx_state_t state = S_IDLE;

    logic [3:0]  phase;        // sample phase counter 0..15 within a bit
    logic [7:0]  shift;
    logic [2:0]  bit_cnt;
    logic [2:0]  data_bits_m1;
    logic [1:0]  parity_cfg_r;
    logic        parity_acc;
    logic        framing_err;
    logic        parity_err;

    // Three majority-vote samples at phases 6, 7, 8
    logic [2:0] vote_buf;

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            rx_fifo_wr  <= 1'b0;
            rx_overrun  <= 1'b0;
            phase       <= '0;
        end else begin
            rx_fifo_wr <= 1'b0;

            if (sample_tick) begin
                case (state)
                    S_IDLE: begin
                        phase <= '0;
                        if (!rx_sync) begin   // falling edge = start bit
                            state <= S_START;
                            phase <= 4'd0;
                        end
                    end

                    S_START: begin
                        phase <= phase + 1'b1;
                        if (phase == 4'd7) begin
                            // Verify centre of start bit is still low
                            if (!rx_sync) begin
                                state        <= S_DATA;
                                bit_cnt      <= '0;
                                data_bits_m1 <= cfg_data_bits - 3'd1;
                                parity_cfg_r <= cfg_parity;
                                parity_acc   <= 1'b0;
                                phase        <= '0;
                            end else begin
                                state <= S_IDLE;   // false start
                            end
                        end
                    end

                    S_DATA: begin
                        phase <= phase + 1'b1;
                        // Collect majority-vote samples at phases 6,7,8
                        if (phase == 4'd6) vote_buf[0] <= rx_sync;
                        if (phase == 4'd7) vote_buf[1] <= rx_sync;
                        if (phase == 4'd8) begin
                            vote_buf[2] <= rx_sync;
                        end
                        if (phase == 4'd15) begin
                            // Majority vote
                            logic sampled;
                            sampled    = (vote_buf[0] & vote_buf[1]) |
                                         (vote_buf[1] & vote_buf[2]) |
                                         (vote_buf[0] & vote_buf[2]);
                            shift      <= {sampled, shift[7:1]};
                            parity_acc <= parity_acc ^ sampled;
                            phase      <= '0;
                            if (bit_cnt == data_bits_m1) begin
                                bit_cnt <= '0;
                                state   <= (parity_cfg_r != 2'b00) ? S_PARITY : S_STOP;
                            end else begin
                                bit_cnt <= bit_cnt + 1'b1;
                            end
                        end
                    end

                    S_PARITY: begin
                        phase <= phase + 1'b1;
                        if (phase == 4'd7) vote_buf[1] <= rx_sync;
                        if (phase == 4'd15) begin
                            logic expected_par;
                            expected_par = (parity_cfg_r == 2'b01) ? ~parity_acc : parity_acc;
                            parity_err   <= (vote_buf[1] != expected_par);
                            state        <= S_STOP;
                            phase        <= '0;
                        end
                    end

                    S_STOP: begin
                        phase <= phase + 1'b1;
                        if (phase == 4'd15) begin
                            framing_err <= !rx_sync;
                            if (rx_fifo_full) begin
                                rx_overrun <= 1'b1;
                            end else begin
                                rx_fifo_wr   <= 1'b1;
                                rx_fifo_data <= {parity_err, framing_err, shift};
                            end
                            state <= S_IDLE;
                            phase <= '0;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
