#!/usr/bin/env python3
"""
decode_pdm.py — Decode the 1-bit PDM stream captured by tb_synth.v into a WAV.

The simulation captures the pdm_out_pin at every rising edge of the 12 MHz
master clock, packing 8 bits per byte (LSB = first in time).

Decoding:
  1. Unpack bits.
  2. Apply a simple CIC-style decimation filter (average every 250 bits →
     one 48 kHz sample).
  3. Write a 16-bit mono WAV file.

Usage:
  python3 decode_pdm.py pdm_out.bin [--out synth_out.wav]

The resulting WAV can be played with any audio player or analysed in Audacity.
"""

import argparse
import struct
import sys


def decode_pdm(raw_bytes, clk_hz=12_000_000, sample_hz=48_000):
    """Unpack bits and decimate to audio samples."""
    decimation = clk_hz // sample_hz   # 250
    bits = []
    for byte in raw_bytes:
        for i in range(8):
            bits.append((byte >> i) & 1)

    samples = []
    i = 0
    while i + decimation <= len(bits):
        block   = bits[i : i + decimation]
        average = sum(block) / len(block)   # 0.0–1.0
        # Map [0, 1] to [-32767, +32767]
        s = int(round((average - 0.5) * 2.0 * 32767))
        s = max(-32767, min(32767, s))
        samples.append(s)
        i += decimation

    return samples


def write_wav(filename, samples, sample_hz=48_000):
    n_samples = len(samples)
    data_size = n_samples * 2   # 16-bit mono
    with open(filename, "wb") as f:
        # RIFF header
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))
        f.write(b"WAVE")
        # fmt chunk
        f.write(b"fmt ")
        f.write(struct.pack("<I",  16))        # chunk size
        f.write(struct.pack("<H",   1))        # PCM
        f.write(struct.pack("<H",   1))        # mono
        f.write(struct.pack("<I", sample_hz))  # sample rate
        f.write(struct.pack("<I", sample_hz * 2))  # byte rate
        f.write(struct.pack("<H",   2))        # block align
        f.write(struct.pack("<H",  16))        # bits per sample
        # data chunk
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        for s in samples:
            f.write(struct.pack("<h", s))


def main():
    p = argparse.ArgumentParser(description="Decode PDM simulation output to WAV")
    p.add_argument("input",  help="PDM binary file from tb_synth simulation")
    p.add_argument("--out",  default="synth_out.wav", help="Output WAV file")
    args = p.parse_args()

    with open(args.input, "rb") as f:
        raw = f.read()

    print(f"  Input:   {args.input}  ({len(raw)} bytes, {len(raw)*8} PDM bits)")

    samples = decode_pdm(raw)
    print(f"  Samples: {len(samples)}  ({len(samples)/48000:.2f} s at 48 kHz)")

    write_wav(args.out, samples)
    print(f"  Output:  {args.out}")


if __name__ == "__main__":
    main()
