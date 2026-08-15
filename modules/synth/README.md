# FPGA Poly Synth

> Part of the [RISC-V SoC](../../README.md). Simulates standalone from this
> folder, or through `soc sim --only <name>`, which already knows the flags.

A 4-voice polyphonic synthesiser implemented in Verilog targeting the Lattice
iCEstick (iCE40HX1K-TQ144).  MIDI notes arrive on a DIN-5 connector through a
PC-900 optocoupler.  Each active note drives a 32-bit DDS sine oscillator
through a 5-state ADSR envelope, all four voices mix into a single digital
biquad low-pass filter, and the output emerges as a 1-bit sigma-delta PDM
stream on a GPIO pin.  A simple RC circuit converts the PDM stream to analog
audio.  No soft-core CPU is involved anywhere — the entire design is
synthesisable RTL.

---

## What it does

Plays up to four simultaneous MIDI notes with independent ADSR envelopes.
When a fifth note arrives the oldest active voice is stolen.  Six MIDI CC
parameters control attack rate (CC 5), decay rate (CC 6), sustain level (CC 7),
release rate (CC 8), filter cutoff intent (CC 1) and resonance (CC 71).  Four
LEDs on the iCEstick show which voices are active; a fifth LED blinks on each
received MIDI byte.

---

## The hard part

**No CPU — everything is concurrent combinational and sequential logic.**
There is no instruction pointer and no loop body: the MIDI receiver is decoding
a byte at the same clock cycle the voice allocator is processing a note-on at
the same clock cycle the ADSR envelopes are advancing at the same clock cycle
the DDS oscillators are computing new samples.  Getting timing closure across
all these paths and making sure the ADSR state machine handles gate transitions
without glitches required careful attention to edge conditions (gate rising
during release, velocity-zero note-on treated as note-off, running MIDI status).

**Block RAM inference for the wavetable.**  The iCE40HX1K has only 16 block
RAMs of 4 Kbits each.  Four DDS oscillators each need a 1024 × 16-bit sine ROM
(16 Kbits).  Sharing a single ROM across all voices is possible but adds a
time-multiplexed arbitration layer; the design instead uses four separate block
RAM instances, consuming 8 of the 16 available RAMs with the note-to-phase ROMs
using 4 more.  Fitting in the remaining 4 RAMs for other purposes requires
careful resource planning.

**Biquad filter coefficient quantisation.**  At 48 kHz with Q15 coefficients
the bilinear-transform low-pass filter has coefficient magnitudes well within
[-1, +1) for moderate cutoff frequencies, but the feedback coefficients a1 can
exceed 1.0 in magnitude for certain resonant settings.  The `COEFF_SHIFT`
parameter in `biquad_df1.v` accommodates this by widening the coefficient
interpretation to Q14, doubling the representable range.

---

## Architecture

See `docs/ARCHITECTURE.md` for the full block diagram, per-module descriptions,
DDS frequency resolution derivation, ADSR timing math, biquad coefficient
equations with a worked example, resource estimation table and sigma-delta
SNR analysis.

---

## Hardware

| Component | Notes |
|---|---|
| FPGA board | Lattice iCEstick (iCE40HX1K-TQ144), 12 MHz oscillator |
| MIDI optocoupler | PC-900 or 6N138, DIN-5 connector |
| RC filter | 4.7 kΩ + 10 nF on GPIO pin 78 → audio jack |

**Pin assignments**

| iCEstick pin | Signal |
|---|---|
| 21 | 12 MHz clock |
| 44 (J1-3) | MIDI RX (optocoupler output) |
| 78 (J2-3) | PDM audio output |
| 95–99 | LEDs 0–4 (active low) |

---

## Quick start

```bash
# Generate ROM hex files (required for synthesis and simulation).
python3 sim/gen_hex.py

# Synthesise and program iCEstick.
yosys -p "synth_ice40 -top synth_top -json synth_top.json" rtl/*.v
nextpnr-ice40 --hx1k --package tq144 \
              --json synth_top.json --pcf rtl/synth_top.pcf \
              --asc synth_top.asc
icepack synth_top.asc synth_top.bin
iceprog synth_top.bin

# Simulate and listen to output.
iverilog -g2012 -o tb_synth sim/tb_synth.v rtl/*.v
vvp tb_synth
python3 sim/decode_pdm.py pdm_out.bin --out synth_out.wav
```

---

## MIDI CC parameters

| CC | Parameter | Range |
|---|---|---|
| CC 1 | Filter cutoff intent | 0 (closed) → 127 (open) |
| CC 5 | Attack rate | 0 (slow) → 127 (fast) |
| CC 6 | Decay rate | 0 (slow) → 127 (fast) |
| CC 7 | Sustain level | 0 (off) → 127 (full) |
| CC 8 | Release rate | 0 (slow) → 127 (fast) |
| CC 71 | Resonance intent | 0 (flat) → 127 (high Q) |

---

## Results

| Metric | Value |
|---|---|
| Polyphony | 4 voices |
| Sample rate | 48 kHz |
| DDS frequency resolution | ~11.2 µHz |
| Filter type | 2nd-order Butterworth low-pass, bilinear transform |
| ADC/DAC | 1-bit sigma-delta, OSR = 250, ~50 dB theoretical SNR |
| Estimated LUT usage | ~750 / 1280 on iCE40HX1K |
| Block RAM usage | 12 / 16 on iCE40HX1K |
| Inferred DSP mults | 9 (mapped to LUT carry chains on iCE40) |
| MIDI baud rate | 31 250 (standard DIN-5 MIDI) |
| Voice steal policy | Round-robin with steal-oldest on overflow |
