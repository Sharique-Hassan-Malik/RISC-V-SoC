// digit_rom.v — 4×7 pixel bitmap font for digits 0–9.
//
// Each digit is 4 pixels wide × 7 pixels tall.
// The ROM returns a single pixel value (1 = on, 0 = off) for a given
// digit and pixel position within its 4×7 bounding box.
//
// col : 0 = leftmost, 3 = rightmost
// row : 0 = topmost,  6 = bottommost
//
// All 10 digit bitmaps are encoded as 28-bit constants (4×7 = 28 bits).
// Bit layout: bit 27 = (row 0, col 0), bit 26 = (row 0, col 1), ...
// i.e., bit index = (6 - row) * 4 + (3 - col)   [rows MSB-first, cols MSB-first]

module digit_rom (
    input  wire [3:0] digit,    // 0–9
    input  wire [1:0] col,      // 0–3
    input  wire [2:0] row,      // 0–6
    output wire       pixel
);

    // 28-bit bitmap constants, each row is 4 bits, MSB = col 0
    // Encoding: row0[3:0], row1[3:0], ..., row6[3:0]  packed into 28 bits
    // bit index = (6 - row) * 4 + (3 - col)
    localparam [27:0] DIGIT_0 = 28'b0110_1001_1001_1001_1001_1001_0110;
    localparam [27:0] DIGIT_1 = 28'b0010_0110_0010_0010_0010_0010_0111;
    localparam [27:0] DIGIT_2 = 28'b0110_1001_0001_0010_0100_1000_1111;
    localparam [27:0] DIGIT_3 = 28'b1110_0001_0001_0110_0001_0001_1110;
    localparam [27:0] DIGIT_4 = 28'b0001_0011_0101_1001_1111_0001_0001;
    localparam [27:0] DIGIT_5 = 28'b1111_1000_1000_1110_0001_0001_1110;
    localparam [27:0] DIGIT_6 = 28'b0110_1000_1000_1110_1001_1001_0110;
    localparam [27:0] DIGIT_7 = 28'b1111_0001_0001_0010_0100_0100_0100;
    localparam [27:0] DIGIT_8 = 28'b0110_1001_1001_0110_1001_1001_0110;
    localparam [27:0] DIGIT_9 = 28'b0110_1001_1001_0111_0001_0001_0110;

    reg [27:0] bitmap;

    always @(*) begin
        case (digit)
            4'd0: bitmap = DIGIT_0;
            4'd1: bitmap = DIGIT_1;
            4'd2: bitmap = DIGIT_2;
            4'd3: bitmap = DIGIT_3;
            4'd4: bitmap = DIGIT_4;
            4'd5: bitmap = DIGIT_5;
            4'd6: bitmap = DIGIT_6;
            4'd7: bitmap = DIGIT_7;
            4'd8: bitmap = DIGIT_8;
            4'd9: bitmap = DIGIT_9;
            default: bitmap = 28'b0;
        endcase
    end

    // Extract pixel: bit = (6 - row) * 4 + (3 - col)
    wire [4:0] bit_idx = (4'd6 - {2'b0, row}) * 4 + (3'd3 - {1'b0, col});
    assign pixel = bitmap[bit_idx];

endmodule
