// voice_mixer.v — 4-voice signed sample mixer with headroom guard.
//
// Adds VOICES 16-bit signed samples and right-shifts by SHIFT bits to
// prevent overflow.  Default SHIFT = 2 for 4 voices (−6 dB headroom).
// The output is saturated to 16-bit signed range.
//
// This module is purely combinational (no registers) so it can be
// placed in the sample_tick update path without adding latency.

module voice_mixer #(
    parameter VOICES = 4,
    parameter SHIFT  = 2        // log2(VOICES) to prevent overflow
) (
    input  wire [VOICES*16-1:0] samples_in,  // packed: sample[v] = samples_in[v*16+:16]
    output reg  [15:0]           mix_out
);

    localparam ACCUM_W = 16 + VOICES;   // enough bits to sum VOICES samples

    reg signed [ACCUM_W-1:0] accum;
    integer v;

    always @(*) begin
        accum = {ACCUM_W{1'b0}};
        for (v = 0; v < VOICES; v = v+1)
            accum = accum + {{(ACCUM_W-16){samples_in[v*16+15]}},
                              samples_in[v*16 +: 16]};

        // Arithmetic right shift by SHIFT.
        accum = accum >>> SHIFT;

        // Saturate to 16-bit signed.
        if (accum > {{(ACCUM_W-15){1'b0}}, 15'h7FFF})
            mix_out = 16'h7FFF;
        else if (accum < {{(ACCUM_W-16){1'b1}}, 16'h8000})
            mix_out = 16'h8000;
        else
            mix_out = accum[15:0];
    end

endmodule
