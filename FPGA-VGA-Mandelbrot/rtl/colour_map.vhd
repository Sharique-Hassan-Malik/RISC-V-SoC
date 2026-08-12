-- colour_map.vhd  Iteration-count to 3-bit RGB colour palette.
--
-- Maps a ITER_BITS-wide iteration count to a 3-bit RGB colour (1 bit per
-- channel: {R, G, B}).  The Mandelbrot set interior (max iteration reached)
-- maps to black; exterior pixels cycle through a simple colour sequence.
--
-- With 3-bit RGB (8 colours) and MAX_ITER = 64:
--   iter mod 7 -> colour index (skip black for non-set pixels)
--   iter = MAX_ITER -> black (set interior)
--
-- For richer colour replace with a wider palette ROM (e.g. 8-bit -> 24-bit
-- RGB with an external resistor DAC).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vga_pkg.all;

entity colour_map is
    port (
        iter  : in  unsigned(ITER_BITS-1 downto 0);
        rgb   : out std_logic_vector(2 downto 0)   -- {R, G, B}
    );
end entity colour_map;

architecture rtl of colour_map is
begin

    process (iter) is
        variable idx : unsigned(2 downto 0);
    begin
        if iter >= MAX_ITER then
            -- Interior of the Mandelbrot set: black
            rgb <= "000";
        else
            -- Exterior: cycle through 7 non-black colours using iter mod 7.
            -- Implemented as a case statement to avoid a divide operation.
            -- iter is truncated to 3 bits for the modulo pattern:
            -- 0->1 1->2 2->3 3->4 4->5 5->6 6->7 7->1 (wraps, skips 0=black)
            idx := resize(iter, 3);   -- take low 3 bits (= iter mod 8)
            case idx is
                when "001"  => rgb <= "001";   -- blue
                when "010"  => rgb <= "010";   -- green
                when "011"  => rgb <= "011";   -- cyan
                when "100"  => rgb <= "100";   -- red
                when "101"  => rgb <= "101";   -- magenta
                when "110"  => rgb <= "110";   -- yellow
                when "111"  => rgb <= "111";   -- white
                when others => rgb <= "001";   -- 000 maps to blue (avoid black)
            end case;
        end if;
    end process;

end architecture rtl;
