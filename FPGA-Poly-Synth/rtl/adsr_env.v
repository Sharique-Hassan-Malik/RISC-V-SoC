// adsr_env.v — ADSR amplitude envelope generator.
//
// Generates a 16-bit unsigned envelope amplitude in [0, 65535].
// Transitions are driven by the sample clock; rates are expressed as
// per-sample increments/decrements so the host sets them from millisecond
// durations:
//
//   attack_rate  = 65535 / (attack_ms  × Fs / 1000)
//   decay_rate   = (65535 − sustain_level) / (decay_ms × Fs / 1000)
//   release_rate = sustain_level / (release_ms × Fs / 1000)
//
// All rate inputs are 16-bit unsigned.  A rate of 1 gives the slowest
// possible transition; a rate of 65535 gives an instant step.
//
// gate: 1 = note held (triggers attack/decay/sustain),
//        0 = note released (triggers release).
// idle: 1 when envelope has fully decayed after release.

module adsr_env (
    input  wire        clk,
    input  wire        rst,
    input  wire        gate,
    input  wire [15:0] attack_rate,
    input  wire [15:0] decay_rate,
    input  wire [15:0] sustain_level,
    input  wire [15:0] release_rate,
    output reg  [15:0] env_out,
    output wire        idle
);

    // State encoding
    localparam S_IDLE    = 3'd0;
    localparam S_ATTACK  = 3'd1;
    localparam S_DECAY   = 3'd2;
    localparam S_SUSTAIN = 3'd3;
    localparam S_RELEASE = 3'd4;

    reg [2:0] state;
    reg       gate_prev;

    assign idle = (state == S_IDLE);

    // 17-bit accumulator to detect overflow/underflow cleanly.
    wire [16:0] amp_next_attack  = {1'b0, env_out} + {1'b0, attack_rate};
    wire [16:0] amp_next_decay   = {1'b0, env_out} - {1'b0, decay_rate};
    wire [16:0] amp_next_release = {1'b0, env_out} - {1'b0, release_rate};

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            env_out   <= 16'h0;
            gate_prev <= 1'b0;
        end else begin
            gate_prev <= gate;

            case (state)

                S_IDLE: begin
                    env_out <= 16'h0;
                    // Rising gate edge → begin attack.
                    if (gate && !gate_prev) begin
                        state   <= S_ATTACK;
                        env_out <= 16'h0;
                    end
                end

                S_ATTACK: begin
                    if (!gate) begin
                        state <= S_RELEASE;
                    end else if (amp_next_attack[16] || amp_next_attack[15:0] >= 16'hFFFF) begin
                        // Overflow: peak reached.
                        env_out <= 16'hFFFF;
                        state   <= S_DECAY;
                    end else begin
                        env_out <= amp_next_attack[15:0];
                    end
                end

                S_DECAY: begin
                    if (!gate) begin
                        state <= S_RELEASE;
                    end else if (amp_next_decay[16] ||
                                 amp_next_decay[15:0] <= sustain_level) begin
                        // Underflow or crossed sustain level.
                        env_out <= sustain_level;
                        state   <= S_SUSTAIN;
                    end else begin
                        env_out <= amp_next_decay[15:0];
                    end
                end

                S_SUSTAIN: begin
                    env_out <= sustain_level;
                    if (!gate)
                        state <= S_RELEASE;
                end

                S_RELEASE: begin
                    if (gate && !gate_prev) begin
                        // New note while releasing — restart attack.
                        state   <= S_ATTACK;
                        env_out <= 16'h0;
                    end else if (amp_next_release[16] ||
                                 amp_next_release[15:0] == 16'h0) begin
                        env_out <= 16'h0;
                        state   <= S_IDLE;
                    end else begin
                        env_out <= amp_next_release[15:0];
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
