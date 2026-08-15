// AES-128 Pipelined Core
//
// Pipeline depth: 11 stages (1 initial AddRoundKey + 9 full rounds + 1 final round).
// Latency:        11 clock cycles from valid_i to valid_o.
// Throughput:     1 block per clock cycle once pipeline is full.
//
// The key schedule is combinational — round keys are registered on load_key
// so that new blocks can be encrypted on every subsequent cycle.

module aes128_core (
    input  wire         clk,
    input  wire         rst_n,

    // Key interface — assert load_key for one cycle with valid key_i.
    // After 1 cycle the round keys are latched and the core is ready.
    input  wire         load_key,
    input  wire [127:0] key_i,

    // Data interface
    input  wire         valid_i,
    input  wire [127:0] plaintext_i,

    output reg          valid_o,
    output reg  [127:0] ciphertext_o
);
    // ── Round key storage ────────────────────────────────────────────────────
    wire [1407:0] rk_comb;
    aes_key_expand u_kexp (.key(key_i), .round_keys(rk_comb));

    reg [127:0] rk [0:10];
    integer k;
    always @(posedge clk) begin
        if (load_key) begin
            for (k = 0; k <= 10; k = k + 1)
                rk[k] <= rk_comb[1407 - k*128 -: 128];
        end
    end

    // ── Pipeline registers ───────────────────────────────────────────────────
    reg [127:0] pipe_state [0:10];
    reg [10:0]  pipe_valid;         // shift register for valid propagation

    // Stage 0: initial AddRoundKey
    wire [127:0] s0 = plaintext_i ^ rk[0];

    // Stages 1–9: full rounds
    wire [127:0] r_out [1:9];
    aes_round u_r1 (.state_in(pipe_state[0]), .round_key(rk[1]), .state_out(r_out[1]));
    aes_round u_r2 (.state_in(pipe_state[1]), .round_key(rk[2]), .state_out(r_out[2]));
    aes_round u_r3 (.state_in(pipe_state[2]), .round_key(rk[3]), .state_out(r_out[3]));
    aes_round u_r4 (.state_in(pipe_state[3]), .round_key(rk[4]), .state_out(r_out[4]));
    aes_round u_r5 (.state_in(pipe_state[4]), .round_key(rk[5]), .state_out(r_out[5]));
    aes_round u_r6 (.state_in(pipe_state[5]), .round_key(rk[6]), .state_out(r_out[6]));
    aes_round u_r7 (.state_in(pipe_state[6]), .round_key(rk[7]), .state_out(r_out[7]));
    aes_round u_r8 (.state_in(pipe_state[7]), .round_key(rk[8]), .state_out(r_out[8]));
    aes_round u_r9 (.state_in(pipe_state[8]), .round_key(rk[9]), .state_out(r_out[9]));

    // Stage 10: final round
    wire [127:0] r_out10;
    aes_final_round u_rf (.state_in(pipe_state[9]), .round_key(rk[10]), .state_out(r_out10));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid    <= 11'b0;
            valid_o       <= 1'b0;
            ciphertext_o  <= 128'b0;
        end else begin
            // Stage 0 register
            pipe_state[0] <= s0;
            pipe_valid[0] <= valid_i;

            // Stages 1–9
            pipe_state[1] <= r_out[1]; pipe_valid[1] <= pipe_valid[0];
            pipe_state[2] <= r_out[2]; pipe_valid[2] <= pipe_valid[1];
            pipe_state[3] <= r_out[3]; pipe_valid[3] <= pipe_valid[2];
            pipe_state[4] <= r_out[4]; pipe_valid[4] <= pipe_valid[3];
            pipe_state[5] <= r_out[5]; pipe_valid[5] <= pipe_valid[4];
            pipe_state[6] <= r_out[6]; pipe_valid[6] <= pipe_valid[5];
            pipe_state[7] <= r_out[7]; pipe_valid[7] <= pipe_valid[6];
            pipe_state[8] <= r_out[8]; pipe_valid[8] <= pipe_valid[7];
            pipe_state[9] <= r_out[9]; pipe_valid[9] <= pipe_valid[8];

            // Stage 10 output
            pipe_valid[10] <= pipe_valid[9];
            valid_o        <= pipe_valid[10];
            ciphertext_o   <= r_out10;
        end
    end

endmodule
