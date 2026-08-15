// MixColumns — one 32-bit column in GF(2^8)
// Irreducible polynomial: x^8 + x^4 + x^3 + x + 1  (0x11B)
//
// MDS matrix multiplication:
//   [2 3 1 1]   [b0]
//   [1 2 3 1] * [b1]
//   [1 1 2 3]   [b2]
//   [3 1 1 2]   [b3]
//
// Efficient form using the identity:
//   out_i = b_i ^ t ^ xtime(b_i ^ b_{i+1})   where t = b0^b1^b2^b3

module aes_mixcol (
    input  [31:0] in,
    output [31:0] out
);
    wire [7:0] b0 = in[31:24];
    wire [7:0] b1 = in[23:16];
    wire [7:0] b2 = in[15:8];
    wire [7:0] b3 = in[7:0];

    // Pairwise XORs — named so they can be part-selected below. A part-select
    // of an expression like (b0^b1)[6:0] is not legal Verilog, so bind first.
    wire [7:0] d01 = b0 ^ b1;
    wire [7:0] d12 = b1 ^ b2;
    wire [7:0] d23 = b2 ^ b3;
    wire [7:0] d30 = b3 ^ b0;

    // xtime: multiply by 2 in GF(2^8)
    wire [7:0] xt01 = {d01[6:0], 1'b0} ^ (d01[7] ? 8'h1b : 8'h00);
    wire [7:0] xt12 = {d12[6:0], 1'b0} ^ (d12[7] ? 8'h1b : 8'h00);
    wire [7:0] xt23 = {d23[6:0], 1'b0} ^ (d23[7] ? 8'h1b : 8'h00);
    wire [7:0] xt30 = {d30[6:0], 1'b0} ^ (d30[7] ? 8'h1b : 8'h00);

    wire [7:0] t = b0 ^ b1 ^ b2 ^ b3;

    assign out[31:24] = b0 ^ t ^ xt01;
    assign out[23:16] = b1 ^ t ^ xt12;
    assign out[15:8]  = b2 ^ t ^ xt23;
    assign out[7:0]   = b3 ^ t ^ xt30;

endmodule
