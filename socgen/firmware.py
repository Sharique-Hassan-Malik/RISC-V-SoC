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


# ---------------------------------------------------------------------------
# The timer-interrupt demonstration.
# ---------------------------------------------------------------------------

# CSR numbers, from docs/traps.md.
CSR_MSTATUS = 0x300
CSR_MIE     = 0x304
CSR_MTVEC   = 0x305
CSR_MEPC    = 0x341
CSR_MCAUSE  = 0x342

MIE_MTIE      = 1 << 7    # machine timer interrupt enable
MSTATUS_MIE   = 1 << 3    # global interrupt enable
TIMER_PERIOD  = 400       # mtime ticks between interrupts

# Where the handler leaves its evidence, as word offsets into RAM.
SLOT_MAIN   = 0    # incremented by the interrupted loop
SLOT_TICKS  = 1    # incremented by the handler
SLOT_CAUSE  = 2    # mcause as the handler saw it
SLOT_RESUME = 3    # mepc, to prove the handler saw where it came from


def build_timer_demo() -> Assembler:
    """A loop that is interrupted by the timer and resumes afterwards.

    The point is not that a handler runs. It is that the *interrupted* loop
    keeps counting after `mret`, which is the only thing that distinguishes a
    working trap from a core that jumped to the handler and never came back.

    Registers are split by convention rather than saved: the loop uses x1-x9
    and the handler x20 upward, so the handler needs no prologue. A handler
    that had to save context would be testing the store path, not the trap.
    """
    ram = memmap.region("ram")
    clint = memmap.region("clint")
    mtime_lo = clint.base + 0xBFF8
    mtimecmp_lo = clint.base + 0x4000
    mtimecmp_hi = clint.base + 0x4004

    asm = Assembler()

    # 0x000: step over the handler, which has to sit at an address known before
    # `mtvec` is written.
    asm.beq("x0", "x0", "start")

    handler_pc = asm.pc
    asm.label("handler")
    asm.addi("x21", "x21", 1)                 # ticks++
    asm.sw("x21", "x20", SLOT_TICKS * 4)
    asm.csrr("x26", CSR_MCAUSE)               # why we are here
    asm.sw("x26", "x20", SLOT_CAUSE * 4)
    asm.csrr("x27", CSR_MEPC)                 # where we will go back to
    asm.sw("x27", "x20", SLOT_RESUME * 4)

    # Re-arm. mtip is a level, so returning without moving the deadline
    # re-enters the handler immediately — see docs/traps.md.
    #
    # The three-step order matters: parking the low half at -1 keeps the
    # intermediate pair no smaller than either the old or the new value.
    asm.li("x25", -1)
    asm.sw("x25", "x24", 0)                   # 1: mtimecmp low = -1
    asm.sw("x0", "x28", 0)                    # 2: mtimecmp high = 0
    asm.lw("x23", "x22", 0)                   # mtime low
    asm.addi("x23", "x23", TIMER_PERIOD)
    asm.sw("x23", "x24", 0)                   # 3: mtimecmp low = deadline
    asm.mret()

    asm.label("start")
    asm.li("x20", ram.base)
    asm.li("x22", mtime_lo)
    asm.li("x24", mtimecmp_lo)
    asm.li("x28", mtimecmp_hi)
    asm.li("x21", 0)                          # tick count

    # First deadline.
    asm.li("x25", -1)
    asm.sw("x25", "x24", 0)
    asm.sw("x0", "x28", 0)
    asm.lw("x23", "x22", 0)
    asm.addi("x23", "x23", TIMER_PERIOD)
    asm.sw("x23", "x24", 0)

    # mtvec, then the timer enable, then the global enable. In that order: a
    # global enable set before mtvec points anywhere would send the first
    # interrupt to address zero.
    asm.li("x5", handler_pc)
    asm.csrw(CSR_MTVEC, "x5")
    asm.li("x6", MIE_MTIE)
    asm.csrw(CSR_MIE, "x6")
    asm.csrrsi("x0", CSR_MSTATUS, MSTATUS_MIE)

    # The interrupted work: count, store, repeat, forever.
    asm.li("x1", 0)
    asm.label("loop")
    asm.addi("x1", "x1", 1)
    asm.sw("x1", "x20", SLOT_MAIN * 4)
    asm.beq("x0", "x0", "loop")
    return asm


def write_timer_demo(path: str | Path) -> Path:
    return build_timer_demo().write_hex(path)
