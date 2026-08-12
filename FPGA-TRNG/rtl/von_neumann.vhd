-- von_neumann.vhd  Von Neumann decorrelation filter.
--
-- Processes raw bits in pairs.  For each pair:
--   "01" → output '0'   (valid)
--   "10" → output '1'   (valid)
--   "00" → discard      (both same)
--   "11" → discard      (both same)
--
-- This removes first-order bias: if Pr(1) = p ≠ 0.5, the output
-- pairs (01) and (10) are equally likely because they are complementary
-- events, both with probability p(1-p).
--
-- The output rate is approximately 2 × p × (1-p) bits per input bit,
-- which for a slightly biased source (p ≈ 0.55) is still roughly 0.49
-- output bits per input bit.
--
-- This is the first stage of whitening; the AES-based whitener that
-- follows provides cryptographic strength.
--
-- Ports:
--   clk          System clock
--   rst          Synchronous reset
--   in_valid     Pulse each time a new raw bit is available
--   in_bit       The raw bit
--   out_valid    High when an output bit is ready
--   out_bit      The decorrelated output bit

library ieee;
use ieee.std_logic_1164.all;

entity von_neumann is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        in_valid  : in  std_logic;
        in_bit    : in  std_logic;
        out_valid : out std_logic;
        out_bit   : out std_logic
    );
end entity von_neumann;

architecture rtl of von_neumann is

    -- Two-state machine: collect first bit, then second bit.
    type state_t is (S_FIRST, S_SECOND);
    signal state    : state_t   := S_FIRST;
    signal first_b  : std_logic := '0';

begin

    process (clk) is
    begin
        if rising_edge(clk) then
            out_valid <= '0';
            out_bit   <= '0';

            if rst = '1' then
                state   <= S_FIRST;
                first_b <= '0';
            elsif in_valid = '1' then
                case state is
                    when S_FIRST =>
                        first_b <= in_bit;
                        state   <= S_SECOND;

                    when S_SECOND =>
                        state <= S_FIRST;
                        -- Only emit when the two bits differ
                        if first_b /= in_bit then
                            out_valid <= '1';
                            out_bit   <= first_b;   -- first bit is '0' for 01, '1' for 10
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
