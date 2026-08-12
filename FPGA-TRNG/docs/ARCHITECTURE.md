# Architecture

## Overview

A hardware True Random Number Generator (TRNG) for the Lattice iCEstick
(iCE40HX1K) that harvests entropy from ring-oscillator jitter, decorrelates
the raw bits with a Von Neumann filter, applies AES-128 cryptographic
whitening and streams the output at 115 200 baud over UART.  The accompanying
Python tool implements nine NIST SP 800-22 statistical tests to verify the
output quality offline.

---

## Data Flow

```
iCE40 fabric ring oscillators (8 independent chains, 7 stages each)
    │  raw jitter-sampled bit, one per 12 MHz clock cycle
    ▼
Von Neumann decorrelation filter
    │  decorrelated bit (~0.49 bits out per 2 raw bits in)
    │  output rate: ~6 Mbit/s
    ▼
128-bit accumulator
    │  full block every ~261 decorrelated bits (~43 µs at 12 MHz)
    ▼
AES-128 whitener (iterative, one round per clock cycle, zero key)
    │  128-bit whitened block (~11 clock cycles = ~0.9 µs)
    ▼
UART serialiser (16 bytes, LSB-first, 115200 baud)
    │  ~1.4 ms per 16-byte block
    ▼
USB-serial adapter → host PC → nist_sts.py
```

Throughput: ≈ 16 bytes / 1.4 ms ≈ **11 400 bytes/second** (91 kbit/s),
limited by the UART baud rate.

---

## Module Descriptions

### `ring_osc.vhd` — Entropy source

Eight independent free-running ring oscillators, each a chain of 7 inverters
(odd count ensures oscillation).  On real iCE40 hardware each ring oscillates
at a slightly different frequency (typically 200–600 MHz) due to process and
temperature variation.  The system clock samples each ring output, and
all eight samples are XOR'd together.

**Why XOR?**  XOR of N independent oscillators accumulates jitter from all
sources.  If each ring has standard deviation σ_i of jitter then the combined
jitter is approximately √(Σσ_i²).  More rings = more entropy per sample.

**Simulation note:**  In RTL simulation a 32-bit maximal LFSR replaces the
ring oscillators.  The LFSR produces a deterministic but statistically useful
sequence for verifying downstream stages.  On real hardware the physical
oscillator jitter is the actual entropy source.

**Synthesis note:**  Ring oscillators must be protected from optimisation.
On iCE40 each inverter should be mapped to an `SB_LUT4` with all inputs tied
to '1' and the carry chain disabled.  The provided `ring_osc.vhd` uses a
portable VHDL model; for production, create a Verilog wrapper using
`SB_LUT4` primitives with the `LOCK_BITS` attribute set.

### `von_neumann.vhd` — Decorrelation filter

Processes raw bits in pairs (b₀, b₁):

```
b₀=0, b₁=1  →  emit 0  (probability: (1-p)×p)
b₀=1, b₁=0  →  emit 1  (probability: p×(1-p))
b₀=0, b₁=0  →  discard (probability: (1-p)²)
b₀=1, b₁=1  →  discard (probability: p²)
```

For a biased source with Pr(1) = p, the emitted pairs (0,1) and (1,0) have
**equal probability** p(1-p).  This removes first-order bias regardless of p.
The output rate is 2p(1-p) bits per input bit; for p = 0.55 this is ≈ 0.495.

### `aes_whitener.vhd` — Cryptographic whitening

Accumulates 128 decorrelated bits, then runs one AES-128 encryption.
The key is fixed at all-zeros and is not secret; the purpose is to spread
any remaining bias uniformly across all 128 output bits.

**Why AES with a zero key?**  Simplicity and well-understood properties.
The AES round function acts as a near-ideal mixing function.  The whitening
is NOT a cryptographic construction (the key is public); it is a post-processing
step to improve statistical properties.  The entropy of the output is bounded
by the entropy of the 128-bit input — AES cannot create entropy.

**Key schedule:**  The full AES-128 round keys for the zero key are pre-computed
and stored as 11 × 128-bit constants.  This avoids implementing the Rijndael
key schedule in hardware.

**AES implementation:**  Iterative, one round per clock cycle.
16 S-box instances run in parallel (SubBytes + ShiftRows in the same cycle).
MixColumns is computed combinationally with GF(2⁸) multiply-by-2 and
multiply-by-3.  The final round skips MixColumns per the AES specification.
Total: 10 active cycles + accumulation time.

### `uart_out.vhd` — UART serialiser

Takes each 128-bit whitened block and transmits it as 16 bytes, MSByte first,
at 115200 baud (8N1).  The baud divisor for a 12 MHz clock is 104.
One 16-byte block takes 16 × 10 bits / 115200 baud ≈ 1.39 ms to transmit.

---

## NIST SP 800-22 Test Suite (nist_sts.py)

The Python tool implements 9 of the 15 SP 800-22 Rev. 1a tests:

