# FPGA VGA Mandelbrot

A 640×480 VGA display driven from a hardware-pipelined Mandelbrot set renderer
written entirely in VHDL.  There is no soft-core CPU anywhere in the design.
A dedicated FSM iterates the Mandelbrot recurrence in fixed-point arithmetic
and writes the result for each pixel into a dual-port block RAM framebuffer.
The VGA sync generator reads the same RAM at pixel-clock rate and maps
iteration counts to a 3-bit RGB palette through a combinational colour lookup.
The design targets the Lattice iCEstick (iCE40) for synthesis and GHDL for
simulation.

---

## What it does

After FPGA power-on the Mandelbrot engine begins computing the classic
[-2.5, 1.0] × [-1.25, 1.25] view at 640×480 resolution.  As each pixel's
iteration count is determined it is written to the framebuffer; the VGA output
immediately begins displaying whatever has been calculated so far, filling in
from the top-left.  A full frame takes approximately 2.4 seconds at 25 MHz.
Once the frame is complete the engine restarts from pixel 0, so the display
continuously recalculates.

The five iCEstick LEDs show:
- LED D1: blinks on every framebuffer write (indicates engine running)
- LED D2: pulses briefly at the start of each new frame

---

## The hard part

**Hardware-pipelined fixed-point iteration.**  The Mandelbrot recurrence
requires two multiplies per iteration step (`z_re²`, `z_im²`, `z_re × z_im`).
All three are computed in parallel using dedicated `fp_mul` instances, each
of which has a 2-cycle register pipeline to close timing.  A third register
stage accumulates the additions.  The total pipeline depth is 3 clock cycles,
meaning the FSM must wait 3 cycles between feeding new `z` values and reading
the updated ones — this is the core timing challenge of the engine design.

**Q4.27 fixed-point accuracy.**  The view window extends to Re = −2.5, so
4 integer bits are required (range ±8).  Multiplying two Q4.27 values produces
a Q8.54 product; extracting bits [58:27] recovers the Q4.27 result.  The
`verify_fp.py` script compares this implementation against Python
floating-point across the full view window and confirms that border pixels
differ by at most ±2 iterations — close enough for visual correctness.

**Dual-port read-write without contention.**  The framebuffer write port
(Mandelbrot engine) and read port (VGA scan) are clocked from the same 25 MHz
clock.  Because the engine writes one pixel every 3–200 cycles while the VGA
port reads 640×480 = 307200 pixels per frame at one per clock, the read port
never has to wait — it simply reads whatever the engine last wrote to each
address, displaying partially-computed frames gracefully.

---

## Architecture

See `docs/ARCHITECTURE.md` for the full block diagram, Q4.27 bit-extraction
derivation, per-module pipeline analysis, framebuffer sizing discussion,
fixed-point accuracy analysis and build/simulation instructions.

---

## Hardware

| Component | Notes |
|---|---|
| FPGA | Lattice iCE40HX1K (iCEstick) or any device with sufficient block RAM |
| Clock | 25 MHz (external crystal or oscillator; see PCF notes) |
| VGA connector | Standard DB15, 3-bit colour (1 bit per channel) |

**VGA wiring (DB15 connector)**

| Pin | Signal | Connection |
|---|---|---|
| 1 | Red | FPGA vga_r → 470 Ω → pin 1 |
| 2 | Green | FPGA vga_g → 470 Ω → pin 2 |
| 3 | Blue | FPGA vga_b → 470 Ω → pin 3 |
| 5,6,7,8,10 | Ground | Common GND |
| 13 | HSync | FPGA vga_hs → direct |
| 14 | VSync | FPGA vga_vs → direct |

**Note on block RAM:** 640×480 × 7 bits = 2.15 Mbit.  The iCE40HX1K
has only 64 Kbit.  For the iCEstick, reduce to 160×120 pixels (134 Kbit,
fits HX8K).  For a Xilinx Artix-7 the full 640×480 framebuffer fits in
the on-chip block RAM directly.

---

## Simulation

```bash
# Check Q4.27 accuracy and generate reference PPM images.
python3 sim/verify_fp.py --check-fp --fp-image

# Compile all VHDL sources with GHDL.
ghdl -a --std=08 rtl/vga_pkg.vhd rtl/fp_mul.vhd rtl/mandelbrot_iter.vhd \
     rtl/mandelbrot_engine.vhd rtl/framebuffer.vhd rtl/colour_map.vhd \
     rtl/vga_sync.vhd rtl/synth_top.vhd sim/tb_mandelbrot.vhd

# Elaborate and run.
ghdl -e --std=08 tb_mandelbrot
ghdl -r --std=08 tb_mandelbrot --vcd=tb.vcd --stop-time=50ms

# The testbench writes mandelbrot.ppm — open in any image viewer.
# View waveforms.
gtkwave tb.vcd
```

---

## Results

| Metric | Value |
|---|---|
| Resolution | 640 × 480 pixels |
| Pixel clock | 25 MHz |
| Frame rate | 59.5 Hz (VGA scan) |
| Computation time per frame | ~2.4 s at 25 MHz, MAX_ITER = 64 |
| Fixed-point format | Q4.27 (32-bit signed, 27 fractional bits) |
| Iteration pipeline depth | 3 clock cycles |
| Max iterations per pixel | 64 (configurable in vga_pkg.vhd) |
| Colour palette | 8 colours (3-bit RGB, 1 bit per channel) |
| Fixed-point accuracy vs float | ≤ ±2 iterations at border pixels |
| Block RAM required | 2.15 Mbit (full 640×480) |
