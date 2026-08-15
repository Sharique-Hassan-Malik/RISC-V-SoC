-- mandelbrot_iter.vhd  Single-pixel pipelined Mandelbrot iterator.
--
-- Computes one iteration of z -> z2 + c using Q4.27 fixed-point arithmetic:
--
--   z_re_next = z_re2 − z_im2 + c_re
--   z_im_next = 2 x z_re x z_im + c_im
--
-- The three multiplications (z_re2, z_im2, z_rexz_im) are pipelined through
-- fp_mul instances.  Each fp_mul has a 2-cycle latency, so this module
-- has a total pipeline depth of 3 clock cycles (multiply + add + register).
--
-- Escape test: |z|2 > 4.0 is performed on the pipelined magnitude estimate
-- and sets the `escaped` output one cycle after the adds complete.
--
-- The caller must account for the 3-cycle pipeline depth when chaining
-- iterations or reading the `escaped` signal.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vga_pkg.all;

entity mandelbrot_iter is
    port (
        clk       : in  std_logic;
        -- Inputs: current z and constant c (all Q4.27)
        z_re_in   : in  signed(31 downto 0);
        z_im_in   : in  signed(31 downto 0);
        c_re_in   : in  signed(31 downto 0);
        c_im_in   : in  signed(31 downto 0);
        -- Outputs (3-cycle latency)
        z_re_out  : out signed(31 downto 0);
        z_im_out  : out signed(31 downto 0);
        escaped   : out std_logic   -- '1' when |z|2 > 4
    );
end entity mandelbrot_iter;

architecture rtl of mandelbrot_iter is

    -- fp_mul outputs (2-cycle latency from inputs)
    signal zre_sq   : signed(31 downto 0);  -- z_re2
    signal zim_sq   : signed(31 downto 0);  -- z_im2
    signal zre_zim  : signed(31 downto 0);  -- z_re x z_im

    -- Stage 1 pipeline registers (delay c by 2 cycles to align with mul outputs)
    signal c_re_d2  : signed(31 downto 0) := (others => '0');
    signal c_im_d2  : signed(31 downto 0) := (others => '0');
    signal c_re_d1  : signed(31 downto 0) := (others => '0');
    signal c_im_d1  : signed(31 downto 0) := (others => '0');

    -- Stage 2: adder outputs, registered
    signal z_re_next : signed(31 downto 0) := (others => '0');
    signal z_im_next : signed(31 downto 0) := (others => '0');
    signal mag_sq    : signed(31 downto 0) := (others => '0');

    -- 4.0 in Q4.27 = 4 x 2^27 = 536870912
    constant FOUR_FP : signed(31 downto 0) :=
        to_signed(4 * FP_ONE, 32);

begin

    -- ---- Three parallel multipliers (pipelined) --------------------------

    u_zre_sq : entity work.fp_mul
        port map (clk => clk, a => z_re_in, b => z_re_in, p => zre_sq);

    u_zim_sq : entity work.fp_mul
        port map (clk => clk, a => z_im_in, b => z_im_in, p => zim_sq);

    u_cross : entity work.fp_mul
        port map (clk => clk, a => z_re_in, b => z_im_in, p => zre_zim);

    -- ---- Pipeline delay on c (2 cycles to match multiplier latency) ------

    process (clk) is
    begin
        if rising_edge(clk) then
            c_re_d1 <= c_re_in;
            c_re_d2 <= c_re_d1;
            c_im_d1 <= c_im_in;
            c_im_d2 <= c_im_d1;
        end if;
    end process;

    -- ---- Stage 3: additions (1 cycle) ------------------------------------

    process (clk) is
    begin
        if rising_edge(clk) then
            -- z_re_next = z_re2 - z_im2 + c_re
            z_re_next <= zre_sq - zim_sq + c_re_d2;

            -- z_im_next = 2.z_re.z_im + c_im
            --   (shift left by 1 = multiply by 2, no extra multiplier needed)
            z_im_next <= shift_left(zre_zim, 1) + c_im_d2;

            -- |z|2 estimate = z_re2 + z_im2
            mag_sq    <= zre_sq + zim_sq;
        end if;
    end process;

    -- Escape condition
    escaped  <= '1' when mag_sq >= FOUR_FP else '0';

    z_re_out <= z_re_next;
    z_im_out <= z_im_next;

end architecture rtl;
