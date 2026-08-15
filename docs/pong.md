# Architecture

## Overview

A complete two-player Pong game implemented entirely as synthesisable
combinational and sequential Verilog logic.  There is no processor, no
firmware and no memory — every game rule, collision test, score update and
pixel decision is a hardware circuit.  The design targets the Lattice iCEstick
(iCE40HX1K) and outputs a standard 640×480 @ 60 Hz VGA signal.

---

## Block Diagram

```
clk_25 (25 MHz)
    │
    ├──► vga_sync ──────────────────────────────► hsync, vsync
    │    │ active, hpos, vpos
    │    │
    │    │ (falling edge of vsync)
    │    └──► game_tick (1 pulse/frame)
    │                │
    │    ┌───────────┼────────────────────────┐
    │    ▼           ▼                        ▼
    │  paddle_L    paddle_R                  ball
    │  (btn_l_up   (btn_r_up             (pad_l_y,
    │   btn_l_dn)   btn_r_dn)             pad_r_y)
    │    │           │                     │   │
    │    │pad_l_y    │pad_r_y    ball_x,y──┘   │score_l/r
    │    │           │                         │
    │    └─────┬─────┘                    scoreboard
    │          │                          │  score_left
    │          ▼                          │  score_right
    │      renderer ◄─────────────────────┘  game_over
    │    (combinational)
    │    (hpos, vpos, ball, paddles,
    │     scores, game_over, win_flash)
    │          │
    └──────────┴──► vga_pixel
```

---

## Module Descriptions

### `vga_sync.v`

Standard dual-counter VGA sync generator at 25 MHz.  `hcnt` runs 0–799,
`vcnt` 0–524.  Sync pulses are active-low, negative polarity.  The `active`
output is high only during the 640×480 visible region.  A registered copy of
the `vsync` falling edge drives `game_tick` in the top level.

### `ball.v`

The ball position is stored in Q8.4 fixed-point (16-bit each for X and Y):
- 4 fractional bits allow sub-pixel velocities without floating-point.
- Integer part (`pos_x[13:4]`) is the display pixel.
- Initial velocity: dx = +2.0 px/frame = 32 (Q.4), dy = +1.0 px/frame = 16.

Collision detection is purely combinational comparators:

**Wall reflection (top/bottom):**
```
if ball_y <= BORDER:          dy = +INIT_DY   (reflect downward)
if ball_y + BALL_H >= SCREEN_H - BORDER: dy = -INIT_DY (reflect upward)
```

**Paddle reflection:**
```
Left paddle:  if vel_x < 0
              AND ball_x <= PAD_L_X + PAD_W
              AND ball centre_y in [pad_l_y, pad_l_y + PAD_H]:
                  vel_x = +INIT_DX

Right paddle: if vel_x > 0
              AND ball_x + BALL_W >= PAD_R_X
              AND ball centre_y in [pad_r_y, pad_r_y + PAD_H]:
                  vel_x = -INIT_DX
```

The velocity direction check (`vel_x < 0` for left, `vel_x > 0` for right)
prevents the ball from being trapped inside a paddle on a second hit.

**Scoring:**
```
if ball_x <  BORDER:          score_l pulse; reset ball, dx positive
if ball_x + BALL_W > SCREEN_W - BORDER: score_r pulse; reset ball, dx negative
```

All collision logic executes once per `game_tick`.  Because the game tick
coincides with vertical blanking, no tearing or mid-frame glitches are possible.

### `paddle.v`

Clamps the paddle Y position to `[BORDER, SCREEN_H - PAD_H - BORDER]` and
moves by `PAD_SPEED` pixels per game tick in response to held button inputs.
Movement is frozen when `game_over` is asserted by the top level gating the
`game_tick` signal.

### `scoreboard.v`

Two 4-bit counters increment on `score_l` / `score_r` pulses.  The
`game_over` flag latches when either counter reaches `WIN_SCORE` (default 9)
and the `winner` signal records which player won.  Scores are frozen (no
further increments) after `game_over`.

### `renderer.v`

The entire screen is produced combinationally — no pixel clock register and no
framebuffer.  For each `(hpos, vpos)` the renderer evaluates seven Boolean
expressions in priority order:

| Layer | Condition |
|---|---|
| Border | `hpos < 2 \|\| hpos >= 638 \|\| vpos < 2 \|\| vpos >= 478` |
| Centre dashes | `(hpos == 319 \|\| hpos == 320) && vpos[3] == 0` |
| Left paddle | `hpos in [PAD_L_X, PAD_L_X+PAD_W) && vpos in [pad_l_y, pad_l_y+PAD_H)` |
| Right paddle | symmetric |
| Ball | `hpos in [ball_x, ball_x+8) && vpos in [ball_y, ball_y+8)` |
| Score digits | 4×7 bitmap (2× scaled) read from `digit_rom` |
| Win flash | `game_over && win_flash` |

The `OR` of all active layers drives `pixel_on`.  Because the display is
monochrome, `pixel_on = 1` means white; all three VGA colour channels are
tied together through equal resistors.

### `digit_rom.v`

A combinational ROM storing ten 4×7 pixel bitmaps (one per digit 0–9) as
28-bit constant values.  Given `(digit, col, row)` it returns a single
`pixel` bit with no clock.  Two instances (one per player) are instantiated
inside `renderer.v`.

