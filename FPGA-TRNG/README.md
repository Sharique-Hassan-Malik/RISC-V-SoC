# FPGA TRNG

A hardware True Random Number Generator for the Lattice iCEstick (iCE40HX1K)
that harvests entropy from FPGA ring-oscillator jitter, decorrelates the raw
bits with a Von Neumann filter and applies AES-128 cryptographic whitening
before streaming the output at 115 200 baud over UART.  The Python companion
tool implements nine tests from the NIST SP 800-22 statistical test suite and
can be run directly against the serial output or a collected binary file.

---

## What it does

Eight independent inverter-chain ring oscillators run freely in the FPGA
fabric at different frequencies (200–600 MHz each, depending on process and
temperature variation).  Their outputs are XOR'd together and sampled at the
12 MHz system clock rate.  The resulting bit stream, carrying jitter-sourced
entropy, passes through a Von Neumann decorrelator which removes first-order
bias by discarding equal-value bit pairs.  Every 128 decorrelated bits form
one input block for the AES-128 whitener, which compresses any remaining
bias into a uniformly distributed 128-bit output.  The whitened block is then
transmitted as 16 bytes over UART at 115 200 baud.

On the host, `collect.py` gathers bytes from the serial port and `nist_sts.py`
runs the statistical tests.

---

## The hard part

**Ring oscillator entropy is invisible to the synthesis tool.**  The jitter
that provides entropy is a physical phenomenon — clock uncertainty between
two different oscillator domains — which cannot be modelled in RTL simulation.
The synthesis tool may legally remove the ring oscillators as dead code if
their outputs are not used in a visible way.  In production the oscillators
must be implemented as explicit LUT4 primitives with attributes that prevent
optimisation.  The `ring_osc.vhd` module uses a portable LFSR model for
simulation and documents the required primitive-level implementation.

**Von Neumann efficiency loss.**  The decorrelator discards roughly 50% of
input bits (equal pairs).  For a biased source with Pr(1) = 0.55 the output
rate is 2 × 0.55 × 0.45 = 0.495 bits per input bit — still near 50%.  But
the raw entropy rate (bits of true randomness per input bit) depends on the
actual ring jitter, which must be measured on hardware.

**AES with a known key does not reduce the output to deterministic.**
The whitener uses AES-128 with a zero key (which is public knowledge).  This
is intentional and correct: AES is a bijection, and applying a public bijection
to a high-entropy input produces a high-entropy output.  The whitening cannot
create entropy, but it cannot destroy it either — and it ensures that any
remaining first- or second-order correlations are spread uniformly across all
128 output bits before transmission.

---

## Architecture

See `docs/ARCHITECTURE.md` for the full pipeline block diagram, Von Neumann
decorrelation math, AES whitener round-key table, UART timing derivation,
throughput analysis and NIST test descriptions with expected result ranges.

---

## Hardware

| Component | Notes |
|---|---|
| FPGA | Lattice iCEstick (iCE40HX1K-TQ144), 12 MHz on-board oscillator |
| UART output | Pin 61 (J2-1), 115 200 baud 8N1 |
| USB-serial adapter | Any 3.3 V FTDI or CH340 adapter |

**Pin map**

| iCEstick pin | Signal |
|---|---|
| 21 | 12 MHz system clock |
| 47 | Reset (active low; tie to VCC to run continuously) |
| 61 (J2-1) | UART TX → serial adapter RX |
| 99 (LED D1) | Block output indicator (blinks per AES block) |
| 98 (LED D2) | Activity indicator (on while running) |

---

## Building and running

```bash
# Synthesise and program (requires ghdl-yosys-plugin + nextpnr-ice40):
yosys -m ghdl -p "ghdl --std=08 rtl/*.vhd -e trng_top; \
    synth_ice40 -top trng_top -json trng_top.json"
nextpnr-ice40 --hx1k --package tq144 \
    --json trng_top.json --pcf rtl/trng_top.pcf --asc trng_top.asc
icepack trng_top.asc trng_top.bin
iceprog trng_top.bin

# Collect 1 MB and run NIST tests:
pip install pyserial
python3 tools/collect.py /dev/ttyUSB0 --bytes 1048576 --out random.bin
python3 tools/nist_sts.py --file random.bin --bits 1000000

# Calibrate against OS random (expected all PASS):
python3 tools/nist_sts.py --urandom --bits 1000000
```

---

## Simulation

```bash
ghdl -a --std=08 rtl/ring_osc.vhd rtl/von_neumann.vhd rtl/aes_sbox.vhd \
     rtl/aes_whitener.vhd rtl/uart_out.vhd rtl/trng_top.vhd sim/tb_trng.vhd
ghdl -e --std=08 tb_trng
ghdl -r --std=08 tb_trng --stop-time=200ms
```

---

## Results

| Metric | Value |
|---|---|
| Entropy source | 8 ring oscillators, 7-stage inverter chains |
| Raw sample rate | 12 MHz (one XOR'd sample per system clock) |
| Von Neumann output rate | ~6 Mbit/s (~50% efficiency) |
| AES block rate | ~46 000 blocks/s |
| UART output rate | ~11 500 bytes/s (92 kbit/s) |
| NIST tests implemented | 9 of 15 from SP 800-22 Rev. 1a |
| Expected NIST result | All 9 PASS with p-values ≥ 0.01 |
