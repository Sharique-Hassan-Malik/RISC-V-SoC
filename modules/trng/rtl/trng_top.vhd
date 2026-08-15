-- trng_top.vhd  True Random Number Generator top level.
--
-- Target: Lattice iCEstick (iCE40HX1K-TQ144), 12 MHz on-board oscillator.
--
-- Data flow:
--   ring_osc (8 ring oscillators, sampled at 12 MHz)
--       │ raw_bit (1 bit per clock)
--       ▼
--   von_neumann (pairs of bits, discards equal pairs)
--       │ decorrelated bit (~0.49 bits per raw bit)
--       ▼
--   aes_whitener (accumulates 128 bits, applies AES-128 with zero key)
--       │ 128-bit whitened block (every ~260 bits of raw input)
--       ▼
--   uart_out (16 bytes at 115200 baud, MSByte first)
--       │
--   UART TX pin → USB-serial adapter → host
--
-- On the host, read the serial stream and pipe to the NIST test suite:
--   python3 tools/collect.py /dev/ttyUSB0 | python3 tools/nist_sts.py
--
-- LEDs (active low on iCEstick):
--   LED0: blinks every time a 128-bit block is output (~every 5 ms)
--   LED1: on while ring oscillator is running (always on after reset)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity trng_top is
    port (
        clk     : in  std_logic;   -- 12 MHz iCEstick oscillator
        rst_n   : in  std_logic;   -- active-low reset (pin 47)
        uart_tx : out std_logic;   -- UART TX output (pin 61 / J2-1)
        led0    : out std_logic;   -- block output indicator
        led1    : out std_logic    -- activity indicator
    );
end entity trng_top;

architecture rtl of trng_top is

    signal rst         : std_logic;

    -- Ring oscillator
    signal raw_bit     : std_logic;

    -- Von Neumann filter
    signal vn_valid    : std_logic;
    signal vn_bit      : std_logic;

    -- AES whitener
    signal white_valid : std_logic;
    signal white_data  : std_logic_vector(127 downto 0);

    -- UART
    signal uart_busy   : std_logic;

    -- LED blink counter
    signal blink_cnt   : unsigned(23 downto 0) := (others => '0');

    component ring_osc is
        generic (NFREE : integer := 8; NSTAGES : integer := 7);
        port (clk_sys : in std_logic; rst : in std_logic; raw_bit : out std_logic);
    end component;

    component von_neumann is
        port (clk : in std_logic; rst : in std_logic;
              in_valid : in std_logic; in_bit : in std_logic;
              out_valid : out std_logic; out_bit : out std_logic);
    end component;

    component aes_whitener is
        port (clk : in std_logic; rst : in std_logic;
              in_valid : in std_logic; in_bit : in std_logic;
              out_valid : out std_logic; out_data : out std_logic_vector(127 downto 0));
    end component;

    component uart_out is
        generic (CLK_HZ : integer := 12_000_000; BAUD : integer := 115_200);
        port (clk : in std_logic; rst : in std_logic;
              in_valid : in std_logic; in_data : in std_logic_vector(127 downto 0);
              tx : out std_logic; busy : out std_logic);
    end component;

begin

    rst <= not rst_n;

    -- ---- Ring oscillator ------------------------------------------------
    u_ring : ring_osc
        generic map (NFREE => 8, NSTAGES => 7)
        port map (clk_sys => clk, rst => rst, raw_bit => raw_bit);

    -- ---- Von Neumann decorrelator ---------------------------------------
    -- raw_bit is valid every clock cycle (in_valid permanently high).
    u_vn : von_neumann
        port map (clk => clk, rst => rst,
                  in_valid => '1', in_bit => raw_bit,
                  out_valid => vn_valid, out_bit => vn_bit);

    -- ---- AES whitener ---------------------------------------------------
    u_white : aes_whitener
        port map (clk => clk, rst => rst,
                  in_valid => vn_valid, in_bit => vn_bit,
                  out_valid => white_valid, out_data => white_data);

    -- ---- UART output ----------------------------------------------------
    u_uart : uart_out
        generic map (CLK_HZ => 12_000_000, BAUD => 115_200)
        port map (clk => clk, rst => rst,
                  in_valid => white_valid, in_data => white_data,
                  tx => uart_tx, busy => uart_busy);

    -- ---- LED blink counter ----------------------------------------------
    process (clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                blink_cnt <= (others => '0');
            elsif white_valid = '1' then
                blink_cnt <= (others => '1');
            elsif blink_cnt /= 0 then
                blink_cnt <= blink_cnt - 1;
            end if;
        end if;
    end process;

    led0 <= not blink_cnt(23);   -- on for ~0.7 s after each block
    led1 <= not '1';             -- always on (ring oscillator running)

end architecture rtl;
