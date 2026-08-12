// ball.v — Ball physics engine.
//
// Position is stored in Q8.4 fixed-point (12-bit integer, 4 fractional bits)
// separately for X and Y.  On each game_tick the velocity is added; the
// integer part of the position (bits [11:4]) is the display pixel.
//
// Collision detection is performed purely with comparators — no multipliers.
//
// Wall collisions (top / bottom border):
//   If the ball's top edge reaches the court top (y_int <= BORDER),
//   or the bottom edge reaches the court bottom (y_int + BALL_H >= SCREEN_H - BORDER),
//   reflect dy.
//
// Paddle collisions:
//   Left paddle:  if ball's left edge is at PAD_L_X + PAD_W and
//                 the ball's vertical centre lies within the paddle,
//                 reflect dx (now positive).
//   Right paddle: symmetric.
//
// Scoring:
//   If the ball exits the left edge (x_int < 0), right player scores.
//   If the ball exits the right edge (x_int > SCREEN_W), left player scores.
//   Either event asserts `score_l` or `score_r` for one game_tick.
//
// After scoring the ball is reset to centre with the opposite dx.

`include "game_pkg.vh"

module ball (
    input  wire        clk,
    input  wire        rst,
    input  wire        game_tick,    // one pulse per frame (60 Hz)
    input  wire [8:0]  pad_l_y,      // left  paddle top Y (0..479)
    input  wire [8:0]  pad_r_y,      // right paddle top Y
    output reg  [9:0]  ball_x,       // integer pixel X (for renderer)
    output reg  [8:0]  ball_y,       // integer pixel Y
    output reg         score_l,      // right player scored (left side missed)
    output reg         score_r       // left  player scored (right side missed)
);

    // ---- Q8.4 position accumulator (16-bit each) -------------------------
    reg signed [15:0] pos_x;   // integer part = pos_x[15:4]
    reg signed [15:0] pos_y;

    // ---- Velocity (signed, Q.4 units = 1/16 pixel per frame) ------------
    reg signed [7:0]  vel_x;
    reg signed [7:0]  vel_y;

    // Integer pixel positions (combinational)
    wire [9:0] ix = pos_x[13:4];   // safe for 640-wide screen
    wire [8:0] iy = pos_y[12:4];   // safe for 480-high screen

    // ---- Paddle collision bounds -----------------------------------------
    // Left paddle right edge = PAD_L_X + PAD_W
    localparam PAD_L_RIGHT = `PAD_L_X + `PAD_W;
    // Right paddle left edge = PAD_R_X
    localparam PAD_R_LEFT  = `PAD_R_X;

    // Ball vertical centre (used for paddle hit zone check)
    wire [8:0] ball_cy = iy + `BALL_H / 2;

    // Paddle hit zones (ball centre must be inside paddle)
    wire hit_l_zone = (ball_cy >= pad_l_y) && (ball_cy <= pad_l_y + `PAD_H);
    wire hit_r_zone = (ball_cy >= pad_r_y) && (ball_cy <= pad_r_y + `PAD_H);

    // ---- Reset helper ----------------------------------------------------
    task reset_ball;
        input negate_dx;
        begin
            pos_x  <= `BALL_INIT_X;
            pos_y  <= `BALL_INIT_Y;
            vel_x  <= negate_dx ? -`BALL_INIT_DX : `BALL_INIT_DX;
            vel_y  <= `BALL_INIT_DY;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            reset_ball(0);
            ball_x  <= `SCREEN_W / 2 - `BALL_W / 2;
            ball_y  <= `SCREEN_H / 2 - `BALL_H / 2;
            score_l <= 1'b0;
            score_r <= 1'b0;
        end else begin
            score_l <= 1'b0;
            score_r <= 1'b0;

            if (game_tick) begin
                // ---- Advance position ------------------------------------
                pos_x <= pos_x + vel_x;
                pos_y <= pos_y + vel_y;

                // ---- Top / bottom wall reflection ------------------------
                if (iy <= `BORDER)
                    vel_y <= (`BALL_INIT_DY);
                else if (iy + `BALL_H >= `SCREEN_H - `BORDER)
                    vel_y <= -(`BALL_INIT_DY);

                // ---- Left paddle reflection ------------------------------
                // Ball moving left, left edge just reached paddle right edge.
                if (vel_x < 0 &&
                    ix <= PAD_L_RIGHT && ix + `BALL_W > `PAD_L_X &&
                    hit_l_zone) begin
                    vel_x <= `BALL_INIT_DX;   // bounce right
                end

                // ---- Right paddle reflection -----------------------------
                if (vel_x > 0 &&
                    ix + `BALL_W >= PAD_R_LEFT && ix < PAD_R_LEFT + `PAD_W &&
                    hit_r_zone) begin
                    vel_x <= -(`BALL_INIT_DX);   // bounce left
                end

                // ---- Scoring: ball exits left or right edge --------------
                if ($signed({1'b0, ix}) < `BORDER) begin
                    score_l <= 1'b1;
                    reset_ball(1);
                end else if (ix + `BALL_W > `SCREEN_W - `BORDER) begin
                    score_r <= 1'b1;
                    reset_ball(0);
                end

                // ---- Update integer output positions ---------------------
                ball_x <= pos_x[13:4];
                ball_y <= pos_y[12:4];
            end
        end
    end

endmodule