| Test | What it checks |
|---|---|
| Frequency (Monobit) | Overall proportion of 1s vs 0s |
| Block Frequency | Local proportion within 128-bit blocks |
| Runs | Alternation rate of runs of identical bits |
| Longest Run | Distribution of the longest run of 1s |
| Binary Matrix Rank | Linear independence of 32×32 bit matrices |
| Non-overlapping Template | Occurrence count of a specific 10-bit pattern |
| Serial | Frequency of overlapping m-bit patterns |
| Approximate Entropy | Regularity of overlapping m and m+1 bit patterns |
| Cumulative Sums | Maximum deviation of partial sums |

Each test computes a p-value.  A p-value ≥ 0.01 means the sequence is
statistically consistent with a random source at the 1% significance level.

**Expected results for a good TRNG:**  All 9 tests should PASS with p-values
distributed roughly uniformly across [0, 1].  A p-value consistently near 0
or near 1 indicates a defect in the entropy source or whitener.

**Reference calibration:**  Running the suite against `/dev/urandom` (`--urandom`)
establishes a baseline.  A correctly functioning TRNG should produce similar
results.

---

## Hardware Schematic

```
iCEstick (iCE40HX1K)
────────────────────────────────────
8 ring oscillators (in fabric, SB_LUT4 chains)
    XOR → sample at 12 MHz
                │
        von_neumann filter
                │
        aes_whitener (128-bit blocks)
                │
        uart_out (115200 baud)
                │
        Pin 61 (J2-1) → USB-serial adapter RX
        GND            → USB-serial adapter GND
```

---

## Throughput and Entropy Rate

Assuming all ring oscillator bits are independent (conservative estimate):
- Ring oscillator sample rate: 12 MHz
- Von Neumann output rate: ~6 Mbit/s (≈50% efficiency)
- AES block rate: 6 Mbit/s / 128 bits ≈ 46 875 blocks/s
- UART transmission rate: 1 block / 1.39 ms ≈ 720 blocks/s
- UART byte rate: 720 × 16 ≈ 11 500 bytes/s = 92 kbit/s

The UART is the bottleneck.  The raw entropy generation rate (~6 Mbit/s)
far exceeds the output rate; the AES whitener acts as a rate-adapter.

---

## Simulation

```bash
ghdl -a --std=08 \
    rtl/ring_osc.vhd rtl/von_neumann.vhd rtl/aes_sbox.vhd \
    rtl/aes_whitener.vhd rtl/uart_out.vhd rtl/trng_top.vhd \
    sim/tb_trng.vhd
ghdl -e --std=08 tb_trng
ghdl -r --std=08 tb_trng --vcd=tb_trng.vcd --stop-time=200ms
gtkwave tb_trng.vcd
```

---

## Building for Hardware

```bash
# Requires ghdl-yosys-plugin for VHDL synthesis with Yosys.
yosys -m ghdl -p "
    ghdl --std=08 rtl/ring_osc.vhd rtl/von_neumann.vhd \
                   rtl/aes_sbox.vhd rtl/aes_whitener.vhd \
                   rtl/uart_out.vhd rtl/trng_top.vhd -e trng_top;
    synth_ice40 -top trng_top -json trng_top.json"

nextpnr-ice40 --hx1k --package tq144 \
              --json trng_top.json --pcf rtl/trng_top.pcf \
              --asc trng_top.asc

icepack trng_top.asc trng_top.bin
iceprog trng_top.bin
```

---

## Running the NIST Tests

```bash
pip install pyserial

# Collect 1 MB and test:
python3 tools/collect.py /dev/ttyUSB0 --bytes 1048576 --out random.bin
python3 tools/nist_sts.py --file random.bin --bits 1000000

# Pipe directly:
python3 tools/collect.py /dev/ttyUSB0 --bytes 131072 | \
    python3 tools/nist_sts.py --bits 1000000

# Calibrate against /dev/urandom:
python3 tools/nist_sts.py --urandom --bits 1000000
```

---

## File Map

| File | Description |
|---|---|
| `rtl/ring_osc.vhd` | 8-chain ring oscillator entropy source (LFSR in simulation) |
| `rtl/von_neumann.vhd` | Von Neumann decorrelation filter |
| `rtl/aes_sbox.vhd` | AES SubBytes S-box ROM (256 × 8-bit) |
| `rtl/aes_whitener.vhd` | Iterative AES-128 whitener (zero key, pre-computed round keys) |
| `rtl/uart_out.vhd` | 115200-baud UART serialiser for 128-bit blocks |
| `rtl/trng_top.vhd` | Top-level connecting all pipeline stages |
| `rtl/trng_top.pcf` | iCEstick pin constraints |
| `sim/tb_trng.vhd` | VHDL testbench: pipeline verification, stuck-byte detection |
| `tools/collect.py` | Serial port data collector (streams bytes to file or stdout) |
| `tools/nist_sts.py` | 9-test NIST SP 800-22 statistical test suite in Python |
| `docs/ARCHITECTURE.md` | This document |
