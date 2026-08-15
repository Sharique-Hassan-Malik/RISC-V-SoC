#!/usr/bin/env python3
"""
verify_fp.py — Verify the VHDL fixed-point Mandelbrot implementation.

Computes the same iteration using Python floating-point and fixed-point
arithmetic, compares results, and generates a reference PPM image.

Usage:
    python3 sim/verify_fp.py                     # 80×60 reference image
    python3 sim/verify_fp.py --w 320 --h 240     # larger image
    python3 sim/verify_fp.py --check-fp          # compare float vs Q4.27
"""

import argparse
import math


# ---- Fixed-point helpers (Q4.27) ---------------------------------------- #

FRAC_BITS = 27
FP_ONE    = 1 << FRAC_BITS   # 134217728
MASK32    = (1 << 32) - 1

def to_fp(x: float) -> int:
    """Convert float to Q4.27 signed integer."""
    return int(round(x * FP_ONE))

def fp_mul(a: int, b: int) -> int:
    """Q4.27 × Q4.27 → Q4.27 (truncate sub-fractional bits)."""
    product = a * b   # 64-bit signed product
    return product >> FRAC_BITS

def fp_to_float(x: int) -> float:
    # Handle two's complement for 32-bit
    if x >= (1 << 31):
        x -= (1 << 32)
    return x / FP_ONE


# ---- Mandelbrot iteration (floating-point) ------------------------------ #

def mandelbrot_float(c_re: float, c_im: float, max_iter: int) -> int:
    zr, zi = 0.0, 0.0
    for i in range(max_iter):
        zr2 = zr * zr
        zi2 = zi * zi
        if zr2 + zi2 > 4.0:
            return i
        zi = 2.0 * zr * zi + c_im
        zr = zr2 - zi2 + c_re
    return max_iter


# ---- Mandelbrot iteration (Q4.27 fixed-point, mirrors VHDL) ------------- #

def mandelbrot_fp(c_re_fp: int, c_im_fp: int, max_iter: int) -> int:
    zr = 0
    zi = 0
    four_fp = to_fp(4.0)
    for i in range(max_iter):
        zr2 = fp_mul(zr, zr)
        zi2 = fp_mul(zi, zi)
        if zr2 + zi2 >= four_fp:
            return i
        zi_new = (fp_mul(zr, zi) << 1) + c_im_fp
        zr_new = zr2 - zi2 + c_re_fp
        zr = zr_new & MASK32
        zi = zi_new & MASK32
        # Sign-extend 32-bit to Python int
        if zr >= (1 << 31): zr -= (1 << 32)
        if zi >= (1 << 31): zi -= (1 << 32)
    return max_iter


# ---- Colour map (mirrors VHDL colour_map.vhd) ---------------------------- #

PALETTE = [
    (  0,   0, 255),   # 0 → blue
    (  0, 255,   0),   # 1 → green
    (  0, 255, 255),   # 2 → cyan
    (255,   0,   0),   # 3 → red
    (255,   0, 255),   # 4 → magenta
    (255, 255,   0),   # 5 → yellow
    (255, 255, 255),   # 6 → white
]

def iter_to_rgb(it: int, max_iter: int) -> tuple:
    if it >= max_iter:
        return (0, 0, 0)
    return PALETTE[it % len(PALETTE)]


# ---- Image generation --------------------------------------------------- #

def render(w: int, h: int, max_iter: int, use_fp: bool = False) -> list:
    re_min, re_max = -2.5,  1.0
    im_min, im_max = -1.25, 1.25
    pixels = []
    for py in range(h):
        row = []
        for px in range(w):
            c_re = re_min + (re_max - re_min) * px / w
            c_im = im_min + (im_max - im_min) * py / h
            if use_fp:
                it = mandelbrot_fp(to_fp(c_re), to_fp(c_im), max_iter)
            else:
                it = mandelbrot_float(c_re, c_im, max_iter)
            row.append(iter_to_rgb(it, max_iter))
        pixels.append(row)
    return pixels


def write_ppm(filename: str, pixels: list) -> None:
    h = len(pixels)
    w = len(pixels[0]) if h > 0 else 0
    with open(filename, "w") as f:
        f.write(f"P3\n{w} {h}\n255\n")
        for row in pixels:
            for r, g, b in row:
                f.write(f"{r} {g} {b} ")
            f.write("\n")
    print(f"  Written {filename}  ({w}×{h} pixels)")


def check_fp_accuracy(w: int = 80, h: int = 60, max_iter: int = 64) -> None:
    """Compare float vs Q4.27 iteration counts."""
    re_min, re_max = -2.5,  1.0
    im_min, im_max = -1.25, 1.25
    mismatches = 0
    total = 0
    max_diff = 0

    for py in range(h):
        for px in range(w):
            c_re = re_min + (re_max - re_min) * px / w
            c_im = im_min + (im_max - im_min) * py / h
            it_f  = mandelbrot_float(c_re, c_im, max_iter)
            it_fp = mandelbrot_fp(to_fp(c_re), to_fp(c_im), max_iter)
            diff  = abs(it_f - it_fp)
            if diff > 0:
                mismatches += 1
            if diff > max_diff:
                max_diff = diff
            total += 1

    pct = 100.0 * mismatches / total
    print(f"  Pixels compared : {total}")
    print(f"  Mismatches      : {mismatches}  ({pct:.1f}%)")
    print(f"  Max iter diff   : {max_diff}")
    if max_diff <= 2:
        print("  PASS — Q4.27 accuracy is within ±2 iterations of float.")
    else:
        print("  WARN — Large discrepancy; check FP_FRAC constant.")


# ---- Entry point -------------------------------------------------------- #

def main() -> None:
    p = argparse.ArgumentParser(description="Mandelbrot reference image generator")
    p.add_argument("--w",        type=int, default=80,  help="Image width")
    p.add_argument("--h",        type=int, default=60,  help="Image height")
    p.add_argument("--max-iter", type=int, default=64,  help="Max iterations")
    p.add_argument("--check-fp", action="store_true",   help="Compare float vs Q4.27")
    p.add_argument("--fp-image", action="store_true",   help="Render using Q4.27 (mirrors VHDL)")
    args = p.parse_args()

    if args.check_fp:
        print("Fixed-point accuracy check:")
        check_fp_accuracy(args.w, args.h, args.max_iter)
        print()

    print("Rendering float reference image...")
    pixels_f = render(args.w, args.h, args.max_iter, use_fp=False)
    write_ppm("mandelbrot_ref.ppm", pixels_f)

    if args.fp_image:
        print("Rendering Q4.27 fixed-point image (mirrors VHDL)...")
        pixels_fp = render(args.w, args.h, args.max_iter, use_fp=True)
        write_ppm("mandelbrot_fp.ppm", pixels_fp)

    # Print a small ASCII preview to the terminal.
    print("\nASCII preview (40×20, centre region):")
    chars = " .:-=+*#%@"
    pw, ph = min(40, args.w), min(20, args.h)
    xoff = (args.w - pw) // 2
    yoff = (args.h - ph) // 2
    for py in range(yoff, yoff + ph):
        row = ""
        for px in range(xoff, xoff + pw):
            it = mandelbrot_float(
                -2.5 + 3.5 * px / args.w,
                -1.25 + 2.5 * py / args.h,
                args.max_iter
            )
            if it >= args.max_iter:
                row += "#"
            else:
                row += chars[it % len(chars)]
        print(" ", row)


if __name__ == "__main__":
    main()
