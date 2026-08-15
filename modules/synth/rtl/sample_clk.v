// sample_clk.v — Master-clock to audio sample-rate clock divider.
//
// Produces a single-cycle pulse `sample_tick` at the audio sample rate.
// At CLK_HZ = 12 MHz and SAMPLE_RATE = 48 000 Hz:
//   DIV = 12 000 000 / 48 000 = 250
//
// All DSP blocks (DDS, ADSR, filter, mixer) use the master clock and
// gate their state updates on `sample_tick`.  Only the PWM output uses
// a faster derived clock.

module sample_clk #(
    parameter CLK_HZ     = 12000000,
    parameter SAMPLE_RATE = 48000
) (
    input  wire clk,
    input  wire rst,
    output reg  sample_tick
);

    localparam integer DIV = CLK_HZ / SAMPLE_RATE;

    reg [$clog2(DIV)-1:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt         <= 0;
            sample_tick <= 1'b0;
        end else begin
            if (cnt == DIV - 1) begin
                cnt         <= 0;
                sample_tick <= 1'b1;
            end else begin
                cnt         <= cnt + 1;
                sample_tick <= 1'b0;
            end
        end
    end

endmodule
