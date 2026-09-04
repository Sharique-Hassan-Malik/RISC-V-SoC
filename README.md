# RISC-V SoC

A five-stage RV32I core, an AES-128 accelerator, UART and SPI IP, a
ring-oscillator TRNG, a CLINT, and three graphics/audio designs — nine separate
FPGA projects, plus the three things that let four of them become one system: **a
memory map both the hardware and the firmware are generated from**, a core that
can be **interrupted and resumed**, and a build harness that knows how to
simulate Verilog, SystemVerilog and VHDL.

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
  clint:clint                PASS                                 0.1s
  trng:trng                  PASS                                 0.2s
  pong:ball                  PASS                                 0.0s
  mandelbrot:mandelbrot      PASS                                25.2s
  synth:synth                PASS                               170.1s
  core:soc                   PASS                                29.5s
  core:traps                 PASS                                30.4s
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
register adapter, and produces the FIPS-197 §C.1 ciphertext. None of the nine
projects could test that alone, because none of them contains more than one
piece of it.

## Interrupts

```
$ soc sim --only traps

  after 3000 cycles: main=941 ticks=7 cause=80000007 mepc=00000088
  PASS  the timer interrupt fired
  PASS  it fired repeatedly (re-arming works)
  PASS  mcause is the machine timer interrupt (0x80000007)
  PASS  the interrupted loop kept running after mret
```

The UART has carried `IRQ_EN` and `IRQ_STAT` registers since it was written, and
for as long as the core had no CSRs that line went nowhere: the only way to use
the UART was to poll it. The core now implements machine-mode CSRs,
`ECALL`/`EBREAK`/`MRET` and precise traps, and the [`clint`](modules/clint)
supplies a timer to fire them.

The assertion that matters is the last one. A core that jumped to `mtvec` and
never came back would satisfy "the handler ran"; only the interrupted loop
*continuing to count* shows that `mepc` was right and `mret` returned to it.
[`docs/traps.md`](docs/traps.md) is the specification.

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

## The nine projects

| Project | HDL | What it is |
|---|---|---|
| [`core`](modules/core) | SystemVerilog | Five-stage RV32I: hazard detection, forwarding, branch prediction, machine-mode CSRs and precise traps. |
| [`clint`](modules/clint) | SystemVerilog | The machine timer and software interrupt — a 64-bit `mtime`, an `mtimecmp`, and `msip`. |
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
