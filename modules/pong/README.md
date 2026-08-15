# FPGA Pong

> Part of the [RISC-V SoC](../../README.md). Simulates standalone from this
> folder, or through `soc sim --only <name>`, which already knows the flags.

A complete two-player Pong game implemented as pure synchronous digital
logic in Verilog.  Ball physics, paddle movement, score counting, collision
detection and pixel rendering are all hardware circuits — no processor, no
firmware and no memory.  The design targets the Lattice iCEstick (iCE40HX1K)
and outputs a standard 640×480 @ 60 Hz VGA signal.

---

## What it does

Two paddles are controlled by four tactile buttons (up/down per player).
A ball bounces off the top and bottom walls and off the paddles.  If the ball
passes either paddle, the opposing player scores a point and the ball resets
to centre.  The first player to reach 9 points wins; the screen flashes white
at 4 Hz until the reset button is pressed to start a new game.  Current
scores are shown as 2×-scaled digits at the top centre of the screen.

---

## The hard part

**Everything is a circuit — no CPU, no code.**  There is no instruction pointer
and no loop.  The ball moves because a Q8.4 accumulator adds a signed velocity
register to itself on every vertical sync pulse.  The paddle collision is a
5-input AND gate comparing the ball's bounding box against the paddle's
bounding box every game tick.  The score appears on screen because a digit
bitmap ROM is read combinationally — for every pixel position inside the score
region the renderer asks "does this bit of digit N equal 1?" and drives the
output directly.

**Q8.4 fixed-point ball velocity** allows sub-pixel speeds without a divider.
The ball moves 2.0 horizontal pixels and 1.0 vertical pixel per frame
(dx = 32, dy = 16 in Q.4 units).  The integer part of the accumulator is the
display coordinate.  This keeps the physics deterministic and purely additive.

**Collision without glitches** — all game-state registers update only on the
`game_tick` pulse (the falling edge of VGA vsync, once per frame during
vertical blanking).  Because the ball and paddle positions are stable for the
entire visible frame, the renderer never sees a mid-frame position change and
there is no tearing or aliasing between the physics and the display.

---

## Architecture

See `docs/ARCHITECTURE.md` for the full block diagram, collision detection
equations, renderer layer table, screen layout diagram, Q8.4 arithmetic
derivation and resource estimate.

---

## Hardware

| Component | Notes |
|---|---|
| FPGA | Lattice iCEstick (iCE40HX1K-TQ144) |
| Clock | 25 MHz external (or SB_PLL40_CORE from 12 MHz on-board OSC) |
| VGA | 3-bit monochrome — R, G, B tied together through 470 Ω each |
| Buttons | 4× tactile switches + 1 reset (active high, 10 kΩ pull-up) |

**VGA wiring**

| DB15 pin | Signal |
|---|---|
| 1, 2, 3 | vga_pixel → 470 Ω → each pin (R, G, B) |
| 5,6,7,8,10 | GND |
| 13 | vga_hsync |
| 14 | vga_vsync |

---

## Controls

| Button | Player | Action |
|---|---|---|
| J1-3 | Left | Paddle up |
| J1-4 | Left | Paddle down |
| J1-5 | Right | Paddle up |
| J1-6 | Right | Paddle down |
| J1-7 | — | Reset / new game |

---

## Building

```bash
yosys -p "synth_ice40 -top pong_top -json pong_top.json" \
      rtl/pong_top.v rtl/vga_sync.v rtl/ball.v rtl/paddle.v \
      rtl/scoreboard.v rtl/renderer.v rtl/digit_rom.v rtl/debounce.v

nextpnr-ice40 --hx1k --package tq144 \
              --json pong_top.json --pcf rtl/pong_top.pcf \
              --asc pong_top.asc

icepack pong_top.asc pong_top.bin
iceprog pong_top.bin
```

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

## Results

| Metric | Value |
|---|---|
| Resolution | 640 × 480 @ ~60 Hz |
| Ball speed | 2 px/frame horizontal, 1 px/frame vertical (Q8.4) |
| Paddle speed | 4 px/frame |
| Win condition | 9 points |
| Estimated LUT usage | ~300 / 1280 on iCE40HX1K |
| Estimated FF usage | ~157 / 1280 on iCE40HX1K |
| Collision method | Combinational AABB comparators |
| Rendering method | Fully combinational — no framebuffer |
