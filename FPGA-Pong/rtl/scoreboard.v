// scoreboard.v — Score counter for both players.
//
// Increments the relevant player's score on each score pulse.
// Asserts `game_over` when either player reaches WIN_SCORE.
// `winner` is 0 for left player, 1 for right player.
// After game_over is asserted, scores freeze until rst.

`include "game_pkg.vh"

module scoreboard (
    input  wire       clk,
    input  wire       rst,
    input  wire       score_l,      // right player scored (left missed)
    input  wire       score_r,      // left  player scored (right missed)
    output reg  [3:0] score_left,
    output reg  [3:0] score_right,
    output reg        game_over,
    output reg        winner        // 0 = left won, 1 = right won
);

    always @(posedge clk) begin
        if (rst) begin
            score_left  <= 4'd0;
            score_right <= 4'd0;
            game_over   <= 1'b0;
            winner      <= 1'b0;
        end else if (!game_over) begin
            if (score_l) begin
                score_right <= score_right + 1;
                if (score_right + 1 >= `WIN_SCORE) begin
                    game_over <= 1'b1;
                    winner    <= 1'b1;
                end
            end else if (score_r) begin
                score_left <= score_left + 1;
                if (score_left + 1 >= `WIN_SCORE) begin
                    game_over <= 1'b1;
                    winner    <= 1'b0;
                end
            end
        end
    end

endmodule
