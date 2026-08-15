"""
AES-128 software implementation and hardware throughput benchmark.

Provides:
  - Pure-Python AES-128 (no external crypto library) for verification
  - FIPS 197 test vector checks
  - Throughput measurement for Python software AES
  - Theoretical hardware throughput projection based on pipeline parameters
  - Side-by-side comparison table

Run: python3 aes_benchmark.py
"""

import time
import struct

# ── FIPS 197 S-box ────────────────────────────────────────────────────────────

SBOX = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
]

RCON = [0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36]


def xtime(b: int) -> int:
    return ((b << 1) ^ 0x1b) & 0xff if b & 0x80 else (b << 1) & 0xff


def key_expand(key: bytes) -> list[list[int]]:
    """Produce 11 round keys from a 16-byte key."""
    w = list(struct.unpack(">4I", key))
    for i in range(4, 44):
        t = w[i - 1]
        if i % 4 == 0:
            t = ((SBOX[(t >> 16) & 0xff] << 24) |
                 (SBOX[(t >>  8) & 0xff] << 16) |
                 (SBOX[(t      ) & 0xff] <<  8) |
                  SBOX[(t >> 24) & 0xff])
            t ^= RCON[i // 4] << 24
        w.append(w[i - 4] ^ t)
    return [w[i*4:(i+1)*4] for i in range(11)]


def add_round_key(state: list[int], rk: list[int]) -> list[int]:
    return [state[i] ^ rk[i // 4] >> (24 - (i % 4) * 8) & 0xff for i in range(16)]


def sub_bytes(state: list[int]) -> list[int]:
    return [SBOX[b] for b in state]


def shift_rows(state: list[int]) -> list[int]:
    # state is column-major: state[col*4 + row]
    s = state[:]
    # row 1: cols shift left by 1
    s[1], s[5], s[9], s[13] = state[5], state[9], state[13], state[1]
    # row 2: shift left by 2
    s[2], s[6], s[10], s[14] = state[10], state[14], state[2], state[6]
    # row 3: shift left by 3
    s[3], s[7], s[11], s[15] = state[15], state[3], state[7], state[11]
    return s


def mix_columns(state: list[int]) -> list[int]:
    out = [0] * 16
    for c in range(4):
        b = state[c*4:(c+1)*4]
        t = b[0] ^ b[1] ^ b[2] ^ b[3]
        out[c*4]   = b[0] ^ t ^ xtime(b[0] ^ b[1])
        out[c*4+1] = b[1] ^ t ^ xtime(b[1] ^ b[2])
        out[c*4+2] = b[2] ^ t ^ xtime(b[2] ^ b[3])
        out[c*4+3] = b[3] ^ t ^ xtime(b[3] ^ b[0])
    return out


def aes128_encrypt(plaintext: bytes, key: bytes) -> bytes:
    """AES-128 ECB encrypt one 16-byte block."""
    assert len(plaintext) == 16 and len(key) == 16
    # FIPS 197 column-major state order matches plaintext byte order directly.
    cm = list(plaintext)
    round_keys = key_expand(key)
    cm = add_round_key(cm, round_keys[0])
    for rnd in range(1, 10):
        cm = sub_bytes(cm)
        cm = shift_rows(cm)
        cm = mix_columns(cm)
        cm = add_round_key(cm, round_keys[rnd])
    cm = sub_bytes(cm)
    cm = shift_rows(cm)
    cm = add_round_key(cm, round_keys[10])
    # Convert back to row-major for output
    rm = bytes(cm[r*4+c] for r in range(4) for c in range(4))
    return rm


# ── Test vectors ──────────────────────────────────────────────────────────────

VECTORS = [
    {
        "name": "FIPS 197 Appendix B",
        "key":   bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c"),
        "plain": bytes.fromhex("3243f6a8885a308d313198a2e0370734"),
        "ctxt":  bytes.fromhex("3925841d02dc09fbdc118597196a0b32"),
    },
    {
        "name": "FIPS 197 C.1 key (OpenSSL verified)",
        "key":   bytes.fromhex("000102030405060708090a0b0c0d0e0f"),
        "plain": bytes.fromhex("00112233445566778899aabbccddeeff"),
        "ctxt":  bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a"),
    },
    {
        "name": "All-zero key and plaintext",
        "key":   bytes(16),
        "plain": bytes(16),
        "ctxt":  bytes.fromhex("66e94bd4ef8a2c3b884cfa59ca342b2e"),
    },
    {
        "name": "NIST SP 800-38A F.1.1",
        "key":   bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c"),
        "plain": bytes.fromhex("6bc1bee22e409f96e93d7e117393172a"),
        "ctxt":  bytes.fromhex("3ad77bb40d7a3660a89ecaf32466ef97"),
    },
]


def run_vectors() -> int:
    print("=" * 60)
    print("Correctness verification (FIPS 197 / NIST SP 800-38A)")
    print("=" * 60)
    failures = 0
    for v in VECTORS:
        result = aes128_encrypt(v["plain"], v["key"])
        status = "PASS" if result == v["ctxt"] else "FAIL"
        if status == "FAIL":
            failures += 1
        print(f"  {status}  {v['name']}")
        if status == "FAIL":
            print(f"       got:      {result.hex()}")
            print(f"       expected: {v['ctxt'].hex()}")
    print()
    return failures


# ── Throughput benchmark ──────────────────────────────────────────────────────

def benchmark_software(n_blocks: int = 50_000) -> float:
    """Return throughput in MB/s for pure-Python AES-128."""
    key   = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
    plain = bytes.fromhex("3243f6a8885a308d313198a2e0370734")
    t0 = time.perf_counter()
    for _ in range(n_blocks):
        aes128_encrypt(plain, key)
    elapsed = time.perf_counter() - t0
    bytes_total = n_blocks * 16
    return bytes_total / elapsed / 1e6   # MB/s


def hardware_throughput(freq_mhz: float) -> dict:
    """
    Theoretical hardware throughput for the pipelined AES-128 core.

    Parameters:
      freq_mhz : target clock frequency in MHz
                 iCEstick (iCE40HX1K) achieves ~80–100 MHz for this design.
                 Xilinx Artix-7 achieves ~200–250 MHz.

    Pipeline parameters:
      Stages    : 11 (initial ARK + 9 full rounds + 1 final round)
      Throughput: 1 block / clock cycle (pipeline is always full after fill)
      Latency   : 11 clock cycles
      Block size: 128 bits = 16 bytes
    """
    blocks_per_sec = freq_mhz * 1e6          # one block per cycle
    throughput_mbps = blocks_per_sec * 16 / 1e6
    latency_ns = 11 / freq_mhz * 1e3
    return {
        "freq_mhz":       freq_mhz,
        "throughput_mbps": throughput_mbps,
        "latency_ns":      latency_ns,
        "blocks_per_sec":  blocks_per_sec,
    }


def print_comparison(sw_mbps: float) -> None:
    targets = [
        ("iCEstick (iCE40HX1K)", 80),
        ("Artix-7 XC7A35T",      220),
        ("Kintex-7 XC7K70T",     300),
    ]

    print("=" * 60)
    print("Throughput comparison: hardware vs software")
    print("=" * 60)
    print(f"  Python software AES-128:  {sw_mbps:8.2f} MB/s")
    print()
    print(f"  {'Target':<28} {'Freq':>8}  {'Throughput':>12}  {'Speedup':>8}  {'Latency':>9}")
    print("  " + "-" * 56)
    for name, freq in targets:
        hw = hardware_throughput(freq)
        speedup = hw["throughput_mbps"] / sw_mbps
        print(f"  {name:<28} {freq:>6} MHz  "
              f"{hw['throughput_mbps']:>9.0f} MB/s  "
              f"{speedup:>6.0f}x  "
              f"{hw['latency_ns']:>7.1f} ns")
    print()
    print("  Pipeline depth : 11 stages (1 block / cycle throughput)")
    print("  Block size     : 128 bits")
    print("  Key size       : 128 bits")
    print("  S-box impl     : synchronous ROM (inferred from case statement)")
    print("  Key schedule   : combinational (new key ready in 1 cycle)")


if __name__ == "__main__":
    failures = run_vectors()
    if failures:
        print(f"WARNING: {failures} test vector(s) failed — throughput numbers may be unreliable.\n")

    print("Benchmarking Python AES (50 000 blocks) ...")
    sw_mbps = benchmark_software(50_000)
    print(f"Done. {sw_mbps:.2f} MB/s\n")

    print_comparison(sw_mbps)
