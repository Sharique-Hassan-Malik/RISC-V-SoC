// tb_ball.v — fast unit test for the ball physics engine.
// Pulses game_tick directly (no VGA timing) so wall reflections can be observed
// in microseconds instead of the many-millisecond frames of the full design.
`timescale 1ns/1ps
`include "game_pkg.vh"

module tb_ball;
    reg clk = 0, rst = 1, game_tick = 0;
    reg  [8:0] pad_l_y = 0, pad_r_y = 0;
    wire [9:0] ball_x;
    wire [8:0] ball_y;
    wire       score_l, score_r;

    ball dut (.clk(clk), .rst(rst), .game_tick(game_tick),
              .pad_l_y(pad_l_y), .pad_r_y(pad_r_y),
              .ball_x(ball_x), .ball_y(ball_y),
              .score_l(score_l), .score_r(score_r));

    always #5 clk = ~clk;

    integer i, pass = 0, fail = 0;
    integer max_y, min_y;
    reg saw_up, saw_down;

    task chk; input [255:0] n; input c; begin
        if (c) begin $display("  PASS: %0s", n); pass = pass + 1; end
        else   begin $display("  FAIL: %0s", n); fail = fail + 1; end
    end endtask

    initial begin
        saw_up = 0; saw_down = 0; max_y = 0; min_y = 511;
        rst = 1; repeat (4) @(posedge clk); rst = 0; @(posedge clk);
        for (i = 0; i < 2000; i = i + 1) begin
            // Keep both paddles centred on the ball so it never scores.
            pad_l_y = (ball_y > 32) ? ball_y - 32 : 9'd0;
            pad_r_y = pad_l_y;
            @(posedge clk); game_tick = 1;
            @(posedge clk); game_tick = 0;
            @(posedge clk);
            if (dut.vel_y < 0) saw_up   = 1;
            if (dut.vel_y > 0) saw_down = 1;
            if (ball_y > max_y) max_y = ball_y;
            if (ball_y < min_y) min_y = ball_y;
            if (saw_up && saw_down) i = 2000;
        end
        $display("\n[ball unit test]  ball_y bottom edge reached %0d (screen %0d, border %0d)",
                 max_y + `BALL_H, `SCREEN_H, `BORDER);
        chk("vel_y takes both signs (top+bottom wall reflection)", saw_up && saw_down);
        // The wall is at the border, so the ball legitimately reaches the border
        // edge; it must never leave the screen entirely.
        chk("ball never leaves the screen", (max_y + `BALL_H) <= `SCREEN_H);
        $display("  %0d passed, %0d failed\n", pass, fail);
        $finish;
    end
endmodule
