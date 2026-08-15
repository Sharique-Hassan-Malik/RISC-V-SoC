// renderer.v — Combinational pixel renderer.
//
// For every pixel position (hpos, vpos) in the visible frame this module
// decides whether to draw a white pixel.  There is no framebuffer; all
// decisions are pure combinational logic.
//
// Drawing layers (later layers override earlier ones):
//   1. Court border — 2-pixel white rectangle around the screen edges
//   2. Centre dashed line — 2 pixels wide, 8-on / 8-off vertical dashes
//   3. Left paddle
//   4. Right paddle
//   5. Ball (8×8 square)
//   6. Score digits — two 4×7 glyphs drawn 2× scaled (8×14) at top centre
//   7. "WIN" flash — full-screen white flash when game_over (blinks at 4 Hz)

`include "game_pkg.vh"

module renderer (
    input  wire        active,
    input  wire [9:0]  hpos,
    input  wire [9:0]  vpos,
    // Game state
    input  wire [9:0]  ball_x,
    input  wire [8:0]  ball_y,
    input  wire [8:0]  pad_l_y,
    input  wire [8:0]  pad_r_y,
    input  wire [3:0]  score_left,
    input  wire [3:0]  score_right,
    input  wire        game_over,
    input  wire        win_flash,    // toggled at ~4 Hz by top level
    // Output
    output wire        pixel_on      // 1 = white, 0 = black
);

    // ---- Layer 1: Court border -------------------------------------------
    wire border_on =
        (hpos < `BORDER) || (hpos >= `SCREEN_W - `BORDER) ||
        (vpos < `BORDER) || (vpos >= `SCREEN_H - `BORDER);

    // ---- Layer 2: Centre dashed line (column 319-320, 8-on/8-off) --------
    wire centre_on =
        (hpos == 9'd319 || hpos == 9'd320) &&
        (vpos[3] == 1'b0);   // bit 3 of vpos toggles every 8 lines

    // ---- Layer 3 & 4: Paddles -------------------------------------------
    wire pad_l_on =
        (hpos >= `PAD_L_X) && (hpos < `PAD_L_X + `PAD_W) &&
        (vpos >= pad_l_y)  && (vpos < pad_l_y + `PAD_H);

    wire pad_r_on =
        (hpos >= `PAD_R_X) && (hpos < `PAD_R_X + `PAD_W) &&
        (vpos >= pad_r_y)  && (vpos < pad_r_y + `PAD_H);

    // ---- Layer 5: Ball (8×8 square) -------------------------------------
    wire ball_on =
        (hpos >= ball_x) && (hpos < ball_x + `BALL_W) &&
        (vpos >= ball_y) && (vpos < ball_y + `BALL_H);

    // ---- Layer 6: Score digits (2× scaled, 8×14 per digit) --------------
    // Each digit occupies a 8-pixel-wide column; 2 pixels of gap between them.
    // Scaled: each font pixel = 2×2 display pixels.
    // digit_col = (hpos - digit_left) / 2, digit_row = (vpos - SCORE_Y) / 2

    // Left score digit
    wire in_score_l  = (hpos >= `SCORE_L_X) && (hpos < `SCORE_L_X + 8) &&
                       (vpos >= `SCORE_Y)   && (vpos < `SCORE_Y + 14);
    wire [1:0] sl_col = (hpos - `SCORE_L_X) >> 1;
    wire [2:0] sl_row = (vpos - `SCORE_Y)   >> 1;
    wire sl_pixel;
    digit_rom u_drom_l (
        .digit(score_left[3:0]), .col(sl_col), .row(sl_row), .pixel(sl_pixel)
    );
    wire score_l_on = in_score_l && sl_pixel;

    // Right score digit
    wire in_score_r  = (hpos >= `SCORE_R_X) && (hpos < `SCORE_R_X + 8) &&
                       (vpos >= `SCORE_Y)   && (vpos < `SCORE_Y + 14);
    wire [1:0] sr_col = (hpos - `SCORE_R_X) >> 1;
    wire [2:0] sr_row = (vpos - `SCORE_Y)   >> 1;
    wire sr_pixel;
    digit_rom u_drom_r (
        .digit(score_right[3:0]), .col(sr_col), .row(sr_row), .pixel(sr_pixel)
    );
    wire score_r_on = in_score_r && sr_pixel;

    // ---- Layer 7: Game-over flash ----------------------------------------
    wire flash_on = game_over && win_flash;

    // ---- Combine all layers ----------------------------------------------
    assign pixel_on = active && (
        border_on  ||
        centre_on  ||
        pad_l_on   ||
        pad_r_on   ||
        ball_on    ||
        score_l_on ||
        score_r_on ||
        flash_on
    );

endmodule
