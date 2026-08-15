"""socgen — the memory map, the firmware, and the build knowledge for this SoC.

    from socgen import memmap, firmware
    memmap.write()                       # SV and C headers from one table
    firmware.write("program.hex")        # a program using those same addresses

The eight hardware modules here are each complete on their own. What was
missing was the part that makes them a system: an address map both sides agree
on, and one place that knows how to build and simulate three HDLs.
"""

from . import asm, firmware, memmap, registry, toolchain

__version__ = "1.0.0"
__all__ = ["asm", "firmware", "memmap", "registry", "toolchain"]
