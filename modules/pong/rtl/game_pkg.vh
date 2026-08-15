// game_pkg.vh — Pong game geometry and timing constants.
//
// Include this file in every module that needs game parameters.
// All pixel measurements are in VGA pixels (640×480).
//
// Court:
//   A 2-pixel white border runs around the entire screen.
//   A dashed centre line (8-on / 8-off) divides the court.
//
// Ball: 8×8 pixel square.
// Paddles: 8 pixels wide × 64 pixels tall.
//   Left paddle  x = 16
//   Right paddle x = 616  (640 - 16 - 8)
//
// Score digits: rendered in a 4×7 font at the top centre.
//
// Frame rate: 60 Hz (25 MHz / 800 / 525 ≈ 59.5 Hz, counted as 60 Hz).
// Ball speed: encoded as a signed 8.4 fixed-point velocity in pixels/frame
//   so fractional speeds are possible without a divider.
//   Initial speed: dx = ±2.0 px/frame, dy = ±1.0 px/frame.
//
// Speeds are stored as signed integers in units of 1/16 pixel per frame
// (4 fractional bits) so that dx = 2.0 becomes 16'd32 and dy = 1.0 = 16'd16.

`ifndef GAME_PKG_VH
`define GAME_PKG_VH

// Screen
`define SCREEN_W  640
`define SCREEN_H  480

// Court border width
`define BORDER   2

// Ball geometry
`define BALL_W   8
`define BALL_H   8

// Paddle geometry
`define PAD_W    8
`define PAD_H    64
`define PAD_L_X  16
`define PAD_R_X  616   // 640 - 16 - 8

// Ball initial position (centre, Q8.4 — stored as integer × 16)
`define BALL_INIT_X   ((`SCREEN_W/2 - `BALL_W/2) * 16)
`define BALL_INIT_Y   ((`SCREEN_H/2 - `BALL_H/2) * 16)

// Ball initial velocity (Q.4: +2.0 → 32, +1.0 → 16)
`define BALL_INIT_DX  32   // +2 pixels/frame
`define BALL_INIT_DY  16   // +1 pixel/frame

// Paddle initial Y (centre)
`define PAD_INIT_Y    ((`SCREEN_H - `PAD_H) / 2)

// Paddle speed (pixels per frame, integer)
`define PAD_SPEED     4

// Score display X positions (left digit column for each player)
`define SCORE_L_X     280
`define SCORE_R_X     340
`define SCORE_Y       16

// Winning score
`define WIN_SCORE     9

// Frame counter width: need to count 60 frames/s, enough to hold 60.
`define FRAME_CNTW    6

`endif
