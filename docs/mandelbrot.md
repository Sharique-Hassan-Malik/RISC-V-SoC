# Architecture

## Overview

A 640×480 VGA display driven entirely from block RAM with a pipelined
hardware Mandelbrot set renderer operating in the background.  No soft-core
CPU is present.  The VGA scan-out reads a framebuffer at pixel-clock rate
while the Mandelbrot engine writes iteration counts to the same RAM
asynchronously.  The design is written in VHDL throughout and targets the
Lattice iCEstick (iCE40HX1K) for synthesis and GHDL for simulation.

---

## Block Diagram

```
clk_25 (25 MHz pixel clock)
    │
    ├──► vga_sync ──► hsync, vsync, active, hpos, vpos
    │         │
    │         └──► fb_rd_addr = vpos×640 + hpos
    │                    │
    │              framebuffer (dual-port block RAM)
    │                    │
    │         fb_wr_addr ◄──── mandelbrot_engine ──► fb_we, fb_wr_data
    │         fb_rd_data ──► colour_map ──► {R,G,B}
    │                                          │
    │                                          └─ gated by active_d1
    │
    └──► vga_r, vga_g, vga_b (3-bit RGB)
```

---

## Module Descriptions

### `vga_pkg.vhd`

VHDL package containing all timing constants for 640×480 @ 60 Hz, the
fixed-point format constants (Q4.27, `FP_ONE`, `FP_FRAC`) and the maximum
iteration count.  Importing this package with `use work.vga_pkg.all` provides
all constants without magic numbers in other modules.

### `vga_sync.vhd`

Standard synchronous VGA counter pair.  `hcnt` runs 0–799, `vcnt` runs
0–524.  Sync pulses are generated combinationally from comparisons against the
constant boundaries.  The `active` output is the blanking gate — high only when
both counters are in the visible region.

Timing derivation (640×480 @ 60 Hz, 25 MHz pixel clock):
```
H total = 640 + 16 + 96 + 48 = 800 pixels  → 800/25e6 = 32 µs per line
V total = 480 + 10 +  2 + 33 = 525 lines   → 525 × 32 µs = 16.8 ms per frame
Frame rate = 1/16.8 ms ≈ 59.5 Hz
```

### `fp_mul.vhd`

Pipelined Q4.27 multiplier.  Both inputs are 32-bit signed integers with 27
fractional bits (range ≈ ±8.0).  The 64-bit product is computed in stage 1;
bits [58:27] are extracted in stage 2 to give the Q4.27 result.

Bit extraction justification:
```
Full product bit layout (Q4.27 × Q4.27 → Q8.54):
  bits 63:54  integer part (10 bits, we use only top 4+sign = 5)
  bits 53:27  Q4.27 fractional result  (bits 58:27 captures sign + 4 int + 27 frac)
  bits 26:0   sub-fractional (discarded)

Extract result_r = product_r(58 downto 27)
This is equivalent to: result = (a × b) >> 27 with 32-bit output
```

### `mandelbrot_iter.vhd`

One step of the Mandelbrot recurrence:
```
z_re_next = z_re² − z_im² + c_re
z_im_next = 2 × z_re × z_im + c_im
```

Three `fp_mul` instances compute `z_re²`, `z_im²` and `z_re × z_im` in parallel.
Each has a 2-cycle latency.  The `c` values are delayed by 2 matching pipeline
registers.  One further registered adder stage combines the products and
constant offsets, giving a total pipeline depth of 3 clock cycles.

The escape test `|z|² > 4` is evaluated on the registered sum `z_re² + z_im²`
compared against `4 × 2^27 = 536870912`.

### `mandelbrot_engine.vhd`

A three-state FSM that drives the iterator for one pixel at a time:

```
S_LOAD:
  Compute c_re = RE_MIN + px × RE_STEP
  Compute c_im = IM_MIN + py × IM_STEP
  Reset z_re = z_im = 0, iter = 0
  → S_ITERATE

S_ITERATE:
  Wait 3 cycles (pipeline depth of mandelbrot_iter)
  On 3rd cycle:
    if escaped OR iter = MAX_ITER-1 → S_WRITE
    else accept z_re_next, z_im_next, iter++, stay

S_WRITE:
  fb_we = 1, fb_addr = py×640 + px, fb_data = iter
  Advance px (or py if px wraps to 640)
  → S_LOAD
```

View window constants in Q4.27:
```
RE_MIN  = −2.5 × 2^27 = −335544320
RE_STEP = 3.5/640 × 2^27 = 737280    (3.5 covered in 640 steps)
IM_MIN  = −1.25 × 2^27 = −167772160
IM_STEP = 2.5/480 × 2^27 = 699051    (2.5 covered in 480 steps)
```

Per-pixel computation time: up to `MAX_ITER × 3 + 2` cycles = 194 cycles at
25 MHz = 7.76 µs.  Full 640×480 frame: ≈ 307200 × 7.76 µs = 2.38 s.

### `framebuffer.vhd`

True dual-port block RAM inferred from a VHDL `shared variable` array.
Port A (write) is driven by the Mandelbrot engine at 25 MHz.  Port B (read)
is driven by the VGA scan at 25 MHz.  Both ports use the same clock so there
are no clock-domain crossing issues.

