// dds_osc.v — Direct Digital Synthesis oscillator voice.
//
// One instance per polyphonic voice.  Advances a 32-bit phase accumulator
// by `phase_inc` every sample clock and outputs a 16-bit signed sine sample
// read from a 1024-point ROM.
//
// Parameters:
//   WAVE_BITS  Width of the wavetable address (default 10 → 1024 entries).
//   SAMPLE_BITS Width of the output sample word (default 16).
//
// Ports:
//   clk        Sample-rate clock (one rising edge = one audio sample).
//   rst        Synchronous reset.
//   phase_inc  32-bit phase increment.  Frequency = phase_inc × Fs / 2^32.
//              At Fs = 48 kHz: phase_inc for 440 Hz = round(440/48000 × 2^32)
//              = 39 321 600 (0x2580000).
//   en         Voice enable.  When low the accumulator freezes and output = 0.
//   sample_out 16-bit signed sine output in range [-32767, +32767].

module dds_osc #(
    parameter WAVE_BITS   = 10,
    parameter SAMPLE_BITS = 16
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire [31:0]             phase_inc,
    input  wire                    en,
    output reg  [SAMPLE_BITS-1:0]  sample_out
);

    // ---- Phase accumulator ------------------------------------------------
    reg [31:0] phase;

    always @(posedge clk) begin
        if (rst)
            phase <= 32'h0;
        else if (en)
            phase <= phase + phase_inc;
    end

    // ---- Wavetable address — top WAVE_BITS bits of the accumulator --------
    wire [WAVE_BITS-1:0] addr = phase[31:32-WAVE_BITS];

    // ---- 1024-point Q15 sine ROM ------------------------------------------
    // Synthesised as a synchronous ROM (single-port block RAM on iCE40).
    // Initialised by $readmemh from sine1024_q15.hex.
    // Each word is a 16-bit two's-complement signed integer representing
    // sin(2π × i / 1024) scaled to [-32767, +32767].
    reg [SAMPLE_BITS-1:0] sine_rom [0:(1<<WAVE_BITS)-1];

    initial begin
        $readmemh("sine1024_q15.hex", sine_rom);
    end

    always @(posedge clk) begin
        if (rst)
            sample_out <= {SAMPLE_BITS{1'b0}};
        else if (en)
            sample_out <= sine_rom[addr];
        else
            sample_out <= {SAMPLE_BITS{1'b0}};
    end

endmodule
