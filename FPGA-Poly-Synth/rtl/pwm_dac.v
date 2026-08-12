// pwm_dac.v — First-order sigma-delta modulator for 1-bit audio output.
//
// Converts a 16-bit signed audio sample to a 1-bit pulse-density modulated
// (PDM) stream suitable for driving a simple RC low-pass filter as a DAC.
//
// The sigma-delta loop runs at CLK_HZ (12 MHz), which is 250× faster than
// the 48 kHz sample rate, giving an oversampling ratio of 250.  The
// effective dynamic range is approximately 6 × log2(250) + 1.76 ≈ 50 dB,
// which is sufficient for a proof-of-concept audio output.
//
// For a proper audio output add an SPI I2S DAC (e.g. PCM5102) and replace
// this module with an I2S transmitter.
//
// The input `sample` is updated by the top-level design on each sample_tick.
// This module runs freely on the master clock and simply re-reads `sample`
// at its own clock rate — no handshake required.
//
// RC filter recommendation: 4.7 kΩ + 10 nF = 3.4 kHz cutoff (iCEstick GPIO).
// Add an op-amp unity-gain buffer and a 20 kHz active filter for better audio.

module pwm_dac (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] sample,    // signed Q15
    output reg         pdm_out
);

    // Convert signed to unsigned for the accumulator.
    wire [15:0] sample_u = {~sample[15], sample[14:0]};  // offset binary

    reg [16:0] accum;   // 17-bit accumulator (16-bit signal + 1-bit carry)

    always @(posedge clk) begin
        if (rst) begin
            accum   <= 17'h0;
            pdm_out <= 1'b0;
        end else begin
            accum   <= {1'b0, accum[15:0]} + {1'b0, sample_u};
            pdm_out <= accum[16];   // carry out = PDM output bit
        end
    end

endmodule
