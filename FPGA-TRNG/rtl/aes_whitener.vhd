-- aes_whitener.vhd  AES-128 cryptographic whitener for TRNG output.
--
-- Accumulates decorrelated bits from the Von Neumann filter into a 128-bit
-- block.  Once 128 bits have been collected, applies one AES-128 encryption
-- (CBC mode with a fixed IV) using a constant all-zeros key, then makes the
-- 128-bit ciphertext available as whitened output.
--
-- "Whitening" in this context means applying a deterministic bijection to
-- compress remaining bias and short-range correlations in the raw bits.
-- The AES operation is not a secret; its value is that it spreads any
-- remaining bias uniformly across all output bits.  The entropy of the
-- output cannot exceed the entropy of the input; we rely on the ring
-- oscillator jitter for the actual entropy source.
--
-- AES implementation: iterative, one round per clock cycle.
-- Key schedule for all-zeros key is pre-computed and stored as constants.
-- 10 rounds + initial key XOR = 11 cycles active + accumulation time.
--
-- Ports:
--   clk          System clock
--   rst          Synchronous reset
--   in_valid     Pulse with each decorrelated bit
--   in_bit       Decorrelated input bit
--   out_valid    High for one cycle when 128 output bits are ready
--   out_data     128-bit whitened output (valid when out_valid = '1')

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aes_whitener is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        in_valid  : in  std_logic;
        in_bit    : in  std_logic;
        out_valid : out std_logic;
        out_data  : out std_logic_vector(127 downto 0)
    );
end entity aes_whitener;

architecture rtl of aes_whitener is

    -- ---- AES state and key schedule constants ---------------------------
    -- Key = 0x0000...00 (128 bits).
    -- Full round keys pre-computed for the zero key.
    -- rk(i) = round key for round i  (AES-128, 10 rounds).
    -- This avoids implementing the key schedule in hardware.
    type rk_array_t is array(0 to 10) of std_logic_vector(127 downto 0);

    constant RK : rk_array_t := (
        x"00000000000000000000000000000000",  -- RK0 (original key)
        x"62636363626363636263636362636363",  -- RK1
        x"9b9898c9f9fbfbaa9b9898c9f9fbfbaa",  -- RK2
        x"90973450696ccffaf2f457330b0fac99",  -- RK3
        x"ee06da7b876a1581759e42b27e91ee2b",  -- RK4
        x"7f2e2b88f8443e098dda7cbbf34b9290",  -- RK5
        x"ec614b851425758c99ff09376ab49ba7",  -- RK6
        x"217517873550620bacaf6b3cc61bf09b",  -- RK7
        x"0ef903333ba9613897060a04511dfa9f",  -- RK8
        x"b1d4d8e28a7db9da1d7bb3de4c664941",  -- RK9
        x"b4ef5bcb3e92e21123e951cf6f8f188e"   -- RK10
    );

    -- S-box component
    component aes_sbox is
        port (
            addr : in  std_logic_vector(7 downto 0);
            dout : out std_logic_vector(7 downto 0)
        );
    end component aes_sbox;

    -- ---- Accumulation registers -----------------------------------------
    signal accum      : std_logic_vector(127 downto 0) := (others => '0');
    signal accum_cnt  : unsigned(6 downto 0) := (others => '0');  -- 0..127
    signal block_ready : std_logic := '0';

    -- ---- AES pipeline state ---------------------------------------------
    signal aes_state  : std_logic_vector(127 downto 0) := (others => '0');
    signal aes_round  : unsigned(3 downto 0) := (others => '0');
    signal aes_active : std_logic := '0';

    -- ---- SubBytes / ShiftRows arrays ------------------------------------
    -- We process the 16 bytes combinationally for each round.
    type byte16_t is array(0 to 15) of std_logic_vector(7 downto 0);

    signal sb_in  : byte16_t;
    signal sb_out : byte16_t;

    -- ---- MixColumns GF(2^8) multiply ------------------------------------
    function gf_mul2(b : std_logic_vector(7 downto 0))
             return std_logic_vector is
        variable r : std_logic_vector(7 downto 0);
    begin
        r := b(6 downto 0) & '0';
        if b(7) = '1' then
            r := r xor x"1b";
        end if;
        return r;
    end function;

    function gf_mul3(b : std_logic_vector(7 downto 0))
             return std_logic_vector is
    begin
        return gf_mul2(b) xor b;
    end function;

    -- ---- After-SubBytes ShiftRows result --------------------------------
    -- AES ShiftRows shifts row i left by i bytes.
    -- In a 128-bit flat representation with byte 0 = MSByte:
    --   Row 0: bytes 0,4,8,12   (no shift)
    --   Row 1: bytes 1,5,9,13   (shift left 1: 5,9,13,1)
    --   Row 2: bytes 2,6,10,14  (shift left 2: 10,14,2,6)
    --   Row 3: bytes 3,7,11,15  (shift left 3: 15,3,7,11)

    function shift_rows(b : byte16_t) return byte16_t is
        variable r : byte16_t;
    begin
        -- Row 0: no shift
        r(0)  := b(0);  r(4)  := b(4);  r(8)  := b(8);  r(12) := b(12);
        -- Row 1: shift left 1
        r(1)  := b(5);  r(5)  := b(9);  r(9)  := b(13); r(13) := b(1);
        -- Row 2: shift left 2
        r(2)  := b(10); r(6)  := b(14); r(10) := b(2);  r(14) := b(6);
        -- Row 3: shift left 3
        r(3)  := b(15); r(7)  := b(3);  r(11) := b(7);  r(15) := b(11);
        return r;
    end function;

    -- ---- MixColumns for one 4-byte column --------------------------------
    function mix_col(c : byte16_t; col : integer) return byte16_t is
        variable r  : byte16_t;
        variable b0, b1, b2, b3 : std_logic_vector(7 downto 0);
    begin
        r  := c;
        b0 := c(col*4);
        b1 := c(col*4+1);
        b2 := c(col*4+2);
        b3 := c(col*4+3);
        r(col*4)   := gf_mul2(b0) xor gf_mul3(b1) xor b2            xor b3;
        r(col*4+1) := b0           xor gf_mul2(b1) xor gf_mul3(b2) xor b3;
        r(col*4+2) := b0           xor b1           xor gf_mul2(b2) xor gf_mul3(b3);
        r(col*4+3) := gf_mul3(b0) xor b1           xor b2           xor gf_mul2(b3);
        return r;
    end function;

    signal sr_result  : byte16_t;
    signal mc_result  : byte16_t;
    signal round_out  : std_logic_vector(127 downto 0);

