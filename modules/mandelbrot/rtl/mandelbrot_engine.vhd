-- mandelbrot_engine.vhd  Pixel-by-pixel Mandelbrot set calculator.
--
-- Operates as a background computation engine independent of the VGA scan.
-- Processes pixels in raster order (x from 0 to 639, y from 0 to 479).
-- For each pixel it runs the Mandelbrot iteration loop up to MAX_ITER times.
--
-- The iteration pipeline in mandelbrot_iter has a 3-cycle latency, so
-- the engine re-registers the outputs and checks the escape flag every
-- 3 cycles.  This means one pixel takes up to MAX_ITER x 3 = 192 clock
-- cycles at 25 MHz ≈ 192 / 25e6 = 7.68 µs per pixel.
-- Full frame: 640 x 480 x 7.68 µs ≈ 2.36 s.
-- Subsequent frames recalculate continuously.
--
-- The framebuffer write port is presented as:
--   fb_we    : write enable (one cycle pulse per completed pixel)
--   fb_addr  : pixel address (y x 640 + x), 19-bit (640 x 480 = 307 200)
--   fb_data  : iteration count truncated to ITER_BITS bits
--
-- View window is fixed at:
--   Re: [-2.5, 1.0]   step = 3.5 / 640
--   Im: [-1.25, 1.25] step = 2.5 / 480

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vga_pkg.all;

entity mandelbrot_engine is
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        -- Framebuffer write port
        fb_we    : out std_logic;
        fb_addr  : out unsigned(18 downto 0);   -- 640x480 = 307200 < 2^19
        fb_data  : out unsigned(ITER_BITS-1 downto 0)
    );
end entity mandelbrot_engine;

architecture rtl of mandelbrot_engine is

    -- ---- View window in Q4.27 -------------------------------------------
    -- Re_min = -2.5 x 2^27 = -335544320
    -- Re_step = 3.5/640 x 2^27 ≈ 737280  (= 3.5 x 2^27 / 640)
    -- Im_min = -1.25 x 2^27 = -167772160
    -- Im_step = 2.5/480 x 2^27 ≈ 699051  (= 2.5 x 2^27 / 480)
    constant RE_MIN  : signed(31 downto 0) := to_signed(-335544320, 32);
    constant RE_STEP : signed(31 downto 0) := to_signed(737280,     32);
    constant IM_MIN  : signed(31 downto 0) := to_signed(-167772160, 32);
    constant IM_STEP : signed(31 downto 0) := to_signed(699051,     32);

    -- ---- Pixel counters --------------------------------------------------
    signal px     : unsigned(9 downto 0) := (others => '0');  -- 0..639
    signal py     : unsigned(8 downto 0) := (others => '0');  -- 0..479

    -- ---- c value for current pixel ---------------------------------------
    signal c_re   : signed(31 downto 0) := (others => '0');
    signal c_im   : signed(31 downto 0) := (others => '0');

    -- ---- Iteration state -------------------------------------------------
    signal z_re   : signed(31 downto 0) := (others => '0');
    signal z_im   : signed(31 downto 0) := (others => '0');
    signal iter   : unsigned(ITER_BITS-1 downto 0) := (others => '0');

    -- Pipeline outputs from mandelbrot_iter
    signal z_re_next : signed(31 downto 0);
    signal z_im_next : signed(31 downto 0);
    signal escaped   : std_logic;

    -- Pipeline delay counter: 3 cycles between feeding inputs and reading outputs
    signal pipe_cnt  : unsigned(1 downto 0) := (others => '0');

    -- State machine
    type engine_state_t is (S_LOAD, S_ITERATE, S_WRITE);
    signal state : engine_state_t := S_LOAD;

    -- Framebuffer write registers
    signal fb_we_r   : std_logic := '0';
    signal fb_addr_r : unsigned(18 downto 0) := (others => '0');
    signal fb_data_r : unsigned(ITER_BITS-1 downto 0) := (others => '0');

begin

    -- ---- Mandelbrot iteration pipeline (runs continuously) ---------------
    u_iter : entity work.mandelbrot_iter
        port map (
            clk      => clk,
            z_re_in  => z_re,
            z_im_in  => z_im,
            c_re_in  => c_re,
            c_im_in  => c_im,
            z_re_out => z_re_next,
            z_im_out => z_im_next,
            escaped  => escaped
        );

    -- ---- Main state machine ----------------------------------------------
    process (clk) is
    begin
        if rising_edge(clk) then
            fb_we_r <= '0';

            if rst = '1' then
                state    <= S_LOAD;
                px       <= (others => '0');
                py       <= (others => '0');
                pipe_cnt <= (others => '0');
                iter     <= (others => '0');
                z_re     <= (others => '0');
                z_im     <= (others => '0');
            else
                case state is

                    when S_LOAD =>
                        -- Compute c for current (px, py)
                        -- signed*signed yields a 64-bit product; narrow the
                        -- Q4.27 result back to 32 bits (the value always fits).
                        c_re     <= resize(RE_MIN + signed(resize(px, 32)) * RE_STEP, 32);
                        c_im     <= resize(IM_MIN + signed(resize(py, 32)) * IM_STEP, 32);
                        z_re     <= (others => '0');
                        z_im     <= (others => '0');
                        iter     <= (others => '0');
                        pipe_cnt <= (others => '0');
                        state    <= S_ITERATE;

                    when S_ITERATE =>
                        -- Wait 3 cycles for the pipeline to flush, then check.
                        if pipe_cnt = 2 then
                            pipe_cnt <= (others => '0');

                            if escaped = '1' or iter = MAX_ITER - 1 then
                                -- Pixel done
                                state <= S_WRITE;
                            else
                                -- Accept pipeline output, advance
                                z_re <= z_re_next;
                                z_im <= z_im_next;
                                iter <= iter + 1;
                            end if;
                        else
                            pipe_cnt <= pipe_cnt + 1;
                        end if;

                    when S_WRITE =>
                        -- Write iteration count to framebuffer
                        fb_we_r   <= '1';
                        fb_addr_r <= resize(resize(py, 19) * 640 + resize(px, 19), 19);
                        fb_data_r <= iter;

                        -- Advance to next pixel
                        if px = 639 then
                            px <= (others => '0');
                            if py = 479 then
                                py <= (others => '0');   -- wrap: redraw
                            else
                                py <= py + 1;
                            end if;
                        else
                            px <= px + 1;
                        end if;
                        state <= S_LOAD;

                end case;
            end if;
        end if;
    end process;

    fb_we   <= fb_we_r;
    fb_addr <= fb_addr_r;
    fb_data <= fb_data_r;

end architecture rtl;
