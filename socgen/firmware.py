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

    # Poll STATUS.done.
    #
    # This was 32 NOPs for a long time, with a comment explaining that polling
    # did not work on this SoC because "loads from a peripheral do not reach
    # the register file". That diagnosis was wrong twice over. It was not the
    # peripheral read path, and it was not peripheral-specific: the core
    # sampled `dmem_rdata` at the end of MEM, one cycle before a synchronous
    # memory returns it, so *every* load got the word for whatever address the
    # bus carried before it. RAM loads looked fine only when that happened to
    # be the same address. See docs/soc.md.
    asm.label("wait")
    asm.lw("x2", "x1", 0x24)                 # STATUS.done
    asm.beq("x2", "x0", "wait")

    # A byte out of the UART, to show the other window decodes too.
    asm.li("x6", uart.base)
    asm.li("x7", 0x41)                        # 'A'
    asm.sw("x7", "x6", 0x00)

    asm.label("done")
    asm.beq("x0", "x0", "done")               # spin
    return asm


def write(path: str | Path) -> Path:
    return build().write_hex(path)