Each digit bitmap is a 28-bit constant with the following encoding:
```
bit index = (6 - row) × 4 + (3 - col)
```
Row 0 is the top row; col 0 is the leftmost column.

Score digits are displayed at 2× scale (each font pixel occupies a 2×2 block
of display pixels), making them 8×14 display pixels per digit.

### `debounce.v`

A 3-stage shift register sampled at 1 kHz (one `div_cnt` divider from
25 MHz) provides 3 ms of hysteresis.  One instance per button.

### `pong_top.v`

Top-level wiring and two timing circuits:

**Game tick** — a single flip-flop detects the falling edge of `vsync` and
produces a one-cycle `game_tick` pulse.  All game-state registers update only
on this pulse, so the game runs at exactly the VGA refresh rate (≈ 59.5 Hz,
rounded to 60 Hz in documentation).

**Win flash** — a 4-bit counter increments each `game_tick` when `game_over`
is asserted.  On count 14 it resets and toggles `win_flash`, producing a
≈ 4 Hz blink.  The renderer uses `win_flash` to fill the screen white on
alternate half-periods.

---

## Collision Detection: No CPU Required

The paddle AABB (axis-aligned bounding box) test for the left paddle requires:

```
left_hit = (vel_x < 0)                     -- moving toward left paddle
         & (ball_x <= PAD_L_X + PAD_W)     -- reached paddle face
         & (ball_x + BALL_W > PAD_L_X)     -- not past paddle yet
         & (ball_cy >= pad_l_y)            -- within paddle top
         & (ball_cy <= pad_l_y + PAD_H)    -- within paddle bottom
```

All five conditions are synthesised as a single 5-input AND gate of
comparators.  At 25 MHz the critical path through the deepest comparator
(the Q8.4-to-integer extraction plus the 9-bit subtractor) closes comfortably
on iCE40.

---

## Screen Layout

```
┌──────────────────────────────────────────────────────────────────┐  y=0
│ (border)         280  4  340                                     │
│              ┌──────┐   ┌──────┐    ← score digits (8×14)       │  y=16
│              │  3   │   │  5   │                                 │
│              └──────┘   └──────┘                                 │  y=30
│                         │                                        │
│  ┌──┐    ·····│·····    │                       ┌──┐             │
│  │  │    centre│line    │ ←ball                 │  │             │
│  │  │    (dash)│        │                       │  │             │
│  └──┘          │        │                       └──┘             │
│  x=16        x=319,320                         x=616             │
│                                                                   │  y=479
└──────────────────────────────────────────────────────────────────┘
```

---

## Resource Estimate (iCE40HX1K)

| Module | LUTs | Registers |
|---|---|---|
| vga_sync | ~20 | 20 |
| ball | ~80 | 50 |
| paddle × 2 | ~20 | 18 |
| scoreboard | ~20 | 12 |
| renderer | ~60 | 2 |
| digit_rom × 2 | ~30 | 0 (comb) |
| debounce × 5 | ~50 | 45 |
| pong_top (glue) | ~20 | 10 |
| **Total** | **~300** | **~157** |

Well within the iCE40HX1K's 1280 LUTs and 1280 flip-flops.

---

## Building

```bash
# Synthesise with Yosys.
yosys -p "synth_ice40 -top pong_top -json pong_top.json" \
      rtl/pong_top.v rtl/vga_sync.v rtl/ball.v rtl/paddle.v \
      rtl/scoreboard.v rtl/renderer.v rtl/digit_rom.v rtl/debounce.v

# Place and route.
nextpnr-ice40 --hx1k --package tq144 \
              --json pong_top.json --pcf rtl/pong_top.pcf \
              --asc pong_top.asc

# Generate bitstream and program.
icepack pong_top.asc pong_top.bin
iceprog pong_top.bin
```

---

## Simulation

```bash
iverilog -g2012 -o tb_pong \
    sim/tb_pong.v rtl/pong_top.v rtl/vga_sync.v rtl/ball.v \
    rtl/paddle.v rtl/scoreboard.v rtl/renderer.v \
    rtl/digit_rom.v rtl/debounce.v
vvp tb_pong
gtkwave tb_pong.vcd
```

---

## File Map

| File | Description |
|---|---|
| `rtl/game_pkg.vh` | Game geometry, timing and physics constants |
| `rtl/vga_sync.v` | 640×480 @ 60 Hz VGA sync generator |
| `rtl/ball.v` | Q8.4 fixed-point ball physics and AABB collision |
| `rtl/paddle.v` | Paddle position controller with bounds clamping |
| `rtl/scoreboard.v` | Score counters and game-over detection |
| `rtl/renderer.v` | Combinational pixel renderer — all layers |
| `rtl/digit_rom.v` | 4×7 bitmap font for digits 0–9 |
| `rtl/debounce.v` | 3-stage shift-register button debouncer |
| `rtl/pong_top.v` | Top-level — game tick, win flash, module wiring |
| `rtl/pong_top.pcf` | iCEstick pin constraints |
| `sim/tb_pong.v` | Testbench: VGA timing, collision and scoring checks |
| `docs/ARCHITECTURE.md` | This document |
