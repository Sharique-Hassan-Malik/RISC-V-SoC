# FPGA & Digital Design

Hardware described in Verilog/SystemVerilog: soft CPUs (including a RISC-V core), reusable peripheral IP, a hardware AES accelerator, and graphics/audio demos, with Python testbenches and cocotb simulation.

A collection of 8 self-contained projects. Each lives in its own subdirectory with its own `README.md` and `LICENSE` (most also include an `ARCHITECTURE.md` and a test suite), and can be built and run independently.

## Projects

| project | what it is |
|---|---|
| [`AES128-Accelerator`](./AES128-Accelerator) | A fully pipelined AES-128 encryption core in Verilog with an AXI4-Lite slave wrapper, verified against FIPS 197 test vectors. |
| [`C8-CPU`](./C8-CPU) | A complete custom 8-bit RISC CPU implemented in Verilog, targeting the Lattice iCE40HX1K on an iCEstick. |
| [`FPGA-Poly-Synth`](./FPGA-Poly-Synth) | A 4-voice polyphonic synthesiser implemented in Verilog targeting the Lattice iCEstick (iCE40HX1K-TQ144). |
| [`FPGA-Pong`](./FPGA-Pong) | A complete two-player Pong game implemented as pure synchronous digital logic in Verilog. |
| [`FPGA-RISCV-Core`](./FPGA-RISCV-Core) | A 5-stage pipelined RV32I processor in SystemVerilog. |
| [`FPGA-TRNG`](./FPGA-TRNG) | A hardware True Random Number Generator for the Lattice iCEstick (iCE40HX1K) that harvests entropy from FPGA ring-oscillator jitter, decorrelates t… |
| [`FPGA-UART-SPI-IP`](./FPGA-UART-SPI-IP) | Parameterized, reusable UART and SPI master IP cores for FPGA designs. |
| [`FPGA-VGA-Mandelbrot`](./FPGA-VGA-Mandelbrot) | A 640×480 VGA display driven from a hardware-pipelined Mandelbrot set renderer written entirely in VHDL. |

## Repository layout

Each subdirectory is a standalone project; there is no shared build. Enter one and follow its README:

```bash
cd AES128-Accelerator
cat README.md
```

## License

MIT — see the `LICENSE` file in each project.
