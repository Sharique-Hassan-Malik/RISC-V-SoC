// AES full round — rounds 1–9.
// SubBytes → ShiftRows → MixColumns → AddRoundKey.
//
// State byte layout (128-bit flat vector):
//   (row, col) at bits [127 - (col*4 + row)*8  -:  8]
//
//   (0,0)[127:120] (1,0)[119:112] (2,0)[111:104] (3,0)[103:96]
//   (0,1)[95:88]   (1,1)[87:80]   (2,1)[79:72]   (3,1)[71:64]
//   (0,2)[63:56]   (1,2)[55:48]   (2,2)[47:40]   (3,2)[39:32]
//   (0,3)[31:24]   (1,3)[23:16]   (2,3)[15:8]    (3,3)[7:0]

module aes_round (
    input  [127:0] state_in,
    input  [127:0] round_key,
    output [127:0] state_out
);
    // SubBytes — 16 parallel S-box lookups
    wire [127:0] after_sub;
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : SBOX
            aes_sbox u_sb (
                .in  (state_in[127 - i*8 -: 8]),
                .out (after_sub[127 - i*8 -: 8])
            );
        end
    endgenerate

    // ShiftRows — pure wiring, row r shifted left by r positions
    wire [127:0] after_shift;
    // Row 0: no shift
    assign after_shift[127:120] = after_sub[127:120]; // (0,0)
    assign after_shift[95:88]   = after_sub[95:88];   // (0,1)
    assign after_shift[63:56]   = after_sub[63:56];   // (0,2)
    assign after_shift[31:24]   = after_sub[31:24];   // (0,3)
    // Row 1: shift left 1 — (1,c) <- old (1, c+1 mod 4)
    assign after_shift[119:112] = after_sub[87:80];   // (1,0) <- (1,1)
    assign after_shift[87:80]   = after_sub[55:48];   // (1,1) <- (1,2)
    assign after_shift[55:48]   = after_sub[23:16];   // (1,2) <- (1,3)
    assign after_shift[23:16]   = after_sub[119:112]; // (1,3) <- (1,0)
    // Row 2: shift left 2
    assign after_shift[111:104] = after_sub[47:40];   // (2,0) <- (2,2)
    assign after_shift[79:72]   = after_sub[15:8];    // (2,1) <- (2,3)
    assign after_shift[47:40]   = after_sub[111:104]; // (2,2) <- (2,0)
    assign after_shift[15:8]    = after_sub[79:72];   // (2,3) <- (2,1)
    // Row 3: shift left 3
    assign after_shift[103:96]  = after_sub[7:0];     // (3,0) <- (3,3)
    assign after_shift[71:64]   = after_sub[103:96];  // (3,1) <- (3,0)
    assign after_shift[39:32]   = after_sub[71:64];   // (3,2) <- (3,1)
    assign after_shift[7:0]     = after_sub[39:32];   // (3,3) <- (3,2)

    // MixColumns — 4 columns, each 32 bits
    wire [127:0] after_mix;
    aes_mixcol u_mc0 (.in(after_shift[127:96]), .out(after_mix[127:96]));
    aes_mixcol u_mc1 (.in(after_shift[95:64]),  .out(after_mix[95:64]));
    aes_mixcol u_mc2 (.in(after_shift[63:32]),  .out(after_mix[63:32]));
    aes_mixcol u_mc3 (.in(after_shift[31:0]),   .out(after_mix[31:0]));

    // AddRoundKey
    assign state_out = after_mix ^ round_key;

endmodule
