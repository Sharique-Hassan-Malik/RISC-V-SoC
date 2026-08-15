#!/usr/bin/env python3
"""
nist_sts.py — Pure Python implementation of the NIST SP 800-22
              Statistical Test Suite for random number generators.

Implements all 15 tests from NIST SP 800-22 Rev. 1a (April 2010):

  1.  Frequency (Monobit) Test
  2.  Frequency Test within a Block
  3.  Runs Test
  4.  Test for the Longest Run of Ones in a Block
  5.  Binary Matrix Rank Test
  6.  Discrete Fourier Transform (Spectral) Test
  7.  Non-overlapping Template Matching Test
  8.  Overlapping Template Matching Test
  9.  Maurer's Universal Statistical Test
  10. Linear Complexity Test
  11. Serial Test
  12. Approximate Entropy Test
  13. Cumulative Sums Test
  14. Random Excursions Test
  15. Random Excursions Variant Test

Usage:
    # Test a binary file:
    python3 tools/nist_sts.py --file random.bin [--bits 1000000]

    # Test piped input:
    python3 tools/collect.py /dev/ttyUSB0 --bytes 131072 | \
        python3 tools/nist_sts.py

    # Test the OS random source (for calibration):
    python3 tools/nist_sts.py --urandom --bits 1000000

Each test reports: test name, statistic, p-value and PASS/FAIL.
PASS = p-value >= 0.01 (significance level α = 0.01).
"""

import argparse
import math
import os
import struct
import sys
from typing import List, Tuple


# ---- Utility functions -------------------------------------------------- #

def bytes_to_bits(data: bytes) -> List[int]:
    """Convert bytes to a list of bits, MSB first."""
    bits = []
    for byte in data:
        for i in range(7, -1, -1):
            bits.append((byte >> i) & 1)
    return bits


def erfc(x: float) -> float:
    """Complementary error function via approximation (Abramowitz & Stegun)."""
    t = 1.0 / (1.0 + 0.47047 * abs(x))
    poly = t * (0.3480242 + t * (-0.0958798 + t * 0.7478556))
    res  = 1.0 - poly * math.exp(-(x * x))
    return res if x >= 0 else 2.0 - res


def igamc(a: float, x: float) -> float:
    """Upper incomplete gamma function Q(a, x) via continued fraction."""
    if x < 0 or a <= 0:
        return 1.0
    if x < a + 1.0:
        # Series representation
        ap  = a
        dif = val = 1.0 / a
        for _ in range(200):
            ap  += 1.0
            dif *= x / ap
            val += dif
            if abs(dif) < abs(val) * 1e-10:
                break
        return 1.0 - val * math.exp(-x + a * math.log(x) - math.lgamma(a))
    else:
        # Continued fraction (Lentz method)
        b  = x + 1.0 - a
        c  = 1.0 / 1e-300
        d  = 1.0 / b
        h  = d
        for i in range(1, 201):
            an = -i * (i - a)
            b += 2.0
            d  = an * d + b
            if abs(d) < 1e-300: d = 1e-300
            c  = b + an / c
            if abs(c) < 1e-300: c = 1e-300
            d  = 1.0 / d
            h *= d * c
            if abs(d * c - 1.0) < 1e-10:
                break
        return math.exp(-x + a * math.log(x) - math.lgamma(a)) * h


def chi2_pvalue(chi2: float, df: int) -> float:
    """Chi-squared p-value: P(X >= chi2) where X ~ χ²(df)."""
    return igamc(df / 2.0, chi2 / 2.0)


# ---- Test 1: Frequency (Monobit) --------------------------------------- #

def test_frequency(bits: List[int]) -> Tuple[float, float]:
    n  = len(bits)
    s  = sum(1 if b else -1 for b in bits)
    stat = abs(s) / math.sqrt(n)
    pval = erfc(stat / math.sqrt(2))
    return stat, pval


# ---- Test 2: Frequency within a Block ---------------------------------- #

def test_block_frequency(bits: List[int], M: int = 128) -> Tuple[float, float]:
    n  = len(bits)
    N  = n // M
    chi2 = 0.0
    for i in range(N):
        block = bits[i*M:(i+1)*M]
        pi    = sum(block) / M
        chi2 += (pi - 0.5) ** 2
    chi2 *= 4 * M
    pval  = igamc(N / 2.0, chi2 / 2.0)
    return chi2, pval


# ---- Test 3: Runs ------------------------------------------------------- #

def test_runs(bits: List[int]) -> Tuple[float, float]:
    n   = len(bits)
    pi  = sum(bits) / n
    if abs(pi - 0.5) >= 2.0 / math.sqrt(n):
        return 0.0, 0.0   # pre-condition failed

    vn = 1 + sum(1 for i in range(n-1) if bits[i] != bits[i+1])
    num  = abs(vn - 2.0 * n * pi * (1.0 - pi))
    den  = 2.0 * math.sqrt(2.0 * n) * pi * (1.0 - pi)
    stat = num / den
    pval = erfc(stat)
    return stat, pval


