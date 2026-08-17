# RISC-V SoC

A five-stage RV32I core, an AES-128 accelerator, UART and SPI IP, a
ring-oscillator TRNG, and three graphics/audio designs — plus the thing that
turns eight separate FPGA projects into one system: **a memory map both the
hardware and the firmware are generated from**, and a build harness that knows
how to simulate Verilog, SystemVerilog and VHDL.

```
soc modules              # what is here, in which HDL, and how to run it
soc map                  # the memory map
soc gen                  # regenerate the SV header, the C header and the firmware
soc sim                  # simulate everything, including the SoC
soc lint                 # Verilator lint over the synthesisable RTL
```

```
$ soc sim

  core:riscv                 PASS                                 9.6s
  uart-spi:uart              PASS                                45.3s
  uart-spi:spi               PASS                                25.2s
  aes:core                   PASS                                 0.8s
  trng:trng                  PASS                                 0.2s
  pong:ball                  PASS                                 0.0s
  mandelbrot:mandelbrot      PASS                                25.2s
  synth:synth                PASS                               170.1s
  core:soc                   PASS                                29.5s
```

## The SoC

```
$ soc sim --only soc

  SoC: RV32I core + UART + AES over the generated memory map

  PASS: core executed instructions
  PASS: program reached the AES window
  PASS: program reached the UART window
  PASS: AES produced the FIPS-197 ciphertext
```

That last line is the whole point. A program — assembled by `socgen/asm.py`
from the addresses in `socgen/memmap.py` — runs on the RISC-V core, is routed by
the address decoder in `rtl/soc_top.sv`, drives the AES accelerator through a
register adapter, and produces the FIPS-197 §C.1 ciphertext. None of the eight
projects could test that alone, because none of them contained more than one
piece of it.

| Region | Base | Size | Purpose |
|---|---|---|---|
| `ram` | `0x00000000` | 64 kB | Data memory |
| `uart` | `0x10000000` | 4 kB | UART with FIFO |
| `spi` | `0x10001000` | 4 kB | SPI master |
| `aes` | `0x20000000` | 4 kB | AES-128 accelerator |
| `trng` | `0x30000000` | 4 kB | Entropy source (VHDL; attaches at synthesis) |

The map is a Python table. `soc gen` emits `rtl/soc_map.svh` for the decoder,
`sw/soc_map.h` for firmware, and the test program — and a test fails if the
committed headers no longer match the table. A memory map that exists in three
places drifts, and the symptom is a store that silently goes nowhere.

## The eight modules

| Module | HDL | What it is |
|---|---|---|
| [`core`](modules/core) | SystemVerilog | Five-stage RV32I: hazard detection, forwarding, branch prediction, performance counters. |
| [`aes`](modules/aes) | Verilog | Round-based AES-128 with an AXI-lite wrapper, checked against FIPS-197. |
| [`uart-spi`](modules/uart-spi) | SystemVerilog | Parameterised UART with a synchronous FIFO; SPI master covering all four modes. |
| [`trng`](modules/trng) | VHDL | Ring-oscillator entropy, von Neumann de-biasing, AES-S-box whitening, NIST STS tooling. |
| [`cpu8`](modules/cpu8) | Verilog | An 8-bit accumulator machine with its own assembler and a Python ISS to check the RTL against. |
| [`pong`](modules/pong) | Verilog | VGA timing, sprites, collision, scoring — a game in fabric. |
| [`mandelbrot`](modules/mandelbrot) | VHDL | Fixed-point Mandelbrot into a framebuffer and VGA, with a Python model of the arithmetic. |
| [`synth`](modules/synth) | Verilog | Polyphonic synthesiser: voice allocation, DDS, biquad filter, PWM DAC. |

## The build harness

Each project knew how to build itself and none of it was written down. What
`socgen/toolchain.py` encodes, and the tests exercise:

- The core is SystemVerilog with a `localparam` assignment pattern **Icarus
  rejects**, so it needs Verilator.
