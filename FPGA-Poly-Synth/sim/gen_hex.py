#!/usr/bin/env python3
"""
gen_hex.py — Generate ROM initialisation files for the FPGA synthesiser.

Outputs:
  sine1024_q15.hex      1024-entry Q15 sine table for dds_osc.v
  note_phase_48k.hex    128-entry MIDI note → DDS phase increment for note_to_phase.v

Also prints biquad low-pass filter coefficients for given fc and Q.

Usage:
  python3 gen_hex.py                     # generate both HEX files
  python3 gen_hex.py --fc 1000 --q 0.5  # also print biquad coeffs for 1 kHz
"""

import argparse
import math
import cmath

SAMPLE_RATE  = 48_000
WAVE_POINTS  = 1024
PHASE_BITS   = 32     # DDS accumulator width
Q15_SCALE    = 32767  # max positive Q15 value


def gen_sine_rom():
    """Generate 1024-point Q15 sine table."""
    entries = []
    for i in range(WAVE_POINTS):
        angle   = 2.0 * math.pi * i / WAVE_POINTS
        val_f   = math.sin(angle) * Q15_SCALE
        val_i   = int(round(val_f))
        val_i   = max(-32768, min(32767, val_i))
        # Two's complement 16-bit
        if val_i < 0:
            val_i += 65536
        entries.append(val_i)
    return entries


def gen_note_phases(fs=SAMPLE_RATE):
    """Generate 128-entry MIDI note → 32-bit DDS phase increment table."""
    phases = []
    for n in range(128):
        freq  = 440.0 * (2.0 ** ((n - 69) / 12.0))
        inc   = int(round(freq / fs * (2 ** PHASE_BITS)))
        inc  &= 0xFFFF_FFFF
        phases.append(inc)
    return phases


def write_hex(filename, entries, width_bytes):
    """Write a $readmemh-compatible HEX file (one value per line)."""
    fmt = f"{{:0{width_bytes*2}X}}"
    with open(filename, "w") as f:
        for v in entries:
            f.write(fmt.format(v) + "\n")
    print(f"  Written {filename}  ({len(entries)} entries, {width_bytes*8}-bit)")


def biquad_lowpass(fc, q, fs=SAMPLE_RATE):
    """
    Compute bilinear-transform biquad low-pass coefficients.
    Returns (b0, b1, b2, a1, a2) as floating-point, then Q15 integers.

    Transfer function:
        H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2)

    Note: a1 and a2 here follow the convention in biquad_df1.v where they
    appear with negative signs in the difference equation, so we store
    them as positive values and subtract in the code.
    """
    K     = math.tan(math.pi * fc / fs)
    norm  = 1.0 + K / q + K * K
    b0    =  K * K / norm
    b1    =  2.0 * b0
    b2    =  b0
    a1_f  =  2.0 * (K * K - 1.0) / norm   # actual a1 (negative in denominator)
    a2_f  =  (1.0 - K / q + K * K) / norm

    def to_q15(x):
        v = int(round(x * 32768.0))
        v = max(-32768, min(32767, v))
        if v < 0:
            v += 65536
        return v

    print(f"\n  Biquad low-pass  fc={fc} Hz  Q={q}  Fs={fs} Hz")
    print(f"  b0={b0:.6f}  b1={b1:.6f}  b2={b2:.6f}")
    print(f"  a1={a1_f:.6f}  a2={a2_f:.6f}")
    print(f"\n  Q15 hex (for synth_top.v):")
    print(f"  .b0(16'h{to_q15(b0):04X}),", end="  ")
    print(f".b1(16'h{to_q15(b1):04X}),", end="  ")
    print(f".b2(16'h{to_q15(b2):04X}),")
    print(f"  .a1(16'h{to_q15(a1_f):04X}),", end="  ")
    print(f".a2(16'h{to_q15(a2_f):04X})")

    # Sanity checks
    print(f"\n  Sanity: gain at DC   = {abs(b0 + b1 + b2) / abs(1.0 + a1_f + a2_f):.4f}  (expect 1.0)")
    gain_fc = abs((b0 + b1 * cmath.exp(-1j * math.pi) + b2 * cmath.exp(-2j * math.pi)) /
                  (1.0 + a1_f * cmath.exp(-1j * math.pi) + a2_f * cmath.exp(-2j * math.pi)))
    print(f"  Sanity: gain at Fs/2 = {gain_fc:.4f}  (expect 0.0 for LP)")

    return b0, b1, b2, a1_f, a2_f


def main():
    p = argparse.ArgumentParser(description="Generate synth ROM HEX files")
    p.add_argument("--fc", type=float, default=2000.0, help="Filter cutoff Hz")
    p.add_argument("--q",  type=float, default=0.707,  help="Filter Q / resonance")
    p.add_argument("--fs", type=int,   default=48000,  help="Sample rate Hz")
    args = p.parse_args()

    print("Generating sine ROM...")
    sine = gen_sine_rom()
    write_hex("sine1024_q15.hex", sine, 2)

    # Verify a few values.
    print(f"  Sanity: sine[0]   = 0x{sine[0]:04X}  (expect 0x0000)")
    print(f"  Sanity: sine[256] = 0x{sine[256]:04X}  (expect 0x7FFF)")
    print(f"  Sanity: sine[512] = 0x{sine[512]:04X}  (expect 0x0000)")
    print(f"  Sanity: sine[768] = 0x{sine[768]:04X}  (expect 0x8001)")

    print("\nGenerating MIDI phase increment table...")
    phases = gen_note_phases(args.fs)
    write_hex("note_phase_48k.hex", phases, 4)

    a4_inc  = int(round(440.0 / args.fs * (2 ** PHASE_BITS)))
    print(f"  Sanity: A4 (note 69) = 0x{phases[69]:08X}  (expect ~0x{a4_inc:08X})")
    print(f"  Sanity: C4 (note 60) = 0x{phases[60]:08X}")

    print("\nFilter coefficients:")
    biquad_lowpass(args.fc, args.q, args.fs)


if __name__ == "__main__":
    main()