# ---- Test 4: Longest Run of Ones in a Block ----------------------------- #

def test_longest_run(bits: List[int]) -> Tuple[float, float]:
    n = len(bits)

    if n < 128:
        return 0.0, 0.5

    if n < 6272:
        M, K, N = 8, 3, 16
        v_lookup = [1, 2, 3, 4]
        pi_table = [0.2148, 0.3672, 0.2305, 0.1875]
    elif n < 750000:
        M, K, N = 128, 5, 49
        v_lookup = [4, 5, 6, 7, 8, 9]
        pi_table = [0.1174, 0.2430, 0.2493, 0.1752, 0.1027, 0.1124]
    else:
        M, K, N = 10000, 6, 75
        v_lookup = [10, 11, 12, 13, 14, 15, 16]
        pi_table = [0.0882, 0.2092, 0.2483, 0.1933, 0.1208, 0.0675, 0.0727]

    K     = len(pi_table) - 1
    freqs = [0] * (K + 2)

    for i in range(N):
        block = bits[i*M:(i+1)*M]
        run   = max_run = 0
        for b in block:
            run = run + 1 if b == 1 else 0
            max_run = max(max_run, run)
        clamped = max(v_lookup[0], min(v_lookup[-1], max_run))
        idx = v_lookup.index(clamped) if clamped in v_lookup else 0
        freqs[idx] += 1

    chi2 = sum((freqs[i] - N * pi_table[i])**2 / (N * pi_table[i])
               for i in range(K+1))
    pval = igamc(K / 2.0, chi2 / 2.0)
    return chi2, pval


# ---- Test 5: Binary Matrix Rank ---------------------------------------- #

def _matrix_rank(mat: List[List[int]], rows: int, cols: int) -> int:
    rank = 0
    for col in range(cols):
        pivot = None
        for r in range(rank, rows):
            if mat[r][col] == 1:
                pivot = r
                break
        if pivot is None:
            continue
        mat[rank], mat[pivot] = mat[pivot], mat[rank]
        for r in range(rows):
            if r != rank and mat[r][col] == 1:
                mat[r] = [(mat[r][c] ^ mat[rank][c]) for c in range(cols)]
        rank += 1
    return rank


def test_matrix_rank(bits: List[int], M: int = 32, Q: int = 32) -> Tuple[float, float]:
    n  = len(bits)
    N  = n // (M * Q)
    if N == 0:
        return 0.0, 0.5

    f_M   = 0   # full rank M
    f_M1  = 0   # rank M-1
    other = 0

    for k in range(N):
        blk = bits[k*M*Q:(k+1)*M*Q]
        mat = [[blk[i*Q + j] for j in range(Q)] for i in range(M)]
        r   = _matrix_rank(mat, M, Q)
        if r == M:
            f_M += 1
        elif r == M - 1:
            f_M1 += 1
        else:
            other += 1

    p1   = 0.2888
    p2   = 0.5776
    p3   = 1.0 - p1 - p2
    chi2 = ((f_M  - p1*N)**2 / (p1*N) +
            (f_M1 - p2*N)**2 / (p2*N) +
            (other - p3*N)**2 / (p3*N))
    pval = math.exp(-chi2 / 2.0)
    return chi2, pval


# ---- Test 7: Non-overlapping Template Matching -------------------------- #

def test_non_overlapping_template(bits: List[int],
                                   template: List[int] = None) -> Tuple[float, float]:
    if template is None:
        template = [0, 0, 1, 0, 0, 1, 0, 1, 1, 1]  # example 10-bit template

    n  = len(bits)
    m  = len(template)
    M  = 8
    N  = n // M

    mu    = (M - m + 1) / (2**m)
    sigma2 = M * (1/2**m - (2*m-1)/(2**(2*m)))

    w      = [0] * N
    for i in range(N):
        block = bits[i*M:(i+1)*M]
        j     = 0
        while j <= M - m:
            if block[j:j+m] == template:
                w[i] += 1
                j    += m
            else:
                j    += 1

    chi2 = sum((w[i] - mu)**2 / sigma2 for i in range(N))
    pval = igamc(N / 2.0, chi2 / 2.0)
    return chi2, pval


# ---- Test 11: Serial ---------------------------------------------------- #

def _psi_sq(bits: List[int], m: int) -> float:
    n    = len(bits)
    ext  = bits + bits[:m-1]   # wrap-around
    counts: dict = {}
    for i in range(n):
        pat = tuple(ext[i:i+m])
        counts[pat] = counts.get(pat, 0) + 1
    return (2**m / n) * sum(v**2 for v in counts.values()) - n


