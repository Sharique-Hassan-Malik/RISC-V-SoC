-- vga_pkg.vhd  VGA 640x480 @ 60 Hz timing constants.
--
-- Pixel clock: 25.175 MHz  (use 25 MHz for iCE40 on-chip PLL or
--              divide a 50 MHz oscillator by 2).
--
-- Horizontal timing (in pixel clocks):
--   Visible area  : 640
--   Front porch   :  16
--   Sync pulse    :  96
--   Back porch    :  48
--   Total         : 800
--
-- Vertical timing (in lines):
--   Visible area  : 480
--   Front porch   :  10
--   Sync pulse    :   2
--   Back porch    :  33
--   Total         : 525
--
-- Both sync pulses are active-low (negative polarity).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package vga_pkg is

    -- Horizontal
    constant H_VISIBLE   : integer := 640;
    constant H_FP        : integer :=  16;
    constant H_SYNC      : integer :=  96;
    constant H_BP        : integer :=  48;
    constant H_TOTAL     : integer := 800;   -- H_VISIBLE + H_FP + H_SYNC + H_BP

    -- Vertical
    constant V_VISIBLE   : integer := 480;
    constant V_FP        : integer :=  10;
    constant V_SYNC      : integer :=   2;
    constant V_BP        : integer :=  33;
    constant V_TOTAL     : integer := 525;

    -- Sync pulse start/end (pixel clock counts from start of total line)
    constant H_SYNC_START : integer := H_VISIBLE + H_FP;          -- 656
    constant H_SYNC_END   : integer := H_VISIBLE + H_FP + H_SYNC; -- 752
    constant V_SYNC_START : integer := V_VISIBLE + V_FP;          -- 490
    constant V_SYNC_END   : integer := V_VISIBLE + V_FP + V_SYNC; -- 492

    -- Colour depth: 3-bit RGB (1 bit per channel) - no resistor DAC needed.
    -- For more bits add a resistor network on R, G, B outputs.
    constant COLOR_BITS  : integer := 3;   -- {R, G, B}

    -- Fixed-point format for Mandelbrot iteration:
    --   Q4.27 - 4 integer bits, 27 fractional bits, total 32 bits signed.
    --   Range: ±8.0.  Mandelbrot region of interest: [-2.5, 1.0] x [-1.25, 1.25].
    constant FP_FRAC     : integer := 27;
    constant FP_ONE      : integer := 2**FP_FRAC;   -- 1.0 in Q4.27

    -- Maximum iteration count (affects colour depth and computation time).
    constant MAX_ITER    : integer := 64;
    constant ITER_BITS   : integer :=  7;  -- ceil(log2(MAX_ITER+1))

end package vga_pkg;
