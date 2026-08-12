-- framebuffer.vhd  Dual-port framebuffer using block RAM.
--
-- Port A: write  (from Mandelbrot engine, synchronous write)
-- Port B: read   (from VGA scan, synchronous read - outputs pixel colour)
--
-- Stores one byte per pixel: the iteration count (ITER_BITS wide).
-- Resolution: 640 x 480 = 307 200 pixels.
-- Storage: 307 200 x 7 bits ≈ 2.15 Mbit.
--
-- iCE40HX4K has 20 x 4 Kbit BRAMs = 80 Kbit - nowhere near enough.
-- iCE40HX8K has 32 x 4 Kbit BRAMs = 128 Kbit - still not enough.
--
-- On real hardware use a device with sufficient embedded memory or an
-- external SRAM/SDRAM.  For simulation and Xilinx targets (which have
-- much larger block RAM budgets), this VHDL synthesises directly.
--
-- For the iCEstick proof-of-concept, reduce resolution to 160x120 and
-- use 4 pixels per displayed pixel (see synth_top.vhd option).
--
-- The entity is generic on DATA_BITS and DEPTH so it can be scaled.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vga_pkg.all;

entity framebuffer is
    generic (
        DATA_BITS : integer := ITER_BITS;       -- bits per pixel
        DEPTH     : integer := 640 * 480         -- number of pixels
    );
    port (
        -- Port A: write (Mandelbrot engine clock domain - same clock)
        clk_a  : in  std_logic;
        we_a   : in  std_logic;
        addr_a : in  unsigned(18 downto 0);
        din_a  : in  unsigned(DATA_BITS-1 downto 0);

        -- Port B: read (VGA scan - same clock)
        clk_b  : in  std_logic;
        addr_b : in  unsigned(18 downto 0);
        dout_b : out unsigned(DATA_BITS-1 downto 0)
    );
end entity framebuffer;

architecture rtl of framebuffer is

    -- Inferred block RAM (true dual-port read-first).
    type ram_t is array(0 to DEPTH-1) of unsigned(DATA_BITS-1 downto 0);
    -- A plain signal (single writer on port A) keeps this VHDL-2008 compliant;
    -- a non-protected shared variable is illegal under the 2008 standard.
    signal ram : ram_t := (others => (others => '0'));

begin

    -- Port A: synchronous write
    process (clk_a) is
    begin
        if rising_edge(clk_a) then
            if we_a = '1' then
                ram(to_integer(addr_a)) <= din_a;
            end if;
        end if;
    end process;

    -- Port B: synchronous read. The scan-out address runs past DEPTH during
    -- blanking; a real block RAM simply returns undefined data there, so clamp
    -- the index to keep the simulation in bounds (output is gated downstream).
    process (clk_b) is
    begin
        if rising_edge(clk_b) then
            if to_integer(addr_b) < DEPTH then
                dout_b <= ram(to_integer(addr_b));
            end if;
        end if;
    end process;

end architecture rtl;
