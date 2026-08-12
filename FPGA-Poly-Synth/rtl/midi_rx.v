// midi_rx.v — MIDI 31250-baud UART receiver and message parser.
//
// Receives raw MIDI bytes from a DIN-5 optocoupler output and assembles
// them into three-byte messages (Note On, Note Off, Control Change).
//
// Parameters:
//   CLK_HZ     System clock frequency in Hz.
//   MIDI_BAUD  MIDI baud rate (always 31250 for standard MIDI).
//
// Outputs (registered, valid for one clock when msg_valid is high):
//   msg_type   2'b01 = Note On, 2'b10 = Note Off, 2'b11 = CC
//   msg_ch     4-bit MIDI channel (0 = channel 1)
//   msg_b1     First data byte  (note number or CC number)
//   msg_b2     Second data byte (velocity or CC value)
//
// Running status: a second data byte pair re-uses the last status byte,
// allowing sequencers to omit repeated status bytes.

module midi_rx #(
    parameter CLK_HZ    = 12000000,
    parameter MIDI_BAUD = 31250
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,          // UART RX input (idle high, active low)
    output reg  [1:0] msg_type,    // 01=NoteOn 10=NoteOff 11=CC
    output reg  [3:0] msg_ch,
    output reg  [7:0] msg_b1,
    output reg  [7:0] msg_b2,
    output reg        msg_valid
);

    // ---- Baud rate divider ------------------------------------------------
    localparam integer BIT_TICKS = CLK_HZ / MIDI_BAUD;    // ticks per bit
    localparam integer HALF_BIT  = BIT_TICKS / 2;         // centre of bit

    // ---- UART receiver state machine -------------------------------------
    localparam UART_IDLE  = 2'd0;
    localparam UART_START = 2'd1;
    localparam UART_DATA  = 2'd2;
    localparam UART_STOP  = 2'd3;

    reg [1:0]  uart_state;
    reg [15:0] baud_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  shift;
    reg        rx_sync1, rx_sync2;   // two-stage synchroniser
    reg        byte_valid;
    reg [7:0]  byte_out;

    // Two-flip-flop synchroniser on async RX input.
    always @(posedge clk) begin
        rx_sync1 <= rx;
        rx_sync2 <= rx_sync1;
    end

    always @(posedge clk) begin
        if (rst) begin
            uart_state <= UART_IDLE;
            byte_valid <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            case (uart_state)
                UART_IDLE: begin
                    if (!rx_sync2) begin          // falling edge = start bit
                        uart_state <= UART_START;
                        baud_cnt   <= HALF_BIT;   // wait to centre of start bit
                    end
                end
                UART_START: begin
                    if (baud_cnt == 0) begin
                        if (!rx_sync2) begin       // still low — valid start bit
                            uart_state <= UART_DATA;
                            baud_cnt   <= BIT_TICKS;
                            bit_idx    <= 4'd0;
                            shift      <= 8'd0;
                        end else begin
                            uart_state <= UART_IDLE;
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                UART_DATA: begin
                    if (baud_cnt == 0) begin
                        shift    <= {rx_sync2, shift[7:1]};  // LSB first
                        baud_cnt <= BIT_TICKS;
                        bit_idx  <= bit_idx + 1;
                        if (bit_idx == 4'd7) begin
                            uart_state <= UART_STOP;
                            baud_cnt   <= BIT_TICKS;
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                UART_STOP: begin
                    if (baud_cnt == 0) begin
                        byte_out   <= shift;
                        byte_valid <= rx_sync2;   // valid only if stop bit high
                        uart_state <= UART_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                default: uart_state <= UART_IDLE;
            endcase
        end
    end

    // ---- MIDI message assembler ------------------------------------------
    // States: waiting for status, waiting for data1, waiting for data2.
    localparam MSG_STATUS = 2'd0;
    localparam MSG_DATA1  = 2'd1;
    localparam MSG_DATA2  = 2'd2;

    reg [1:0] msg_state;
    reg [7:0] status_byte;
    reg [7:0] data1_byte;

    always @(posedge clk) begin
        if (rst) begin
            msg_state <= MSG_STATUS;
            msg_valid <= 1'b0;
            msg_type  <= 2'b00;
            msg_ch    <= 4'h0;
            msg_b1    <= 8'h0;
            msg_b2    <= 8'h0;
            status_byte <= 8'h0;
            data1_byte  <= 8'h0;
        end else begin
            msg_valid <= 1'b0;

            if (byte_valid) begin
                if (byte_out[7]) begin
                    // Status byte — reset parser regardless of current state.
                    // Ignore System Exclusive (0xF0) and real-time (0xF8+).
                    if (byte_out < 8'hF0) begin
                        status_byte <= byte_out;
                        msg_state   <= MSG_DATA1;
                    end
                end else begin
                    // Data byte.
                    case (msg_state)
                        MSG_STATUS: begin
                            // Running status: treat as data1 with last status.
                            data1_byte <= byte_out;
                            msg_state  <= MSG_DATA2;
                        end
                        MSG_DATA1: begin
                            data1_byte <= byte_out;
                            msg_state  <= MSG_DATA2;
                        end
                        MSG_DATA2: begin
                            // Complete message.
                            case (status_byte[7:4])
                                4'h9: begin  // Note On
                                    msg_type  <= 2'b01;
                                    msg_ch    <= status_byte[3:0];
                                    msg_b1    <= data1_byte;   // note
                                    msg_b2    <= byte_out;     // velocity
                                    msg_valid <= (byte_out != 8'h0);  // vel=0 → note off
                                    if (byte_out == 8'h0) begin
                                        msg_type  <= 2'b10;    // Note Off
                                        msg_valid <= 1'b1;
                                    end
                                end
                                4'h8: begin  // Note Off
                                    msg_type  <= 2'b10;
                                    msg_ch    <= status_byte[3:0];
                                    msg_b1    <= data1_byte;
                                    msg_b2    <= byte_out;
                                    msg_valid <= 1'b1;
                                end
                                4'hB: begin  // Control Change
                                    msg_type  <= 2'b11;
                                    msg_ch    <= status_byte[3:0];
                                    msg_b1    <= data1_byte;   // CC number
                                    msg_b2    <= byte_out;     // CC value
                                    msg_valid <= 1'b1;
                                end
                                default: ;
                            endcase
                            msg_state <= MSG_STATUS;  // ready for running status
                        end
                        default: msg_state <= MSG_STATUS;
                    endcase
                end
            end
        end
    end

endmodule
