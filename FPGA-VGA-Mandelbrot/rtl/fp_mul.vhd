-- fp_mul.vhd  Signed Q4.27 fixed-point multiplier.
--
-- Computes (a x b) with both operands in Q4.27 format (32-bit signed,
-- 27 fractional bits) and returns the result in the same format.
--
-- The full product is 64 bits.  We extract bits [58:27] which correspond
-- to the Q4.27 result:
--
--   Full product bit layout (a x b, both Q4.27):
--   bit 63     sign of 64-bit product
--   bits 62:54 integer part (9 bits - we only keep 4, check overflow)
--   bits 53:27 fractional part that forms the 27-bit fraction of result
--   bits 26:0  sub-fractional (discarded)
--
--   Result = product[58:27]  (sign-extended from bit 58)
--
-- Latency: 2 clock cycles (pipeline register after multiply, before extract).
-- The 2-cycle latency allows the synthesiser to map this to a single
-- iCE40 SB_MAC16 with pipeline registers enabled, or to a Xilinx DSP48.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vga_pkg.all;

entity fp_mul is
    port (
        clk : in  std_logic;
        a   : in  signed(31 downto 0);   -- Q4.27 multiplicand
        b   : in  signed(31 downto 0);   -- Q4.27 multiplier
        p   : out signed(31 downto 0)    -- Q4.27 product (2-cycle latency)
    );
end entity fp_mul;

architecture rtl of fp_mul is

    signal product_r : signed(63 downto 0) := (others => '0');
    signal result_r  : signed(31 downto 0) := (others => '0');

begin

    process (clk) is
    begin
        if rising_edge(clk) then
            -- Stage 1: full 64-bit signed multiply
            product_r <= a * b;
            -- Stage 2: extract Q4.27 result from bits [58:27]
            result_r  <= product_r(58 downto 27);
        end if;
    end process;

    p <= result_r;

end architecture rtl;
