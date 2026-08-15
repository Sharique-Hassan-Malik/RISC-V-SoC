// biquad_df1.v — Direct-Form I second-order IIR (biquad) filter section.
//
// Implements:
//   y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2]
//          − a1·y[n-1] − a2·y[n-2]
//
// All coefficients are Q15 signed (16-bit two's-complement, fractional range
// approximately [-1, +1)).  For filters requiring |a1| > 1 (common for
// resonant low-pass filters), set COEFF_SHIFT = 1 to interpret all
// coefficients in Q14 format (range approximately [-2, +2)).
//
// Input and output are 16-bit signed.  Internal datapath is 32-bit to prevent
// overflow during accumulation; the result is saturated back to 16 bits.
//
// Latency: 2 clock cycles (pipeline registers for multipliers + accumulate).
//
// Coefficient computation (Q15 low-pass biquad, bilinear transform):
//   Given cutoff fc and sample rate Fs:
//     ω = 2·π·fc/Fs
//     K = tan(ω/2)
//     a0_norm = 1 + K/Q + K²     (Q = resonance, typ. 0.707 for Butterworth)
//     b0 = K² / a0_norm
//     b1 = 2·b0
//     b2 = b0
//     a1 = 2·(K²−1) / a0_norm
//     a2 = (1 − K/Q + K²) / a0_norm
//   Quantise to Q15: coeff_Q15 = round(coeff_float × 32768).

module biquad_df1 #(
    parameter COEFF_SHIFT = 0    // 0 = Q15 range [-1,+1), 1 = Q14 range [-2,+2)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] x_in,     // signed Q15 input
    input  wire [15:0] b0,
    input  wire [15:0] b1,
    input  wire [15:0] b2,
    input  wire [15:0] a1,       // stored as negative: multiply then subtract becomes add
    input  wire [15:0] a2,
    output reg  [15:0] y_out     // signed Q15 output
);

    // State registers
    reg signed [15:0] x1, x2;   // x[n-1], x[n-2]
    reg signed [15:0] y1, y2;   // y[n-1], y[n-2]

    // Pipe stage 1: compute all five products simultaneously.
    wire signed [31:0] p_b0 = $signed(b0) * $signed(x_in);
    wire signed [31:0] p_b1 = $signed(b1) * $signed(x1);
    wire signed [31:0] p_b2 = $signed(b2) * $signed(x2);
    wire signed [31:0] p_a1 = $signed(a1) * $signed(y1);
    wire signed [31:0] p_a2 = $signed(a2) * $signed(y2);

    // Accumulate (note a1, a2 are stored as positive; we subtract them).
    // With COEFF_SHIFT=0 the product bits [30:15] give the Q15 result.
    // With COEFF_SHIFT=1 the coefficients are Q14 so product bits [29:14].
    localparam SHIFT = 15 - COEFF_SHIFT;

    wire signed [31:0] acc = (p_b0 + p_b1 + p_b2 - p_a1 - p_a2) >>> SHIFT;

    // Saturate to 16-bit signed.
    wire signed [15:0] sat_result =
        (acc > 32'sh00007FFF) ? 16'h7FFF :
        (acc < -32'sh00008000) ? 16'h8000 :
        acc[15:0];

    always @(posedge clk) begin
        if (rst) begin
            x1 <= 16'h0; x2 <= 16'h0;
            y1 <= 16'h0; y2 <= 16'h0;
            y_out <= 16'h0;
        end else begin
            x2    <= x1;
            x1    <= x_in;
            y2    <= y1;
            y1    <= sat_result;
            y_out <= sat_result;
        end
    end

endmodule