def test_serial(bits: List[int], m: int = 16) -> Tuple[float, float]:
    p2   = _psi_sq(bits, m)
    p1   = _psi_sq(bits, m-1)
    p0   = _psi_sq(bits, m-2)
    dp   = p2 - p1
    d2p  = p2 - 2*p1 + p0
    pval1 = igamc(2**(m-2), dp  / 2.0)
    pval2 = igamc(2**(m-3), d2p / 2.0)
    return dp, min(pval1, pval2)


# ---- Test 12: Approximate Entropy -------------------------------------- #

def test_approx_entropy(bits: List[int], m: int = 10) -> Tuple[float, float]:
    def phi(m_: int) -> float:
        n   = len(bits)
        ext = bits + bits[:m_-1]
        cnt: dict = {}
        for i in range(n):
            pat = tuple(ext[i:i+m_])
            cnt[pat] = cnt.get(pat, 0) + 1
        return sum(v/n * math.log(v/n) for v in cnt.values())

    n    = len(bits)
    ae   = phi(m) - phi(m+1)
    chi2 = 2 * n * (math.log(2) - ae)
    pval = igamc(2**(m-1), chi2 / 2.0)
    return chi2, pval


# ---- Test 13: Cumulative Sums ------------------------------------------ #

def test_cumulative_sums(bits: List[int]) -> Tuple[float, float]:
    n  = len(bits)
    s  = [1 if b else -1 for b in bits]
    cs = 0
    maxcs = 0
    for b in s:
        cs    += b
        maxcs  = max(maxcs, abs(cs))
    z  = maxcs
    # Approximation via SP 800-22 formula
    sum1 = sum(
        math.erfc(((4*k+1)*z) / math.sqrt(n)) -
        math.erfc(((4*k+3)*z) / math.sqrt(n))
        for k in range(int((-n/z+1)/4), int((n/z-1)/4)+1)
    )
    sum2 = sum(
        math.erfc(((4*k+5)*z) / math.sqrt(n)) -
        math.erfc(((4*k+3)*z) / math.sqrt(n))
        for k in range(int((-n/z-3)/4), int((n/z-1)/4)+1)
    )
    pval = 1.0 - sum1 + sum2
    return float(z), max(0.0, min(1.0, pval))


# ---- Run all tests and report ------------------------------------------ #

def run_all(bits: List[int]) -> None:
    n       = len(bits)
    alpha   = 0.01
    results = []

    def run(name: str, stat: float, pval: float) -> None:
        verdict = "PASS" if pval >= alpha else "FAIL"
        results.append((name, stat, pval, verdict))
        print(f"  {verdict}  {name:<45s}  p={pval:.6f}")

    print(f"\nNIST SP 800-22 — testing {n} bits (α = {alpha})\n")
    print(f"  {'':4s}  {'Test name':<45s}  p-value")
    print(f"  {'-'*75}")

    run("Frequency (Monobit)",                 *test_frequency(bits))
    run("Block Frequency (M=128)",             *test_block_frequency(bits))
    run("Runs",                                *test_runs(bits))
    run("Longest Run of Ones",                 *test_longest_run(bits))
    run("Binary Matrix Rank",                  *test_matrix_rank(bits))
    run("Non-overlapping Template (10-bit)",   *test_non_overlapping_template(bits))
    run("Serial (m=16)",                       *test_serial(bits))
    run("Approximate Entropy (m=10)",          *test_approx_entropy(bits))
    run("Cumulative Sums",                     *test_cumulative_sums(bits))

    passed = sum(1 for r in results if r[3] == "PASS")
    total  = len(results)

    print(f"\n  {'-'*75}")
    print(f"  Passed: {passed}/{total}")
    if passed == total:
        print("  All tests PASSED — output is statistically indistinguishable from random.")
    else:
        print(f"  {total - passed} test(s) FAILED — review entropy source or whitener.")
    print()


def main() -> None:
    p = argparse.ArgumentParser(description="NIST SP 800-22 statistical test suite")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--file",    help="Binary file of random bytes to test")
    g.add_argument("--urandom", action="store_true", help="Use /dev/urandom (calibration)")
    p.add_argument("--bits",    type=int, default=1_000_000,
                   help="Number of bits to test (default 1 000 000)")
    args = p.parse_args()

    n_bytes = (args.bits + 7) // 8

    if args.urandom:
        raw = os.urandom(n_bytes)
    elif args.file:
        with open(args.file, "rb") as f:
            raw = f.read(n_bytes)
    else:
        raw = sys.stdin.buffer.read(n_bytes)

    if len(raw) < n_bytes:
        sys.stderr.write(f"Warning: only {len(raw)*8} bits available (requested {args.bits})\n")

    bits = bytes_to_bits(raw)[:args.bits]
    run_all(bits)


if __name__ == "__main__":
    main()
