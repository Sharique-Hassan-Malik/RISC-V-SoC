-- uart_out.vhd  Simple 115200-baud UART transmitter for streaming TRNG bytes.
--
-- Accepts 128-bit words from the AES whitener and serialises them as 16
-- individual bytes at 115200 baud (8N1, no parity, 1 stop bit).
-- Each byte is transmitted as soon as the previous byte has finished.
--
-- Clock: 12 MHz (iCEstick on-board oscillator).
--   Baud divisor = 12 000 000 / 115 200 ≈ 104.
--   Error: |104 × 115200 - 12000000| / 12000000 ≈ 0% (104 × 115200 = 11980800,
--   actual baud rate = 12000000/104 ≈ 115384, error = 0.16%).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_out is
    generic (
        CLK_HZ : integer := 12_000_000;
        BAUD   : integer := 115_200
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        -- Input: 128-bit word from whitener
        in_valid  : in  std_logic;
        in_data   : in  std_logic_vector(127 downto 0);
        -- UART serial output
        tx        : out std_logic;
        -- Busy: high while transmitting a word
        busy      : out std_logic
    );
end entity uart_out;

architecture rtl of uart_out is

    constant BIT_TICKS : integer := CLK_HZ / BAUD;

    -- ---- Byte shift register (holds one 128-bit word, shifts out bytes) --
    signal word_reg   : std_logic_vector(127 downto 0) := (others => '0');
    signal byte_idx   : unsigned(3 downto 0) := (others => '0');  -- 0..15

    -- ---- UART single-byte transmitter -----------------------------------
    type tx_state_t is (S_IDLE, S_START, S_DATA, S_STOP, S_NEXT_BYTE);
    signal tx_state   : tx_state_t := S_IDLE;

    signal baud_cnt   : unsigned(9 downto 0) := (others => '0');
    signal bit_cnt    : unsigned(2 downto 0) := (others => '0');
    signal shift_reg  : std_logic_vector(7 downto 0) := (others => '1');
    signal word_busy  : std_logic := '0';

    signal baud_tick  : std_logic;

begin

    baud_tick <= '1' when baud_cnt = 0 else '0';

    process (clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx        <= '1';
                baud_cnt  <= (others => '0');
                bit_cnt   <= (others => '0');
                byte_idx  <= (others => '0');
                tx_state  <= S_IDLE;
                word_busy <= '0';
            else

                -- Baud counter
                if baud_tick = '1' then
                    baud_cnt <= to_unsigned(BIT_TICKS - 1, 10);
                else
                    baud_cnt <= baud_cnt - 1;
                end if;

                -- Capture new word when idle
                if in_valid = '1' and word_busy = '0' then
                    word_reg  <= in_data;
                    byte_idx  <= (others => '0');
                    word_busy <= '1';
                end if;

                case tx_state is
                    when S_IDLE =>
                        tx <= '1';
                        if word_busy = '1' then
                            -- Load MSByte (byte 15 = word_reg[127:120])
                            shift_reg <= word_reg(127 downto 120);
                            baud_cnt  <= to_unsigned(BIT_TICKS - 1, 10);
                            tx_state  <= S_START;
                        end if;

                    when S_START =>
                        if baud_tick = '1' then
                            tx       <= '0';      -- start bit
                            bit_cnt  <= (others => '0');
                            tx_state <= S_DATA;
                        end if;

                    when S_DATA =>
                        if baud_tick = '1' then
                            tx        <= shift_reg(0);
                            shift_reg <= '1' & shift_reg(7 downto 1);   -- LSB first
                            if bit_cnt = 7 then
                                tx_state <= S_STOP;
                            else
                                bit_cnt <= bit_cnt + 1;
                            end if;
                        end if;

                    when S_STOP =>
                        if baud_tick = '1' then
                            tx       <= '1';      -- stop bit
                            tx_state <= S_NEXT_BYTE;
                        end if;

                    when S_NEXT_BYTE =>
                        if baud_tick = '1' then
                            if byte_idx = 15 then
                                -- All 16 bytes transmitted
                                word_busy <= '0';
                                tx_state  <= S_IDLE;
                            else
                                byte_idx <= byte_idx + 1;
                                -- Next byte: shift word left by 8 to bring next byte into [127:120]
                                word_reg <= word_reg(119 downto 0) & x"00";
                                shift_reg <= word_reg(119 downto 112);
                                tx_state  <= S_START;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process;

    busy <= word_busy;

end architecture rtl;
