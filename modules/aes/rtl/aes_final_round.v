// AES final round — round 10.
// SubBytes → ShiftRows → AddRoundKey  (MixColumns omitted per FIPS 197).

module aes_final_round (
    input  [127:0] state_in,
    input  [127:0] round_key,
    output [127:0] state_out
);
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

    wire [127:0] after_shift;
    // Row 0: no shift
    assign after_shift[127:120] = after_sub[127:120];
    assign after_shift[95:88]   = after_sub[95:88];
    assign after_shift[63:56]   = after_sub[63:56];
    assign after_shift[31:24]   = after_sub[31:24];
    // Row 1: shift left 1
    assign after_shift[119:112] = after_sub[87:80];
    assign after_shift[87:80]   = after_sub[55:48];
    assign after_shift[55:48]   = after_sub[23:16];
    assign after_shift[23:16]   = after_sub[119:112];
    // Row 2: shift left 2
    assign after_shift[111:104] = after_sub[47:40];
    assign after_shift[79:72]   = after_sub[15:8];
    assign after_shift[47:40]   = after_sub[111:104];
    assign after_shift[15:8]    = after_sub[79:72];
    // Row 3: shift left 3
    assign after_shift[103:96]  = after_sub[7:0];
    assign after_shift[71:64]   = after_sub[103:96];
    assign after_shift[39:32]   = after_sub[71:64];
    assign after_shift[7:0]     = after_sub[39:32];

    assign state_out = after_shift ^ round_key;

endmodule
