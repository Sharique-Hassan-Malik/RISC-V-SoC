-- vga_sync.vhd  VGA horizontal and vertical sync generator.
--
-- Produces pixel-clock-synchronous hsync, vsync, active (blanking gate),
-- and the current visible pixel coordinates (hpos, vpos).
--
-- hpos and vpos are only meaningful when active = '1'.
-- Both sync signals are active-low per the 640x480 @ 60 Hz standard.
--
-- This module drives the framebuffer read address and the RGB output
-- gate simultaneously.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vga_pkg.all;

entity vga_sync is
    port (
        pclk   : in  std_logic;                          -- 25 MHz pixel clock
        rst    : in  std_logic;
        hsync  : out std_logic;
        vsync  : out std_logic;
        active : out std_logic;                          -- '1' in visible region
        hpos   : out unsigned(9 downto 0);               -- 0 .. 639
        vpos   : out unsigned(9 downto 0)                -- 0 .. 479
    );
end entity vga_sync;

architecture rtl of vga_sync is

    signal hcnt : unsigned(9 downto 0) := (others => '0');
    signal vcnt : unsigned(9 downto 0) := (others => '0');

begin

    process (pclk) is
    begin
        if rising_edge(pclk) then
            if rst = '1' then
                hcnt <= (others => '0');
                vcnt <= (others => '0');
            else
                -- Horizontal counter
                if hcnt = H_TOTAL - 1 then
                    hcnt <= (others => '0');
                    -- Vertical counter
                    if vcnt = V_TOTAL - 1 then
                        vcnt <= (others => '0');
                    else
                        vcnt <= vcnt + 1;
                    end if;
                else
                    hcnt <= hcnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- Sync pulses (active low, negative polarity)
    hsync <= '0' when (hcnt >= H_SYNC_START and hcnt < H_SYNC_END) else '1';
    vsync <= '0' when (vcnt >= V_SYNC_START and vcnt < V_SYNC_END) else '1';

    -- Blanking gate
    active <= '1' when (hcnt < H_VISIBLE and vcnt < V_VISIBLE) else '0';

    -- Pixel coordinates (only valid when active = '1')
    hpos <= hcnt(9 downto 0);
    vpos <= vcnt(9 downto 0);

end architecture rtl;
