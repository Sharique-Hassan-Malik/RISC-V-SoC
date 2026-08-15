// cc_store.v — MIDI Control Change parameter register bank.
//
// Receives CC messages from midi_rx and stores them in named registers
// that drive the synthesiser parameters.  All outputs are updated one
// clock after msg_valid with matching msg_type == CC.
//
// CC assignments:
//   CC  1  Modulation wheel — filter cutoff (0 = min, 127 = max)
//   CC  5  Attack  time rate (0 = slowest, 127 = fastest)
//   CC  6  Decay   time rate (0 = slowest, 127 = fastest)
//   CC  7  Volume / sustain level
//   CC  8  Release time rate (0 = slowest, 127 = fastest)
//   CC 71  Filter resonance (Q)
//
// Rate scaling: CC value (0–127) is mapped to a 16-bit rate register.
//   rate = (cc_val + 1) × 512   (range 512–65 024)
//   At 48 kHz: minimum rate 512/65535 × 48000 ≈ 375 ms full-scale sweep.
//              maximum rate 65024/65535 × 48000 ≈ 0.94 ms (nearly instant).
//
// Sustain level: CC value directly as top 7 bits of 16-bit register.
//   sustain = cc_val << 9   (range 0–65 024)
//
// Filter cutoff / resonance: CC values stored as raw 7-bit registers;
// the actual biquad coefficients must be recomputed by a coefficient
// update block (not implemented here — coefficients are provided externally
// via the b0..a2 ports for each design iteration).

module cc_store (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] msg_type,
    input  wire [7:0] msg_b1,    // CC number
    input  wire [7:0] msg_b2,    // CC value
    input  wire       msg_valid,

    output reg  [15:0] attack_rate,
    output reg  [15:0] decay_rate,
    output reg  [15:0] sustain_level,
    output reg  [15:0] release_rate,
    output reg  [6:0]  cc_cutoff,     // raw 0–127 for external coeff calculation
    output reg  [6:0]  cc_resonance
);

    // Default values: piano-like ADSR, open filter.
    initial begin
        attack_rate   = 16'd2048;    // ~16 ms attack
        decay_rate    = 16'd1024;    // ~32 ms decay
        sustain_level = 16'd40960;   // ~63% sustain
        release_rate  = 16'd512;     // ~65 ms release
        cc_cutoff     = 7'd127;      // fully open
        cc_resonance  = 7'd32;       // moderate Q
    end

    // CC value (7-bit) to 16-bit rate conversion.
    function [15:0] cc_to_rate;
        input [6:0] cc_val;
        cc_to_rate = ({9'h0, cc_val} + 16'd1) * 16'd512;
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            attack_rate   <= 16'd2048;
            decay_rate    <= 16'd1024;
            sustain_level <= 16'd40960;
            release_rate  <= 16'd512;
            cc_cutoff     <= 7'd127;
            cc_resonance  <= 7'd32;
        end else if (msg_valid && msg_type == 2'b11) begin
            case (msg_b1[6:0])
                7'd1:  cc_cutoff     <= msg_b2[6:0];
                7'd5:  attack_rate   <= cc_to_rate(msg_b2[6:0]);
                7'd6:  decay_rate    <= cc_to_rate(msg_b2[6:0]);
                7'd7:  sustain_level <= {msg_b2[6:0], 9'h0};
                7'd8:  release_rate  <= cc_to_rate(msg_b2[6:0]);
                7'd71: cc_resonance  <= msg_b2[6:0];
                default: ;
            endcase
        end
    end

endmodule
