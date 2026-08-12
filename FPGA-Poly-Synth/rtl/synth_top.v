// synth_top.v — 4-voice polyphonic FM synthesiser top level.
//
// Target: Lattice iCEstick (iCE40HX1K-TQ144)
// Master clock: 12 MHz (on-board oscillator, pin 21 = clk)
// Audio output: PDM on pin 78 (J2-3) → 4.7 kΩ + 10 nF RC → audio out
// MIDI input:   pin 44 (J1-3) — optocoupler output (6N138 or PC-900)
//
// Block diagram:
//
//  midi_rx ──► voice_alloc ──► 4× {note_to_phase, dds_osc, adsr_env, q15_mul}
//                                            │
//              cc_store ──►  biquad_df1  ◄──┘ voice_mixer
//                                            │
//                                        pwm_dac ──► PDM output
//
// All DSP blocks share the 12 MHz master clock and gate on sample_tick (48 kHz).
//
// Filter:
//   A single biquad low-pass filter is applied to the mixed output.
//   Coefficients are hardwired for a 2 kHz cutoff with Q = 0.707 at 48 kHz
//   (computed by gen_hex.py).  CC 1 modulation of the cutoff is not yet
//   implemented in hardware coefficient update logic — extend biquad_coeff.v
//   for a full real-time morphing filter.

`default_nettype none

module synth_top (
    input  wire clk,         // 12 MHz iCEstick oscillator
    input  wire midi_rx_pin, // MIDI DIN-5 optocoupler output
    output wire pdm_out_pin, // sigma-delta audio output
    output wire led0,        // activity LED
    output wire led1,        // voice-active indicator
    output wire led2,
    output wire led3,
    output wire led4
);

    localparam VOICES      = 4;
    localparam CLK_HZ      = 12_000_000;
    localparam SAMPLE_RATE = 48_000;

    // ---- Reset generator (4 clock cycles) --------------------------------
    reg [3:0] rst_sr = 4'hF;
    wire rst = rst_sr[3];
    always @(posedge clk) rst_sr <= {rst_sr[2:0], 1'b0};

    // ---- Sample-rate tick ------------------------------------------------
    wire sample_tick;
    sample_clk #(.CLK_HZ(CLK_HZ), .SAMPLE_RATE(SAMPLE_RATE)) u_sclk (
        .clk(clk), .rst(rst), .sample_tick(sample_tick)
    );

    // ---- MIDI receiver ---------------------------------------------------
    wire [1:0] msg_type;
    wire [3:0] msg_ch;
    wire [7:0] msg_b1, msg_b2;
    wire       msg_valid;

    midi_rx #(.CLK_HZ(CLK_HZ)) u_midi (
        .clk(clk), .rst(rst), .rx(midi_rx_pin),
        .msg_type(msg_type), .msg_ch(msg_ch),
        .msg_b1(msg_b1), .msg_b2(msg_b2),
        .msg_valid(msg_valid)
    );

    // ---- CC parameter store ----------------------------------------------
    wire [15:0] attack_rate, decay_rate, sustain_level, release_rate;
    wire [6:0]  cc_cutoff, cc_resonance;

    cc_store u_cc (
        .clk(clk), .rst(rst),
        .msg_type(msg_type), .msg_b1(msg_b1), .msg_b2(msg_b2),
        .msg_valid(msg_valid),
        .attack_rate(attack_rate), .decay_rate(decay_rate),
        .sustain_level(sustain_level), .release_rate(release_rate),
        .cc_cutoff(cc_cutoff), .cc_resonance(cc_resonance)
    );

    // ---- Voice allocator -------------------------------------------------
    wire [VOICES-1:0]   voice_gate;
    wire [VOICES*8-1:0] voice_note;
    wire [VOICES*8-1:0] voice_vel;

    voice_alloc #(.VOICES(VOICES)) u_valloc (
        .clk(clk), .rst(rst),
        .msg_type(msg_type), .msg_b1(msg_b1), .msg_b2(msg_b2),
        .msg_valid(msg_valid),
        .voice_gate(voice_gate),
        .voice_note(voice_note),
        .voice_vel(voice_vel)
    );

    // ---- Per-voice oscillator + envelope + scale -------------------------
    wire [VOICES*16-1:0] voice_samples;

    genvar v;
    generate
        for (v = 0; v < VOICES; v = v+1) begin : voice_inst

            // Note-to-phase-increment ROM lookup.
            wire [31:0] phase_inc;
            note_to_phase u_n2p (
                .clk(clk),
                .note(voice_note[v*8 +: 7]),
                .phase_inc(phase_inc)
            );

            // DDS oscillator (runs every sample_tick implicitly by gating).
            // For area efficiency: run osc every master clock tick;
            // phase accumulator and ROM are registered so output is stable.
            wire [15:0] osc_raw;
            dds_osc u_osc (
                .clk(clk), .rst(rst),
                .phase_inc(phase_inc),
                .en(sample_tick & voice_gate[v]),
                .sample_out(osc_raw)
            );

            // ADSR envelope.
            wire [15:0] env_amp;
            wire        env_idle;
            adsr_env u_adsr (
                .clk(clk), .rst(rst),
                .gate(voice_gate[v]),
                .attack_rate(attack_rate),
                .decay_rate(decay_rate),
                .sustain_level(sustain_level),
                .release_rate(release_rate),
                .env_out(env_amp),
                .idle(env_idle)
            );

            // Scale oscillator by envelope (Q15 × Q16 → Q15).
            wire [15:0] voice_scaled;
            q15_mul u_mul (
                .clk(clk),
                .a_signed(osc_raw),
                .b_unsigned(env_amp),
                .result(voice_scaled)
            );

            assign voice_samples[v*16 +: 16] = voice_scaled;

        end
    endgenerate

    // ---- Voice mixer -----------------------------------------------------
    wire [15:0] mix_raw;
    voice_mixer #(.VOICES(VOICES)) u_mixer (
        .samples_in(voice_samples),
        .mix_out(mix_raw)
    );

    // ---- Biquad low-pass filter ------------------------------------------
    // Hardwired coefficients for fc = 2 kHz, Q = 0.707 at Fs = 48 kHz.
    // Generated by gen_hex.py (see tools section).
    // b0 = 0x0264, b1 = 0x04C8, b2 = 0x0264
    // a1 = 0xD99E (represents −0.6157… stored as two's complement)
    // a2 = 0x1AEB
    wire [15:0] filt_out;
    biquad_df1 u_filt (
        .clk(clk), .rst(rst),
        .x_in(mix_raw),
        .b0(16'h0264), .b1(16'h04C8), .b2(16'h0264),
        .a1(16'h2662), .a2(16'h1AEB),
        .y_out(filt_out)
    );

    // ---- Sigma-delta DAC -------------------------------------------------
    pwm_dac u_dac (
        .clk(clk), .rst(rst),
        .sample(filt_out),
        .pdm_out(pdm_out_pin)
    );

    // ---- Status LEDs (active-low on iCEstick) ----------------------------
    // LED0: MIDI activity (pulses on each valid message)
    reg [23:0] midi_blink;
    always @(posedge clk)
        if (msg_valid) midi_blink <= 24'hFFFFFF;
        else if (|midi_blink) midi_blink <= midi_blink - 1;

    assign led0 = ~midi_blink[23];
    assign led1 = ~voice_gate[0];
    assign led2 = ~voice_gate[1];
    assign led3 = ~voice_gate[2];
    assign led4 = ~voice_gate[3];

endmodule

`default_nettype wire
