// pong_top.v — Top-level Pong game.
//
// Target: Lattice iCEstick (iCE40HX1K-TQ144)
// Master clock: 25 MHz (external; or use iCEstick 12 MHz → SB_PLL40_CORE × 2)
//
// VGA output: 3-bit monochrome (R=G=B tied together)
//   All white pixels on pin 61 (J2 PMOD), connect to VGA R+G+B through 470 Ω each.
//   Or tie all three VGA colour channels to pong_pixel for a true white-on-black display.
//
// Buttons (active-high — add external pull-downs or invert):
//   btn_l_up   : RB0 / J1-1  — left paddle up
//   btn_l_down : RB1 / J1-2  — left paddle down
//   btn_r_up   : RB2 / J1-3  — right paddle up
//   btn_r_down : RB3 / J1-4  — right paddle down
//   btn_rst    : RB4 / J1-5  — global reset / new game
//
// Game tick: one pulse per VGA frame (rising edge of vsync falling-edge → rising-edge).
// Win flash: 4 Hz toggle derived by counting frames after game_over.

`include "game_pkg.vh"
`default_nettype none

module pong_top (
    input  wire clk_25,
    // Buttons (active high after debounce)
    input  wire btn_l_up_raw,
    input  wire btn_l_down_raw,
    input  wire btn_r_up_raw,
    input  wire btn_r_down_raw,
    input  wire btn_rst_raw,
    // VGA
    output wire vga_hsync,
    output wire vga_vsync,
    output wire vga_pixel,   // white/black — tie R, G, B together through 470 Ω each
    // Status LEDs (active low on iCEstick)
    output wire led_l_score,  // dim when left  score > 0
    output wire led_r_score,  // dim when right score > 0
    output wire led_game_over
);

    // ---- Reset -----------------------------------------------------------
    wire rst;
    debounce #(.CLK_HZ(25_000_000)) u_rst_deb (
        .clk(clk_25), .rst(1'b0), .btn_raw(btn_rst_raw), .btn_out(rst)
    );

    // ---- Debounced paddle buttons ----------------------------------------
    wire btn_l_up, btn_l_down, btn_r_up, btn_r_down;
    debounce #(.CLK_HZ(25_000_000)) u_lu  (.clk(clk_25),.rst(rst),.btn_raw(btn_l_up_raw),  .btn_out(btn_l_up));
    debounce #(.CLK_HZ(25_000_000)) u_ld  (.clk(clk_25),.rst(rst),.btn_raw(btn_l_down_raw),.btn_out(btn_l_down));
    debounce #(.CLK_HZ(25_000_000)) u_ru  (.clk(clk_25),.rst(rst),.btn_raw(btn_r_up_raw),  .btn_out(btn_r_up));
    debounce #(.CLK_HZ(25_000_000)) u_rd  (.clk(clk_25),.rst(rst),.btn_raw(btn_r_down_raw),.btn_out(btn_r_down));

    // ---- VGA sync --------------------------------------------------------
    wire        active;
    wire [9:0]  hpos, vpos;
    wire        hsync_raw, vsync_raw;

    vga_sync u_vga (
        .pclk(clk_25), .rst(rst),
        .hsync(hsync_raw), .vsync(vsync_raw),
        .active(active), .hpos(hpos), .vpos(vpos)
    );

    assign vga_hsync = hsync_raw;
    assign vga_vsync = vsync_raw;

    // ---- Game tick: one pulse at the end of each VGA frame ---------------
    // Detect falling edge of vsync (start of vertical blanking).
    reg vsync_prev = 1'b1;
    reg game_tick  = 1'b0;

    always @(posedge clk_25) begin
        vsync_prev <= vsync_raw;
        game_tick  <= vsync_prev && !vsync_raw;   // falling edge
    end

    // ---- Win flash: ~4 Hz toggle (60 Hz / 15 frames per half-period) -----
    reg [3:0] flash_cnt  = 4'd0;
    reg       win_flash  = 1'b0;
    wire      game_over;

    always @(posedge clk_25) begin
        if (rst || !game_over) begin
            flash_cnt <= 4'd0;
            win_flash <= 1'b0;
        end else if (game_tick) begin
            if (flash_cnt == 4'd14) begin
                flash_cnt <= 4'd0;
                win_flash <= ~win_flash;
            end else begin
                flash_cnt <= flash_cnt + 1;
            end
        end
    end

    // ---- Paddle controllers ---------------------------------------------
    wire [8:0] pad_l_y, pad_r_y;

    paddle u_pad_l (
        .clk(clk_25), .rst(rst),
        .game_tick(game_tick && !game_over),
        .btn_up(btn_l_up), .btn_down(btn_l_down),
        .pad_y(pad_l_y)
    );

    paddle u_pad_r (
        .clk(clk_25), .rst(rst),
        .game_tick(game_tick && !game_over),
        .btn_up(btn_r_up), .btn_down(btn_r_down),
        .pad_y(pad_r_y)
    );

    // ---- Ball physics ---------------------------------------------------
    wire [9:0] ball_x;
    wire [8:0] ball_y;
    wire       score_l, score_r;

    ball u_ball (
        .clk(clk_25), .rst(rst),
        .game_tick(game_tick && !game_over),
        .pad_l_y(pad_l_y), .pad_r_y(pad_r_y),
        .ball_x(ball_x), .ball_y(ball_y),
        .score_l(score_l), .score_r(score_r)
    );

    // ---- Scoreboard -----------------------------------------------------
    wire [3:0] score_left, score_right;
    wire       winner;

    scoreboard u_score (
        .clk(clk_25), .rst(rst),
        .score_l(score_l), .score_r(score_r),
        .score_left(score_left), .score_right(score_right),
        .game_over(game_over), .winner(winner)
    );

    // ---- Renderer (pure combinational) -----------------------------------
    wire pixel_on;

    renderer u_render (
        .active(active), .hpos(hpos), .vpos(vpos),
        .ball_x(ball_x), .ball_y(ball_y),
        .pad_l_y(pad_l_y), .pad_r_y(pad_r_y),
        .score_left(score_left), .score_right(score_right),
        .game_over(game_over), .win_flash(win_flash),
        .pixel_on(pixel_on)
    );

    assign vga_pixel = pixel_on;

    // ---- Status LEDs (active low) ----------------------------------------
    assign led_l_score  = ~(|score_left);
    assign led_r_score  = ~(|score_right);
    assign led_game_over = ~game_over;

endmodule

`default_nettype wire
