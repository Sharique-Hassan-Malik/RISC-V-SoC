// q15_mul.v — Signed Q15 × Unsigned Q16 multiplier.
//
// Computes (a_signed × b_unsigned) >> 16, returning a signed 16-bit result.
// Used to scale a Q15 oscillator sample by a Q16 envelope amplitude:
//
//   a_signed  : 16-bit two's-complement sine sample  [-32767, +32767]
//   b_unsigned: 16-bit envelope amplitude             [    0,  65535]
//   result    : 16-bit signed scaled sample           [-32767, +32767]
//
// The 32-bit intermediate product is sign-extended from the signed operand
// and truncated by right-shifting 16 bits (arithmetic shift).  This maps
// cleanly onto one DSP48/SB_MAC16 primitive in synthesis.
//
// Latency: 1 clock cycle (registered output).

module q15_mul (
    input  wire        clk,
    input  wire [15:0] a_signed,
    input  wire [15:0] b_unsigned,
    output reg  [15:0] result
);

    wire signed [15:0] a_s  = $signed(a_signed);
    wire        [15:0] b_u  = b_unsigned;

    // Sign-extend a to 32 bits, zero-extend b, multiply.
    wire signed [31:0] product = $signed({{16{a_s[15]}}, a_s})
                               * $signed({1'b0, b_u});

    always @(posedge clk)
        result <= product[31:16];

endmodule
