#!/usr/bin/env python3
"""
collect.py — Read random bytes from the TRNG UART output and write them
             to a file or stdout.

The TRNG streams 16 bytes (one 128-bit AES block) at a time at 115200 baud.
This script reads bytes continuously, optionally limiting the total count,
and writes them to a binary file or stdout for piping to nist_sts.py.

Usage:
    # Collect 1 MB to file:
    python3 tools/collect.py /dev/ttyUSB0 --bytes 1048576 --out random.bin

    # Pipe directly to NIST test suite:
    python3 tools/collect.py /dev/ttyUSB0 --bytes 1048576 | \
        python3 tools/nist_sts.py

    # Collect indefinitely (Ctrl-C to stop):
    python3 tools/collect.py /dev/ttyUSB0

Requires: pyserial
    pip install pyserial
"""

import argparse
import sys
import time

try:
    import serial
    _SERIAL_OK = True
except ImportError:
    _SERIAL_OK = False


def collect(port: str, baud: int, n_bytes: int, out_path: str) -> None:
    if not _SERIAL_OK:
        sys.exit("Install pyserial: pip install pyserial")

    with serial.Serial(port, baud, timeout=5.0) as ser:
        if out_path:
            out = open(out_path, "wb")
        else:
            out = sys.stdout.buffer

        total = 0
        start = time.time()

        try:
            while n_bytes == 0 or total < n_bytes:
                want = 16 if n_bytes == 0 else min(16, n_bytes - total)
                chunk = ser.read(want)
                if not chunk:
                    sys.stderr.write("Read timeout\n")
                    break
                out.write(chunk)
                out.flush()
                total += len(chunk)

                elapsed = time.time() - start
                rate    = total / elapsed if elapsed > 0 else 0
                sys.stderr.write(
                    f"\r  Collected {total:>10} bytes  "
                    f"({rate/1024:.1f} KB/s)    "
                )
        except KeyboardInterrupt:
            sys.stderr.write("\n  Interrupted.\n")
        finally:
            elapsed = time.time() - start
            sys.stderr.write(f"\n  Total: {total} bytes in {elapsed:.1f} s\n")
            if out_path:
                out.close()


def main() -> None:
    p = argparse.ArgumentParser(description="Collect TRNG bytes from serial port")
    p.add_argument("port",             help="Serial port (e.g. /dev/ttyUSB0 or COM4)")
    p.add_argument("--baud",  type=int, default=115200, help="Baud rate (default 115200)")
    p.add_argument("--bytes", type=int, default=0,
                   help="Number of bytes to collect (0 = unlimited)")
    p.add_argument("--out",   default="", help="Output file (default: stdout)")
    args = p.parse_args()
    collect(args.port, args.baud, args.bytes, args.out)


if __name__ == "__main__":
    main()