begin

    -- ---- 16 S-box instances (parallel SubBytes) -------------------------
    GEN_SBOX: for i in 0 to 15 generate
        sb_in(i) <= aes_state(127 - i*8 downto 120 - i*8);
        u_sb : aes_sbox
            port map (addr => sb_in(i), dout => sb_out(i));
    end generate;

    -- ---- ShiftRows (combinational) -------------------------------------
    sr_result <= shift_rows(sb_out);

    -- ---- MixColumns (combinational, 4 columns) -------------------------
    process (sr_result) is
        variable m : byte16_t;
    begin
        m := sr_result;
        m := mix_col(m, 0);
        m := mix_col(m, 1);
        m := mix_col(m, 2);
        m := mix_col(m, 3);
        mc_result <= m;
    end process;

    -- Flatten mc_result back to std_logic_vector
    process (mc_result) is
    begin
        for i in 0 to 15 loop
            round_out(127-i*8 downto 120-i*8) <= mc_result(i);
        end loop;
    end process;

    -- ---- Bit accumulator ------------------------------------------------
    process (clk) is
    begin
        if rising_edge(clk) then
            block_ready <= '0';
            if rst = '1' then
                accum     <= (others => '0');
                accum_cnt <= (others => '0');
            elsif in_valid = '1' and aes_active = '0' then
                accum     <= accum(126 downto 0) & in_bit;
                if accum_cnt = 127 then
                    accum_cnt  <= (others => '0');
                    block_ready <= '1';
                else
                    accum_cnt <= accum_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- ---- AES round engine -----------------------------------------------
    process (clk) is
        variable rk_v : std_logic_vector(127 downto 0);
    begin
        if rising_edge(clk) then
            out_valid <= '0';

            if rst = '1' then
                aes_active <= '0';
                aes_round  <= (others => '0');
                aes_state  <= (others => '0');

            elsif block_ready = '1' then
                -- Initial key XOR (AddRoundKey round 0)
                aes_state  <= accum xor RK(0);
                aes_round  <= to_unsigned(1, 4);
                aes_active <= '1';

            elsif aes_active = '1' then
                rk_v := RK(to_integer(aes_round));

                if aes_round = 10 then
                    -- Final round: SubBytes + ShiftRows + AddRoundKey (no MixColumns)
                    -- sr_result is combinationally updated from aes_state
                    for i in 0 to 15 loop
                        aes_state(127-i*8 downto 120-i*8) <=
                            sr_result(i) xor rk_v(127-i*8 downto 120-i*8);
                    end loop;
                    aes_active <= '0';
                    out_valid  <= '1';
                else
                    -- Normal round: SubBytes + ShiftRows + MixColumns + AddRoundKey
                    aes_state  <= round_out xor rk_v;
                    aes_round  <= aes_round + 1;
                end if;
            end if;
        end if;
    end process;

    out_data <= aes_state;

end architecture rtl;
