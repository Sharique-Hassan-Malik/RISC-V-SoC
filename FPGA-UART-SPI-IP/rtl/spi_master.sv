// spi_master.sv — SPI master engine.
//
// Generates SCK, drives MOSI, captures MISO.
// Supports all four SPI modes (CPOL × CPHA) and MSB-first or LSB-first
// transfer order.  Bit width is configurable from 4 to 32 bits per transaction.
//
// Interface:
//   start    — Assert for one cycle to begin a transaction.
//              Data is sampled from tx_data on the same cycle.
//   tx_data  — Data to shift out (bits [cfg_bits-1:0] used).
//   rx_data  — Captured data after transaction completes.
//   done     — Asserts for one cycle when the transaction is complete.
//   busy     — High while a transaction is in progress.
//
// SPI mode encoding:
//   mode[1] = CPOL (clock polarity, idle level)
//   mode[0] = CPHA (clock phase, when data is sampled)
//
// SCK frequency = CLK_HZ / (2 × (cfg_div + 1))
// cfg_div = 0 → SCK = CLK_HZ / 2  (maximum speed)

`default_nettype none

module spi_master #(
    parameter int CLK_HZ = 50_000_000,
    parameter int DIV_W  = 8,
    parameter int DATA_W = 32
) (
    input  logic             clk,
    input  logic             rst,

    // User interface
    input  logic             start,
    input  logic [DATA_W-1:0] tx_data,
    output logic [DATA_W-1:0] rx_data,
    output logic             done,
    output logic             busy,

    // Configuration
    input  logic [DIV_W-1:0] cfg_div,      // SCK half-period = cfg_div+1 clocks
    input  logic [1:0]       cfg_mode,     // CPOL[1] CPHA[0]
    input  logic [5:0]       cfg_bits,     // 4..32 bits per transaction
    input  logic             cfg_lsb_first,// 1 = LSB first

    // SPI pins (CS managed externally)
    output logic             sck,
    output logic             mosi,
    input  logic             miso
);

    // ---- State machine --------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE    = 3'd0,
        S_LEAD    = 3'd1,   // CPHA=1: half-clock lead before first bit
        S_SHIFT   = 3'd2,
        S_TRAIL   = 3'd3,   // hold last SCK phase
        S_DONE    = 3'd4
    } spi_state_t;

    spi_state_t state = S_IDLE;

    logic [DIV_W-1:0] div_cnt;
    logic             phase_tick;        // toggle when div_cnt expires
    logic             sck_int;           // internal SCK
    logic [DATA_W-1:0] shift_tx;
    logic [DATA_W-1:0] shift_rx;
    logic [5:0]        bit_cnt;
    logic [5:0]        total_bits_m1;
    logic [1:0]        mode_r;
    logic              lsb_first_r;
    logic              cpol, cpha;

    assign cpol = mode_r[1];
    assign cpha = mode_r[0];

    assign phase_tick = (div_cnt == '0);

    always_ff @(posedge clk) begin
        if (rst)
            div_cnt <= '0;
        else if (state == S_IDLE)
            div_cnt <= cfg_div;
        else if (phase_tick)
            div_cnt <= cfg_div;
        else
            div_cnt <= div_cnt - 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            sck_int     <= 1'b0;
            mosi        <= 1'b0;
            done        <= 1'b0;
            busy        <= 1'b0;
            shift_rx    <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    sck_int  <= cpol;
                    busy     <= 1'b0;
                    if (start) begin
                        // Latch configuration and TX data
                        mode_r        <= cfg_mode;
                        lsb_first_r   <= cfg_lsb_first;
                        total_bits_m1 <= cfg_bits - 6'd1;
                        bit_cnt       <= '0;
                        busy          <= 1'b1;
                        shift_rx      <= '0;

                        if (cfg_lsb_first)
                            shift_tx <= tx_data;
                        else
                            // Rotate so that MSB appears at [DATA_W-1]
                            shift_tx <= tx_data << (DATA_W - cfg_bits);

                        // For CPHA=1 there is a half-clock lead delay before
                        // the first edge; for CPHA=0 start shifting immediately.
                        if (cfg_mode[0]) begin  // CPHA=1
                            state <= S_LEAD;
                        end else begin
                            state <= S_SHIFT;
                            // Drive MOSI with first bit immediately
                            mosi <= cfg_lsb_first ? tx_data[0] :
                                     tx_data[cfg_bits - 1];
                        end
                    end
                end

                S_LEAD: begin
                    // Wait one half clock period (CPHA=1 mode)
                    if (phase_tick) begin
                        sck_int <= ~cpol;   // first SCK edge
                        // Drive first MOSI bit on lead edge
                        mosi    <= lsb_first_r ? shift_tx[0] : shift_tx[DATA_W-1];
                        state   <= S_SHIFT;
                    end
                end

                S_SHIFT: begin
                    if (phase_tick) begin
                        sck_int <= ~sck_int;   // toggle SCK

                        if (sck_int == cpol) begin
                            // This is the active (sampling) edge for CPHA=0,
                            // or the trailing edge for CPHA=1.
                            // Capture MISO into shift_rx.
                            if (lsb_first_r) begin
                                shift_rx  <= {miso, shift_rx[DATA_W-1:1]};
                            end else begin
                                shift_rx  <= {shift_rx[DATA_W-2:0], miso};
                            end

                            if (bit_cnt == total_bits_m1) begin
                                state <= S_TRAIL;
                            end else begin
                                bit_cnt  <= bit_cnt + 1'b1;
                                // Shift TX register and update MOSI
                                if (lsb_first_r) begin
                                    shift_tx <= {1'b0, shift_tx[DATA_W-1:1]};
                                    mosi     <= shift_tx[1];
                                end else begin
                                    shift_tx <= {shift_tx[DATA_W-2:0], 1'b0};
                                    mosi     <= shift_tx[DATA_W-2];
                                end
                            end
                        end
                    end
                end

                S_TRAIL: begin
                    // Final half-clock to complete last SCK phase
                    if (phase_tick) begin
                        sck_int  <= cpol;   // return to idle
                        rx_data  <= shift_rx;
                        done     <= 1'b1;
                        state    <= S_DONE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b0;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // SCK output: idle at CPOL level
    assign sck = (busy) ? sck_int : cpol;

endmodule

`default_nettype wire
