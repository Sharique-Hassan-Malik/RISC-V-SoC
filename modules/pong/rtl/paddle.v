// paddle.v — Paddle position controller for one paddle.
//
// Moves the paddle up or down by PAD_SPEED pixels per game tick.
// Clamps the paddle within the court (border to screen bottom minus pad height).
//
// btn_up   — move paddle up   (toward y=0)
// btn_down — move paddle down (toward y=SCREEN_H)

`include "game_pkg.vh"

module paddle (
    input  wire       clk,
    input  wire       rst,
    input  wire       game_tick,
    input  wire       btn_up,
    input  wire       btn_down,
    output reg  [8:0] pad_y       // top pixel of paddle
);

    localparam Y_MIN = `BORDER;
    localparam Y_MAX = `SCREEN_H - `PAD_H - `BORDER;

    always @(posedge clk) begin
        if (rst) begin
            pad_y <= `PAD_INIT_Y;
        end else if (game_tick) begin
            if (btn_up && pad_y > Y_MIN)
                pad_y <= pad_y - `PAD_SPEED;
            else if (btn_down && pad_y < Y_MAX)
                pad_y <= pad_y + `PAD_SPEED;
        end
    end

endmodule
