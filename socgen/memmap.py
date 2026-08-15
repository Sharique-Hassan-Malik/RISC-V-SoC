"""The SoC memory map: defined once, emitted for the RTL, the firmware and the tests.

A memory map that exists in three places drifts. The address decoder says a
peripheral is at `0x2000_0000`, the C header says `0x2000_1000`, and the symptom
is a store that silently goes nowhere — no error, no exception, just a
peripheral that never does anything. It is one of the least pleasant classes of
hardware/software bug, and it is entirely avoidable.

So the map is data here, and everything else is generated from it:

    socgen memmap --sv rtl/soc_map.svh --c sw/soc_map.h

A test regenerates both and compares them against what is committed, so a
changed map that was not regenerated fails the build rather than the board.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Region:
    """One decoded region of the address space."""

    name: str
    base: int
    size: int
    kind: str                       # "memory" | "peripheral"
    description: str
    registers: tuple[tuple[str, int, str], ...] = ()   # (name, offset, meaning)

    @property
    def limit(self) -> int:
        return self.base + self.size - 1

    @property
    def upper(self) -> str:
        return self.name.upper().replace("-", "_")

    def contains(self, address: int) -> bool:
        return self.base <= address <= self.limit


# The decode is on the top nibble, which is why every base is 0x_0000_0000
# aligned: a four-bit comparison is one LUT level, and an SoC this size does not
# need a finer split.
MAP: tuple[Region, ...] = (
    Region(
        "ram", 0x0000_0000, 64 * 1024, "memory",
        "Data memory. The core's instruction memory is separate and not on this bus.",
    ),
    Region(
        "uart", 0x1000_0000, 4 * 1024, "peripheral",
        "UART transmitter and receiver with a synchronous FIFO.",
        # Taken from uart_core.sv's own register map, not invented here: a
        # generated header that disagrees with the RTL is worse than no header.
        registers=(
            ("DATA", 0x00, "write: byte to transmit; read: oldest received byte"),
            ("STAT", 0x04, "status flags, read-only"),
            ("DIV", 0x08, "baud divisor: CLK_HZ/baud - 1"),
            ("CTRL", 0x0C, "frame format"),
            ("IRQ_EN", 0x10, "interrupt enable mask"),
            ("IRQ_STAT", 0x14, "interrupt status, write 1 to clear"),
        ),
    ),
    Region(
        "spi", 0x1000_1000, 4 * 1024, "peripheral",
        "SPI master covering all four clock modes.",
        registers=(
            ("DATA", 0x0, "write starts a transfer; read returns the received byte"),
            ("STATUS", 0x4, "bit0 busy"),
            ("CONFIG", 0x8, "bit0 CPOL, bit1 CPHA, bits15:8 clock divisor"),
        ),
    ),
    Region(
        "aes", 0x2000_0000, 4 * 1024, "peripheral",
        "AES-128 accelerator. Key and block are written 32 bits at a time.",
        registers=(
            ("KEY0", 0x00, "key bits 31:0"),
            ("KEY1", 0x04, "key bits 63:32"),
            ("KEY2", 0x08, "key bits 95:64"),
            ("KEY3", 0x0C, "key bits 127:96"),
            ("DATA0", 0x10, "plaintext bits 31:0"),
            ("DATA1", 0x14, "plaintext bits 63:32"),
            ("DATA2", 0x18, "plaintext bits 95:64"),
            ("DATA3", 0x1C, "plaintext bits 127:96"),
            ("CTRL", 0x20, "write 1 to start"),
            ("STATUS", 0x24, "bit0 done"),
            ("OUT0", 0x30, "ciphertext bits 31:0"),
            ("OUT1", 0x34, "ciphertext bits 63:32"),
            ("OUT2", 0x38, "ciphertext bits 95:64"),
            ("OUT3", 0x3C, "ciphertext bits 127:96"),
        ),
    ),
    Region(
        "trng", 0x3000_0000, 4 * 1024, "peripheral",
        "Ring-oscillator entropy source, von Neumann de-biased and whitened. "
        "VHDL, so it attaches at synthesis rather than in the mixed-language "
        "simulation.",
        registers=(
            ("DATA", 0x0, "read: one whitened random byte"),
            ("STATUS", 0x4, "bit0 valid"),
        ),
    ),
)

_BY_NAME = {region.name: region for region in MAP}


def region(name: str) -> Region:
    try:
        return _BY_NAME[name]
    except KeyError:
        raise KeyError(
            f"unknown region {name!r}; choose from {', '.join(sorted(_BY_NAME))}"
        ) from None


def decode(address: int) -> Region | None:
    """Which region an address lands in, or None — the software mirror of the
    hardware decoder, and what makes an unmapped access testable."""
    for entry in MAP:
        if entry.contains(address):
            return entry
    return None


def overlaps() -> list[tuple[str, str]]:
    """Any two regions that collide. Should always be empty; asserted in tests."""
    found = []
    for i, first in enumerate(MAP):
        for second in MAP[i + 1:]:
            if first.base <= second.limit and second.base <= first.limit:
                found.append((first.name, second.name))
    return found


_BANNER = "Generated by socgen/memmap.py. Do not edit; edit the map and regenerate."


def to_systemverilog() -> str:
    """A header of localparams for the address decoder."""
    lines = [
        "// " + _BANNER,
        "",
        "`ifndef SOC_MAP_SVH",
        "`define SOC_MAP_SVH",
        "",
    ]
    for entry in MAP:
        lines.append(f"// {entry.description}")
        lines.append(f"localparam logic [31:0] {entry.upper}_BASE = 32'h{entry.base:08X};")
        lines.append(f"localparam logic [31:0] {entry.upper}_SIZE = 32'h{entry.size:08X};")
        lines.append(f"localparam logic [31:0] {entry.upper}_LIMIT = 32'h{entry.limit:08X};")
        for name, offset, meaning in entry.registers:
            lines.append(
                f"localparam logic [31:0] {entry.upper}_{name} = "
                f"32'h{entry.base + offset:08X};  // {meaning}"
            )
        lines.append("")
    lines += ["`endif", ""]
    return "\n".join(lines)


def to_c() -> str:
    """The same map as a firmware header."""
    lines = [
        "/* " + _BANNER + " */",
        "",
        "#ifndef SOC_MAP_H",
        "#define SOC_MAP_H",
        "",
        "#include <stdint.h>",
        "",
        "#define MMIO(addr) (*(volatile uint32_t *)(addr))",
        "",
    ]
    for entry in MAP:
        lines.append(f"/* {entry.description} */")
        lines.append(f"#define {entry.upper}_BASE  0x{entry.base:08X}u")
        lines.append(f"#define {entry.upper}_SIZE  0x{entry.size:08X}u")
        for name, offset, meaning in entry.registers:
            lines.append(
                f"#define {entry.upper}_{name}  0x{entry.base + offset:08X}u  /* {meaning} */"
            )
        lines.append("")
    lines += ["#endif /* SOC_MAP_H */", ""]
    return "\n".join(lines)


def to_markdown() -> str:
    """The map as a table, for the README."""
    lines = ["| Region | Base | Size | Kind | Purpose |", "|---|---|---|---|---|"]
    for entry in MAP:
        size = f"{entry.size // 1024} kB" if entry.size >= 1024 else f"{entry.size} B"
        lines.append(
            f"| `{entry.name}` | `0x{entry.base:08X}` | {size} | {entry.kind} | "
            f"{entry.description.splitlines()[0]} |"
        )
    return "\n".join(lines)


DEFAULT_SV = REPO_ROOT / "rtl" / "soc_map.svh"
DEFAULT_C = REPO_ROOT / "sw" / "soc_map.h"


def write(sv_path: Path | None = None, c_path: Path | None = None) -> list[Path]:
    """Emit both headers. Returns what was written."""
    written = []
    for path, text in ((sv_path or DEFAULT_SV, to_systemverilog()),
                       (c_path or DEFAULT_C, to_c())):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        written.append(path)
    return written
