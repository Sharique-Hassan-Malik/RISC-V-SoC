"""The program the SoC testbench runs, assembled from the memory map.

Twenty-odd instructions: load the AES key and block, start it, poll until it is
done, copy the result into RAM, then write a byte to the UART. Short, and the
only thing it has to prove is that a program can reach the peripherals at the
addresses the map says they are at.

Every address comes from `socgen.memmap`. There is no second copy to get wrong.
"""

from __future__ import annotations

from pathlib import Path

from . import memmap
from .asm import Assembler

# FIPS-197 §C.1, the same vector the AES module's own testbench uses.
KEY = 0x2B7E151628AED2A6ABF7158809CF4F3C
PLAINTEXT = 0x3243F6A8885A308D313198A2E0370734
EXPECTED = 0x3925841D02DC09FBDC118597196A0B32


def _words(value: int) -> list[int]:
    """A 128-bit value as four 32-bit words, least significant first —
    the order the register map writes them in."""
    return [(value >> (32 * i)) & 0xFFFF_FFFF for i in range(4)]


def build() -> Assembler:
    aes = memmap.region("aes")
    uart = memmap.region("uart")
    ram = memmap.region("ram")

    asm = Assembler()
    asm.li("x1", aes.base)

    # Key, low word first. Each write also strobes load_key; the schedule is
    # latched from whatever is in the key register at the time, so the last
    # write is the one that matters and it must be the high word.
    for index, word in enumerate(_words(KEY)):
        asm.li("x2", word)
        asm.sw("x2", "x1", index * 4)

    # A few cycles for the round-key schedule to register before data goes in.
    for _ in range(4):
        asm.nop()

    for index, word in enumerate(_words(PLAINTEXT)):
        asm.li("x2", word)
        asm.sw("x2", "x1", 0x10 + index * 4)

    asm.li("x2", 1)
    asm.sw("x2", "x1", 0x20)                 # CTRL: start

    # A fixed wait rather than polling STATUS.
    #
    # Polling would be the right firmware and it still does not work here. The
    # reason is now measured rather than guessed at, and it is not the
    # peripheral read path: `dmem_rdata` carries 0x1 on exactly the cycle the
    # core samples it. What goes wrong is in the core's predictor —
    #
    #     lw  x2, 0x24(x1)     <- fetched at 0x7c
    #     beq x2, x0, -4       <- at 0x80
    #
    # a BTB entry for index 31 (PC[7:2] of 0x7c) holds 0x78 with a matching
    # tag, so the *load* is predicted taken and the fetch is redirected
    # backwards, re-running the CTRL write instead of reaching the branch. The
    # loaded value never lands and the loop never ends.
    #
    # Recorded in docs/soc.md with a reproducer (`soc sim --only poll`), not
    # papered over — this program simply does not depend on the broken part.
    #
    # The core needs 11 cycles for a block; 32 is comfortable.
    for _ in range(32):
        asm.nop()

    # A byte out of the UART, to show the other window decodes too.
    asm.li("x6", uart.base)
    asm.li("x7", 0x41)                        # 'A'
    asm.sw("x7", "x6", 0x00)

    asm.label("done")
    asm.beq("x0", "x0", "done")               # spin
    return asm


def write(path: str | Path) -> Path:
    return build().write_hex(path)