- Several modules `` `include `` a package by bare filename, so the tool has to
  run **from the module's own directory**. From anywhere else the include is
  simply not found.
- The GHDL packaged on Debian uses the mcode backend, where `ghdl -e` writes no
  binary at all; VHDL is analysed and then run with `ghdl -r`.
- A VHDL testbench with free-running oscillators never terminates, so it needs
  `--stop-time`.
- **A simulator exits zero after a failed assertion**, so every bench declares a
  string it prints when it is satisfied, and the harness checks for that rather
  than trusting the return code.

## What putting them together found

**The two AES S-boxes agree.** The accelerator has one in Verilog; the TRNG's
whitener has one in VHDL. Same 256 bytes, written twice, in different syntax,
never compared — until a test parsed both. They match, and both are proper
permutations. That test would have caught a single-digit typo that no amount of
reading would.

**Five real defects in the core**, all invisible to its own twenty-one-test
bench, all now fixed with committed reproducers.

1. **A single-instruction loop body ran once too many.** A redirect has to kill
   two fetched instructions, not one: the memory reads synchronously, so at
   resolution there is one instruction in IF/ID and another still inside the
   memory, fetched from the wrong path. The flush cleared only the first — and
   on a single-instruction body the second one *is* the body.
2. **The predictor redirected on instructions that were not branches.** The BHT
   and BTB were indexed by `PC[7:2]` with no tag, and a prediction is made from
   the PC alone, before the instruction is decoded. A NOP 256 bytes from a
   taken branch inherited its entry and jumped the core into a loop it had
   already left, with nothing to correct it since `mispredicted` required
   `ex_branch_valid`. Defect 1 had been *masking* this one.
3. **Every load returned the previous access's word.** The data memory is
   synchronous, so the word for the address issued in MEM arrives in WB — but
   MEM/WB registered the bus in MEM. It hid because the obvious test cannot see
   it: the core's own load test uses address 0 preceded by NOPs, whose
   `dmem_addr` is also 0, so the stale word is the right word by accident.
4. **A stall desynchronised the fetch pair.** A stall freezes `pc_reg`,
   `pc_fetch` and IF/ID, but cannot freeze `imem_data` — the memory keeps
   returning whatever `imem_addr` points at, and that was `pc_reg`, one ahead
   of `pc_fetch`. IF/ID then latched a PC paired with the wrong instruction, and
   a branch arriving under its predecessor's PC wrote a BTB entry for an
   address that is not a branch.
5. **A redirect was discarded by a stall.** `pc_reg` updated only when
   `!stall_if`, so a correction computed during a stall was thrown away.

3, 4 and 5 together are why a status poll never terminated — for a long time
recorded, wrongly, as "loads from a peripheral do not reach the register file".
A poll is a load followed by a branch on the loaded value: the shortest program
that needs the fetch pipeline, the load path and the predictor all correct at
once. The firmware polls `STATUS.done` now rather than waiting a fixed 32
cycles.

Every one of these was found by *committing the reproducer failing*. That is
the point of them: a defect in prose gets argued about, while one with a
reproducer is a fixed target — and the day someone fixes it, the suite says so.
It did, five times.

## Using one module on its own

```bash
cd modules/core       && verilator --binary -y rtl --top-module tb_riscv rtl/*.sv sim/tb_riscv.sv
cd modules/aes        && iverilog -o aes.vvp rtl/*.v sim/tb_aes128_core.v && vvp aes.vvp
cd modules/trng       && ghdl -a --std=08 rtl/*.vhd sim/*.vhd && ghdl -r --std=08 tb_trng --stop-time=500us
cd modules/cpu8       && python sim/sim.py
```

Or `soc sim --only aes`, which does the same thing with the flags already right.

## Tests

```bash
pytest -m "not slow"     # 69 tests: map, assembler, S-box cross-check — under a second
pytest                   # adds every hardware simulation, several minutes
```

## Licence

MIT — see [LICENSE](LICENSE).
