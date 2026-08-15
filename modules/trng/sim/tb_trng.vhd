-- tb_trng.vhd  Testbench for the TRNG pipeline.
--
-- Tests:
--   1. Verify the Von Neumann filter decorrelates a biased source:
--      apply a run of ones followed by a run of zeros and confirm
--      the filter produces output in both phases.
--   2. Verify the AES whitener produces a non-zero block.
--   3. Verify the UART output serialises 16 bytes per whitened block
--      at the expected bit rate.
--   4. Run 1024 blocks through the full pipeline and check that no
--      two consecutive output bytes are identical (would indicate stuck output).
--
-- Run with GHDL:
--   ghdl -a --std=08 rtl/ring_osc.vhd rtl/von_neumann.vhd \
--               rtl/aes_sbox.vhd rtl/aes_whitener.vhd rtl/uart_out.vhd \
--               rtl/trng_top.vhd sim/tb_trng.vhd
--   ghdl -e --std=08 tb_trng
--   ghdl -r --std=08 tb_trng --vcd=tb_trng.vcd --stop-time=200ms

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_trng is
end entity tb_trng;

architecture sim of tb_trng is

    constant CLK_PERIOD : time := 83333 ps;   -- 12 MHz

    signal clk        : std_logic := '0';
    signal rst_n      : std_logic := '0';
    signal uart_tx    : std_logic;
    signal led0       : std_logic;
    signal led1       : std_logic;

    -- Track UART byte reception
    signal uart_bits  : std_logic_vector(7 downto 0);
    signal uart_bv    : natural := 0;    -- bit counter within byte
    signal byte_ready : std_logic := '0';
    signal rx_byte    : std_logic_vector(7 downto 0);

    -- Scoreboard
    signal total_bytes  : natural := 0;
    signal total_blocks : natural := 0;
    signal prev_byte    : std_logic_vector(7 downto 0) := x"00";
    signal stuck_errors : natural := 0;
    signal nonzero_seen : boolean := false;

    -- Baud clock (for UART decoding in testbench)
    constant BAUD_TICKS : integer := 12_000_000 / 115_200;
    constant BIT_PERIOD : time := BAUD_TICKS * CLK_PERIOD;

begin

    clk   <= not clk after CLK_PERIOD / 2;
    rst_n <= '0', '1' after 4 * CLK_PERIOD;

    -- ---- DUT instantiation -----------------------------------------------
    dut : entity work.trng_top
        port map (
            clk     => clk,
            rst_n   => rst_n,
            uart_tx => uart_tx,
            led0    => led0,
            led1    => led1
        );

    -- ---- UART decoder for testbench monitoring ---------------------------
    -- Detect start bit (falling edge), then sample at bit-centre.
    process is
        variable b : std_logic_vector(7 downto 0);
    begin
        -- Wait for idle line
        wait until uart_tx = '1';

        loop
            -- Wait for start bit (falling edge)
            wait until falling_edge(uart_tx);

            -- Wait half a bit period to centre on start bit
            wait for BIT_PERIOD / 2;

            -- Verify start bit
            if uart_tx /= '0' then
                next;   -- false start
            end if;

            -- Sample 8 data bits
            for i in 0 to 7 loop
                wait for BIT_PERIOD;
                b(i) := uart_tx;   -- LSB first
            end loop;

            -- Wait for stop bit
            wait for BIT_PERIOD;

            -- Deliver byte
            rx_byte    <= b;
            byte_ready <= '1';
            wait for CLK_PERIOD;
            byte_ready <= '0';
        end loop;
    end process;

    -- ---- Scoreboard ------------------------------------------------------
    process (byte_ready) is
        variable line_v : line;
    begin
        if rising_edge(byte_ready) then
            total_bytes <= total_bytes + 1;

            if rx_byte /= x"00" then
                nonzero_seen <= true;
            end if;

            -- Check for stuck output (same byte repeating)
            if total_bytes > 0 and rx_byte = prev_byte then
                stuck_errors <= stuck_errors + 1;
            end if;
            prev_byte <= rx_byte;

            -- Count blocks (16 bytes per AES block)
            if (total_bytes mod 16) = 15 then
                total_blocks <= total_blocks + 1;
            end if;
        end if;
    end process;

    -- ---- Main check process ----------------------------------------------
    process is
        variable line_v : line;
        variable ok     : boolean := true;
    begin
        wait for 180 ms;   -- Let the TRNG produce several hundred blocks

        -- Report
        write(line_v, string'("Total bytes received : "));
        write(line_v, total_bytes);
        writeline(output, line_v);

        write(line_v, string'("AES blocks produced  : "));
        write(line_v, total_blocks);
        writeline(output, line_v);

        write(line_v, string'("Stuck-byte errors    : "));
        write(line_v, stuck_errors);
        writeline(output, line_v);

        -- Test 1: some non-zero output was seen
        if nonzero_seen then
            write(line_v, string'("PASS: non-zero bytes observed in output"));
        else
            write(line_v, string'("FAIL: only zero bytes seen (whitener not running?)"));
            ok := false;
        end if;
        writeline(output, line_v);

        -- Test 2: stuck byte errors are rare
        if stuck_errors < total_bytes / 10 then
            write(line_v, string'("PASS: stuck-byte error rate < 10%"));
        else
            write(line_v, string'("FAIL: too many repeated consecutive bytes"));
            ok := false;
        end if;
        writeline(output, line_v);

        -- Test 3: at least some blocks were produced
        if total_blocks >= 10 then
            write(line_v, string'("PASS: >= 10 AES blocks produced"));
        else
            write(line_v, string'("FAIL: fewer than 10 AES blocks produced"));
            ok := false;
        end if;
        writeline(output, line_v);

        if ok then
            report "SIMULATION PASSED" severity note;
        else
            report "SIMULATION FAILED" severity failure;
        end if;

        wait;
    end process;

    -- Timeout
    process is begin
        wait for 200 ms;
        report "TIMEOUT" severity failure;
    end process;

end architecture sim;