Memory sizing:
```
640 × 480 × 7 bits = 2 150 400 bits ≈ 2.15 Mbit
```

This exceeds the iCE40HX1K's 64 Kbit of block RAM.  Options:
- **iCE40HX4K or HX8K**: 128–256 Kbit of block RAM — still insufficient.
- **Xilinx Spartan-6 / Artix-7**: typically 4–18 Mbit of block RAM — fits.
- **Reduced resolution**: 160×120 pixels × 7 bits = 134 Kbit — fits in HX8K.
- **External SRAM**: use an IS61WV5128BLL (512K × 8 SRAM) on the PCB.

For the iCEstick demonstration, modify `synth_top.vhd` to use 160×120 logical
pixels drawn 4× wide × 4× tall (pixel-doubling in both dimensions), reducing
the framebuffer to 134 Kbit.  The `mandelbrot_engine.vhd` RE_STEP and IM_STEP
constants scale accordingly.

### `colour_map.vhd`

Combinational lookup mapping iteration counts to 3-bit RGB (one bit per
channel, 8 colours total).  Interior pixels (`iter ≥ MAX_ITER`) map to black.
Exterior pixels cycle through 7 non-black colours modulo 7 using the low 3
bits of the iteration count.  The colour assignment is:

| iter & 7 | Colour |
|---|---|
| 0 | blue |
| 1 | green |
| 2 | cyan |
| 3 | red |
| 4 | magenta |
| 5 | yellow |
| 6 | white |

---

## Fixed-Point Arithmetic Analysis

The Mandelbrot iteration stays bounded for |z| ≤ 2.  The view window extends
to Re = -2.5 so the Q4.27 format (4 integer bits → range ±8) never overflows
within the region of interest.

The main source of error relative to floating-point is the Q4.27 quantisation
of the view constants (RE_MIN, RE_STEP, IM_MIN, IM_STEP).  Each pixel maps
to a coordinate with a quantisation error of at most ½ × 2^−27 ≈ 3.7 × 10^−9.
After 64 iterations the accumulated error stays small enough that border
pixels differ by at most ±2 iterations from the float reference — verified by
`sim/verify_fp.py --check-fp`.

---

## Simulation

```bash
# Generate reference images and check fixed-point accuracy.
python3 sim/verify_fp.py --check-fp --fp-image

# Compile and run GHDL simulation (VHDL-2008 required for 'automatic').
ghdl -a --std=08 rtl/vga_pkg.vhd rtl/fp_mul.vhd rtl/mandelbrot_iter.vhd \
     rtl/mandelbrot_engine.vhd rtl/framebuffer.vhd rtl/colour_map.vhd \
     rtl/vga_sync.vhd rtl/synth_top.vhd sim/tb_mandelbrot.vhd
ghdl -e --std=08 tb_mandelbrot
ghdl -r --std=08 tb_mandelbrot --vcd=tb.vcd --stop-time=50ms

# View output image.
# mandelbrot.ppm is written by the testbench during simulation.
# Open with any PPM-capable viewer: eog, feh, GIMP, etc.

# View waveforms.
gtkwave tb.vcd
```

---

## Building for Hardware

```bash
# Yosys synthesis (reads all VHDL files via ghdl plugin).
# The ghdl-yosys-plugin must be installed: https://github.com/ghdl/ghdl-yosys-plugin
yosys -m ghdl -p "ghdl --std=08 rtl/vga_pkg.vhd rtl/fp_mul.vhd \
                        rtl/mandelbrot_iter.vhd rtl/mandelbrot_engine.vhd \
                        rtl/framebuffer.vhd rtl/colour_map.vhd \
                        rtl/vga_sync.vhd rtl/synth_top.vhd -e synth_top; \
                  synth_ice40 -top synth_top -json synth_top.json"

nextpnr-ice40 --hx1k --package tq144 \
              --json synth_top.json --pcf rtl/synth_top.pcf \
              --asc synth_top.asc

icepack synth_top.asc synth_top.bin
iceprog synth_top.bin
```

---

## File Map

| File | Description |
|---|---|
| `rtl/vga_pkg.vhd` | VGA timing constants and fixed-point format package |
| `rtl/vga_sync.vhd` | Horizontal and vertical sync generator |
| `rtl/fp_mul.vhd` | Pipelined Q4.27 signed multiplier (2-cycle latency) |
| `rtl/mandelbrot_iter.vhd` | One Mandelbrot iteration step (3-cycle pipeline) |
| `rtl/mandelbrot_engine.vhd` | FSM iterating pixels and writing framebuffer |
| `rtl/framebuffer.vhd` | Dual-port block RAM (write: engine, read: VGA) |
| `rtl/colour_map.vhd` | Iteration count → 3-bit RGB colour palette |
| `rtl/synth_top.vhd` | Top-level design connecting all modules |
| `rtl/synth_top.pcf` | iCEstick pin constraints |
| `sim/tb_mandelbrot.vhd` | VHDL testbench with PPM image capture |
| `sim/verify_fp.py` | Python reference renderer and Q4.27 accuracy checker |
| `docs/ARCHITECTURE.md` | This document |
