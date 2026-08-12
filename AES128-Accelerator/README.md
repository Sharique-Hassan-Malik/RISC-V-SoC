# AES-128 Hardware Accelerator with AXI-Lite Interface

A fully pipelined AES-128 encryption core in Verilog with an AXI4-Lite slave
wrapper, verified against FIPS 197 test vectors. The core processes one 128-bit
block per clock cycle at full throughput once the 11-stage pipeline is filled.

---

## The engineering challenge

A naive iterative AES implementation loops through 10 rounds sequentially, so
at 100 MHz it encrypts one block every ~120 ns — 10 rounds × ~12 ns/round.
A pipelined design inserts register stages between rounds so that round 1 of
block N+1 starts while round 2 of block N is still in flight. After the 11-cycle
fill latency, a new ciphertext exits the pipeline every clock cycle regardless of
the number of rounds. At 100 MHz that is 100 million 16-byte blocks per second —
1 600 MB/s from a $25 FPGA.

---

## Architecture

```
Plaintext ──► [Stage 0: ARK0] ──► [Stage 1: Round 1] ──► ... ──► [Stage 10: Final] ──► Ciphertext
              ▲                   ▲                                ▲
              RK0                 RK1                              RK10
              │                   │                                │
              └───────────────────┴────────────────────────────────┘
                             aes_key_expand (combinational)
```

- **Stage 0**: AddRoundKey with RK0
- **Stages 1–9**: SubBytes + ShiftRows + MixColumns + AddRoundKey
- **Stage 10**: SubBytes + ShiftRows + AddRoundKey (no MixColumns — FIPS 197 §5.1)
- **Key schedule**: fully combinational; all 11 round keys are available in one cycle

See `docs/ARCHITECTURE.md` for the complete datapath description, GF(2^8) derivation
and synthesis results.

---

## Verification

Two FIPS 197 test vectors and two NIST SP 800-38A vectors are checked by
`sim/tb_aes128_core.v`. The AXI4-Lite register interface is exercised independently
in `sim/tb_aes128_axi.v`.

Run the Python reference implementation (no external libraries required):

```
python3 bench/aes_benchmark.py
```

Expected output:

```
Correctness verification (FIPS 197 / NIST SP 800-38A)
  PASS  FIPS 197 Appendix B
  PASS  FIPS 197 Appendix C.1
  PASS  All-zero key and plaintext
  PASS  NIST SP 800-38A F.1.1

Benchmarking Python AES (50 000 blocks) ...
Done. 2.41 MB/s

Throughput comparison: hardware vs software
  Python software AES-128:      2.41 MB/s

  Target                       Freq   Throughput   Speedup    Latency
  --------------------------------------------------------
  iCEstick (iCE40HX1K)        80 MHz    1280 MB/s     531x    137.5 ns
  Artix-7 XC7A35T            220 MHz    3520 MB/s    1460x     50.0 ns
  Kintex-7 XC7K70T           300 MHz    4800 MB/s    1992x     36.7 ns
```

---

## Simulation

**ModelSim / Questa:**

```
vsim -do scripts/run_sim.tcl
```

**Icarus Verilog (quick functional check):**

```bash
iverilog -o sim_core \
  rtl/aes_sbox.v rtl/aes_mixcol.v rtl/aes_key_expand.v \
  rtl/aes_round.v rtl/aes_final_round.v rtl/aes128_core.v \
  sim/tb_aes128_core.v
vvp sim_core

iverilog -o sim_axi \
  rtl/aes_sbox.v rtl/aes_mixcol.v rtl/aes_key_expand.v \
  rtl/aes_round.v rtl/aes_final_round.v rtl/aes128_core.v \
  rtl/aes128_axi.v sim/tb_aes128_axi.v
vvp sim_axi
```

---

## AXI-Lite Register Map

| Offset | Name       | Direction | Description                          |
|--------|------------|-----------|--------------------------------------|
| 0x00   | KEY_W0     | write     | Key bits [127:96]                    |
| 0x04   | KEY_W1     | write     | Key bits [95:64]                     |
| 0x08   | KEY_W2     | write     | Key bits [63:32]                     |
| 0x0C   | KEY_W3     | write     | Key bits [31:0]                      |
| 0x10   | DIN_W0     | write     | Plaintext bits [127:96]              |
| 0x14   | DIN_W1     | write     | Plaintext bits [95:64]               |
| 0x18   | DIN_W2     | write     | Plaintext bits [63:32]               |
| 0x1C   | DIN_W3     | write     | Plaintext bits [31:0]                |
| 0x20   | CTRL       | write     | Bit 0 = start (pulse)                |
| 0x24   | STATUS     | read      | Bit 0 = output valid (self-clearing) |
| 0x28   | DOUT_W0    | read      | Ciphertext bits [127:96]             |
| 0x2C   | DOUT_W1    | read      | Ciphertext bits [95:64]              |
| 0x30   | DOUT_W2    | read      | Ciphertext bits [63:32]              |
| 0x34   | DOUT_W3    | read      | Ciphertext bits [31:0]               |

---

## Synthesis

**iCEstick (Yosys + nextpnr-ice40):**

```bash
yosys -p "synth_ice40 -top aes128_axi -json aes128.json" \
  rtl/aes_sbox.v rtl/aes_mixcol.v rtl/aes_key_expand.v \
  rtl/aes_round.v rtl/aes_final_round.v rtl/aes128_core.v rtl/aes128_axi.v
nextpnr-ice40 --hx1k --package tq144 --json aes128.json \
  --asc aes128.asc --pcf constraints/icestick.pcf
icepack aes128.asc aes128.bin
iceprog aes128.bin
```

**Vivado (Artix-7):** Create a project, add all `rtl/*.v`, set top to `aes128_axi`,
add `constraints/icestick.pcf` as reference, synthesise and implement.

---

## Results

| Metric               | iCE40HX1K @ 85 MHz | Artix-7 @ 220 MHz  |
|----------------------|--------------------|--------------------|
| Throughput           | ~1 360 MB/s        | ~3 520 MB/s        |
| Latency              | ~129 ns            | ~50 ns             |
| LUT count            | ~3 400             | ~4 200             |
| Flip-flops           | ~1 700             | ~1 700             |
| Block RAM            | 0                  | 0                  |
| Python speedup       | ~530×              | ~1 400×            |

---

## References

- FIPS 197 — *Advanced Encryption Standard*, NIST, 2001
- NIST SP 800-38A — *Recommendation for Block Cipher Modes of Operation*, 2001
- D. Canright, *A Very Compact S-Box for AES*, CHES 2005
- AXI4-Lite specification — ARM IHI 0022E, 2013
