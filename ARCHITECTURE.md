# Architecture

Eight hardware modules and the two things that make them a system: a memory map
generated for both sides of the hardware/software boundary, and a harness that
knows how to build three HDLs. Each module's own design is in [`docs/`](docs);
the SoC and its defects are in [`docs/soc.md`](docs/soc.md).

```
             socgen/                                   rtl/
   memmap.py ──► soc_map.svh ──────────────────► soc_top.sv (decode)
        │   └──► sw/soc_map.h                         │
        │                                          aes_regs.sv
   asm.py ──► firmware.py ──► program.hex ──► imem ──┘
        │
   toolchain.py ──► iverilog / verilator / ghdl
```

## One map, three consumers

`socgen/memmap.py` is a table of regions and registers. From it come the
SystemVerilog header the address decoder includes, the C header firmware would
include, and the addresses the test program is assembled with.

A map that exists in three places drifts, and the failure is unusually
unpleasant: the decoder says the peripheral is at one address, the software
writes to another, and the result is a store that silently goes nowhere — no
error, no exception, just a peripheral that never does anything.

A test regenerates both headers and compares them against what is committed, so
a changed map that was not regenerated fails the build rather than the board.

The UART's register offsets were taken *from* `uart_core.sv` rather than
invented, because a generated header that disagrees with the RTL is worse than
no header at all.

## An assembler, so the firmware uses the map

`socgen/asm.py` is enough RV32I to write twenty-instruction programs. It exists
instead of a RISC-V toolchain dependency, and instead of hand-encoded hex,
because it can `import socgen.memmap` — the firmware and the hardware take
their addresses from one table.

The one subtlety it encodes is `li`: `addi` sign-extends its 12-bit immediate,
so a low half with bit 11 set subtracts 0x1000 from the upper half and the
standard correction is to add 1 to the `lui` first. Forgetting it loads an
address 4 kB low, which — on a map with 4 kB peripheral windows — lands squarely
in the previous peripheral. There is a test for exactly that.

## A harness, because the build knowledge was unwritten

Every project could build itself and none of it was recorded. `toolchain.py`
holds it, and the tests run it:

- **Icarus cannot build the core.** It rejects a `localparam` assignment
  pattern in the RV32I package, so the core needs Verilator.
- **Tools must run from the module's own directory.** Several modules
  `` `include `` a package by bare filename; from anywhere else it is not found.
- **`ghdl -e` writes no binary** on the mcode backend Debian ships. VHDL is
  analysed with `-a` and run with `-r`, which elaborates in the same step.
- **VHDL testbenches with free-running oscillators never terminate**, so they
  carry a `--stop-time`.
- **A simulator exits zero after a failed assertion.** Every bench declares the
  string it prints when satisfied, and that — not the return code — decides
  pass or fail.

Two recipes were wrong when first written down and the harness caught both: the
Mandelbrot bench drives the whole design rather than the iterator, and the synth
needs `-g2012` for a declaration inside an unnamed block.

## The cross-HDL check

The AES S-box appears twice: Verilog in the accelerator, VHDL in the TRNG's
whitener. Same 256 bytes, two syntaxes, never compared.

The test parses both — a case statement pairing index with value, and an ordered
array — and asserts they agree, that each is a permutation of 0..255, and that
the landmarks match FIPS-197 Figure 7. A single transposed digit would be
invisible to inspection and fatal to the cipher, and this is the kind of check
that only becomes possible when the two files are in one repository.

## Test layout

`pytest -m "not slow"` runs the map, assembler and S-box checks in under a
second. `pytest` adds every hardware simulation, which takes minutes — the
synth bench alone runs a 460-microsecond simulation.

The `slow` marker is registered in `pyproject.toml` so the split is a supported
option rather than a convention someone has to remember.
