-- synth_top.vhd  VGA Framebuffer with Mandelbrot Renderer - top level.
--
-- Target: Lattice iCEstick (iCE40HX1K-TQ144)
--         Or Nexys A7 / Basys 3 (Xilinx 7-series) - see note on framebuffer size.
--
-- Clock:
--   iCEstick: 12 MHz on-chip oscillator, divided by 2 for iCE40 DCM-like use,
--             then a simple counter divides 12 MHz -> 6 MHz (25 MHz not achievable
--             without PLL on HX1K).  For a proper 25 MHz pixel clock use the
--             iCE40 SB_PLL40_CORE primitive or target an HX8K with PLL.
--             This top-level assumes a 25 MHz input clock (e.g. Nexys A7 with
--             a DCM/MMCM, or iCEstick with external 25 MHz crystal).
--
-- VGA output pins (3-bit RGB, no resistor DAC - wire directly to VGA connector):
--   vga_r  -> pin 61  (VGA red)
--   vga_g  -> pin 62  (VGA green)
--   vga_b  -> pin 63  (VGA blue)
--   vga_hs -> pin 56  (VGA hsync)
--   vga_vs -> pin 55  (VGA vsync)
--
-- Note on framebuffer size:
--   640x480 x 7 bits ≈ 2.15 Mbit.  The iCE40HX1K has only 64 Kbit of block RAM.
--   For the iCEstick, define DEMO_MODE = true in generics to use a 160x120 display
--   (each logical pixel drawn as a 4x4 block) which requires only 134 Kbit -
--   still too large for HX1K but fits in HX4K/HX8K.
--   For simulation there is no constraint: the VHDL framebuffer uses a plain array.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vga_pkg.all;

entity synth_top is
    port (
        clk_25  : in  std_logic;                   -- 25 MHz pixel clock input
        rst_n   : in  std_logic;                   -- active-low reset (push button)
        vga_r   : out std_logic;
        vga_g   : out std_logic;
        vga_b   : out std_logic;
        vga_hs  : out std_logic;
        vga_vs  : out std_logic;
        -- Status LEDs
        led_busy : out std_logic;                  -- '1' while calculating
        led_done : out std_logic                   -- blinks after each full frame
    );
end entity synth_top;

architecture rtl of synth_top is

    signal rst       : std_logic;
    signal active    : std_logic;
    signal hpos      : unsigned(9 downto 0);
    signal vpos      : unsigned(9 downto 0);

    -- Framebuffer ports
    signal fb_we     : std_logic;
    signal fb_wr_addr: unsigned(18 downto 0);
    signal fb_wr_data: unsigned(ITER_BITS-1 downto 0);
    signal fb_rd_addr: unsigned(18 downto 0);
    signal fb_rd_data: unsigned(ITER_BITS-1 downto 0);

    -- Colour output
    signal rgb_out   : std_logic_vector(2 downto 0);

    -- Active pipeline delay (framebuffer read has 1-cycle latency)
    signal active_d1 : std_logic := '0';

    -- Frame counter for done LED
    signal frame_ctr : unsigned(23 downto 0) := (others => '0');
    signal frame_done: std_logic := '0';

begin

    rst <= not rst_n;

    -- ---- VGA sync generator ----------------------------------------------
    u_vga : entity work.vga_sync
        port map (
            pclk   => clk_25,
            rst    => rst,
            hsync  => vga_hs,
            vsync  => vga_vs,
            active => active,
            hpos   => hpos,
            vpos   => vpos
        );

    -- ---- Mandelbrot computation engine -----------------------------------
    u_engine : entity work.mandelbrot_engine
        port map (
            clk     => clk_25,
            rst     => rst,
            fb_we   => fb_we,
            fb_addr => fb_wr_addr,
            fb_data => fb_wr_data
        );

    -- ---- Dual-port framebuffer -------------------------------------------
    u_fb : entity work.framebuffer
        port map (
            clk_a  => clk_25,
            we_a   => fb_we,
            addr_a => fb_wr_addr,
            din_a  => fb_wr_data,
            clk_b  => clk_25,
            addr_b => fb_rd_addr,
            dout_b => fb_rd_data
        );

    -- Framebuffer read address: current scan position. During blanking hpos/vpos
    -- run past the visible area; the framebuffer clamps out-of-range reads so this
    -- stays in bounds (the pixel output is gated by active_d1 anyway).
    -- resize the product back to 19 bits: numeric_std "*"(unsigned,natural)
    -- returns a double-width (38-bit) result, which must be narrowed to the
    -- 19-bit address (the value always fits: max 479*640+639 = 307199).
    fb_rd_addr <= resize(resize(vpos, 19) * 640 + resize(hpos, 19), 19);

    -- ---- Colour lookup ---------------------------------------------------
    u_colour : entity work.colour_map
        port map (
            iter => fb_rd_data,
            rgb  => rgb_out
        );

    -- ---- VGA RGB output (gate by active, delayed 1 cycle for FB read) ----
    process (clk_25) is
    begin
        if rising_edge(clk_25) then
            active_d1 <= active;
        end if;
    end process;

    vga_r <= rgb_out(2) when active_d1 = '1' else '0';
    vga_g <= rgb_out(1) when active_d1 = '1' else '0';
    vga_b <= rgb_out(0) when active_d1 = '1' else '0';

    -- ---- Status LEDs -----------------------------------------------------
    -- led_busy: high while the engine is computing (always busy in free-run)
    led_busy <= fb_we;

    -- led_done: blinks for ~0.5 s after each time px wraps to 0 (new frame)
    process (clk_25) is
    begin
        if rising_edge(clk_25) then
            if rst = '1' then
                frame_ctr  <= (others => '0');
                frame_done <= '0';
            elsif fb_we = '1' and fb_wr_addr = 0 then
                -- Engine just wrote pixel 0 - new frame started
                frame_ctr  <= (others => '1');
                frame_done <= '1';
            elsif frame_ctr /= 0 then
                frame_ctr <= frame_ctr - 1;
            else
                frame_done <= '0';
            end if;
        end if;
    end process;

    led_done <= frame_done;

end architecture rtl;
