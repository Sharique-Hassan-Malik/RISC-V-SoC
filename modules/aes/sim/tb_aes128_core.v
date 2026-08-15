// Testbench: aes128_core
// Self-checking against FIPS 197 Appendix B and C.1 test vectors.
// Pass criterion: all expected ciphertexts match; $finish with exit 0.

`timescale 1ns/1ps

module tb_aes128_core;

    reg         clk, rst_n;
    reg         load_key, valid_i;
    reg  [127:0] key_i, plaintext_i;
    wire        valid_o;
    wire [127:0] ciphertext_o;

    aes128_core dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .load_key    (load_key),
        .key_i       (key_i),
        .valid_i     (valid_i),
        .plaintext_i (plaintext_i),
        .valid_o     (valid_o),
        .ciphertext_o(ciphertext_o)
    );

    integer fail_count;
    integer i;

    // Test vector storage
    reg [127:0] tv_key   [0:3];
    reg [127:0] tv_plain [0:3];
    reg [127:0] tv_ctxt  [0:3];
    reg [127:0] tv_expected [0:3];
    integer     tv_count;

    // Clock: 10 ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Capture outputs (pipeline produces one result per cycle once full)
    integer  recv_idx;
    initial  recv_idx = 0;
    always @(posedge clk) begin
        if (valid_o) begin
            tv_ctxt[recv_idx] = ciphertext_o;
            recv_idx = recv_idx + 1;
        end
    end

    // Each vector uses its own key. The core shares one round-key register
    // across all pipeline stages, so a key must be loaded and allowed to
    // settle *before* its block enters the pipeline, and the block must drain
    // fully before the next key is loaded. (For a fixed key, blocks can instead
    // be streamed back-to-back at one per cycle — see the AXI testbench.)
    task run_vector;
        input [127:0] key;
        input [127:0] plain;
        begin
            // 1) Load the round-key schedule; let it register (valid_i low).
            @(posedge clk); #1;
            key_i    = key;
            load_key = 1'b1;
            valid_i  = 1'b0;
            @(posedge clk); #1;
            load_key = 1'b0;
            // 2) Feed one plaintext block now that the key is stable.
            plaintext_i = plain;
            valid_i     = 1'b1;
            @(posedge clk); #1;
            valid_i     = 1'b0;
            // 3) Drain the 11-stage pipeline before the next vector.
            repeat (13) @(posedge clk);
        end
    endtask

    initial begin
        fail_count = 0;
        load_key   = 0;
        valid_i    = 0;
        key_i      = 0;
        plaintext_i= 0;
        rst_n      = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ── FIPS 197 Appendix B ─────────────────────────────────────────────
        tv_key[0]      = 128'h2b7e151628aed2a6abf7158809cf4f3c;
        tv_plain[0]    = 128'h3243f6a8885a308d313198a2e0370734;
        tv_expected[0] = 128'h3925841d02dc09fbdc118597196a0b32;

        // ── C.1 key / plaintext (OpenSSL verified) ──────────────────────────
        tv_key[1]      = 128'h000102030405060708090a0b0c0d0e0f;
        tv_plain[1]    = 128'h00112233445566778899aabbccddeeff;
        tv_expected[1] = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

        // ── All-zero vector ─────────────────────────────────────────────────
        tv_key[2]      = 128'h00000000000000000000000000000000;
        tv_plain[2]    = 128'h00000000000000000000000000000000;
        tv_expected[2] = 128'h66e94bd4ef8a2c3b884cfa59ca342b2e;

        // ── NIST SP 800-38A F.1.1 (ECB-AES128) ─────────────────────────────
        tv_key[3]      = 128'h2b7e151628aed2a6abf7158809cf4f3c;
        tv_plain[3]    = 128'h6bc1bee22e409f96e93d7e117393172a;
        tv_expected[3] = 128'h3ad77bb40d7a3660a89ecaf32466ef97;

        tv_count = 4;
        recv_idx = 0;

        // Run each vector: load its key, feed its block, drain the pipeline.
        for (i = 0; i < tv_count; i = i + 1) begin
            run_vector(tv_key[i], tv_plain[i]);
        end

        repeat (2) @(posedge clk);

        // ── Verify ──────────────────────────────────────────────────────────
        for (i = 0; i < tv_count; i = i + 1) begin
            if (tv_ctxt[i] !== tv_expected[i]) begin
                $display("FAIL  vec[%0d]: got %h  expected %h", i, tv_ctxt[i], tv_expected[i]);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS  vec[%0d]: %h", i, tv_ctxt[i]);
            end
        end

        if (fail_count == 0)
            $display("\nAll %0d vectors PASSED.", tv_count);
        else
            $display("\n%0d vector(s) FAILED.", fail_count);

        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
