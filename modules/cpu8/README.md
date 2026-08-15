# C8 — Custom 8-bit RISC CPU on FPGA

> Part of the [RISC-V SoC](../../README.md). Simulates standalone from this
> folder, or through `soc sim --only <name>`, which already knows the flags.

A complete custom 8-bit RISC CPU implemented in Verilog, targeting the Lattice iCE40HX1K on an iCEstick. Includes a two-pass assembler, a cycle-accurate software simulator, three demo programs and a full test suite.

No soft-core templates. No vendor IP. The ISA, RTL, assembler and simulator are all written from scratch.

## What's included

| Component | File(s) | Description |
|---|---|---|
| ISA spec | `rtl/c8_isa.h` | Complete ISA reference |
| ALU | `rtl/alu.v` | 16-opcode combinational ALU with flags |
| Register file | `rtl/regfile.v` | 8 × 8-bit, R0 hardwired to zero |
| Instruction ROM | `rtl/imem.v` | 256 × 16-bit, `$readmemh` initialised |
| Data RAM | `rtl/dmem.v` | 256 × 8-bit synchronous-write RAM |
| CPU core | `rtl/cpu.v` | Single-cycle datapath, all 16 instructions |
| iCEstick top | `rtl/top.v` | Reset logic + LED output |
| Pin constraints | `rtl/c8.pcf` | iCEstick LED and clock pins |
| Assembler | `asm/c8asm.py` | Two-pass, produces `$readmemh`-compatible hex |
| Simulator | `sim/sim.py` | Cycle-accurate Python model |
| Fibonacci | `prog/fibonacci.asm` | Computes F(0)–F(12), stores in DRAM |
| Bubble sort | `prog/sort.asm` | In-place sort of 8 DRAM bytes |
| LED blink | `prog/blink.asm` | Chasing LED pattern for iCEstick demo |
| Tests | `tests/test_c8.py` | 46 pytest assertions |

## ISA summary

8 registers (R0–R7, R0 = 0), 8-bit data, 256-word instruction ROM, 256-byte DRAM. Fixed 16-bit instruction width.

```
ADD  R3, R1, R2      ; R-type ALU
LDI  R1, 42          ; load immediate (0–255)
LD   R2, [R1+4]      ; load from DRAM[R1+4]
ST   [R1+0], R3      ; store to DRAM[R1]
BR   EQ, label       ; branch on condition code
JMP  label           ; unconditional absolute jump
CALL sub             ; push PC+1, jump to sub
RET                  ; pop PC from stack
HLT                  ; halt
```

Condition codes: `EQ NE LT GE CS CC ALW NEV`
Shift operations: `SHF R2, R1, SHL` / `SHR` / `ROR`

Full ISA reference: `rtl/c8_isa.h` and `docs/architecture.md`.

## Project structure

```
c8-cpu/
├── rtl/
│   ├── c8_isa.h         ISA constant definitions
│   ├── alu.v            combinational ALU
│   ├── regfile.v        8 × 8-bit register file
│   ├── imem.v           instruction ROM
│   ├── dmem.v           data RAM
│   ├── cpu.v            single-cycle CPU core
│   ├── top.v            iCEstick top-level
│   └── c8.pcf           pin constraints
├── asm/
│   └── c8asm.py         two-pass assembler
├── sim/
│   └── sim.py           cycle-accurate simulator
├── prog/
│   ├── fibonacci.asm    Fibonacci sequence demo
│   ├── sort.asm         bubble sort demo
│   └── blink.asm        iCEstick LED blink demo
├── tests/
│   └── test_c8.py       46 pytest assertions
└── docs/
    └── architecture.md
```

## Running the tests

No toolchain required — just Python:

```bash
pip install pytest
pytest tests/test_c8.py -v
```

## Assembling a program

```bash
python asm/c8asm.py prog/fibonacci.asm -o rtl/prog.hex
python asm/c8asm.py prog/blink.asm --list    # annotated listing
```

## Simulating

```bash
python sim/sim.py prog/fibonacci.asm --cycles 50000 --dump
python sim/sim.py prog/sort.asm --trace       # print each instruction
```

## Synthesising for iCEstick

Install the open-source iCE40 toolchain: [icestorm](https://clifford.at/icestorm/)

```bash
# Assemble the blink demo
python asm/c8asm.py prog/blink.asm -o rtl/prog.hex

# Synthesise
cd rtl
yosys -p "synth_ice40 -top top -json c8.json" top.v

# Place and route
nextpnr-ice40 --hx1k --package tq144 --pcf c8.pcf \
              --json c8.json --asc c8.asc

# Pack and flash
icepack c8.asc c8.bin
iceprog c8.bin
```

After programming, the five green LEDs on the iCEstick chase left and right at approximately 1 Hz.

## Design decisions

**Single-cycle execution.** Every instruction completes in one clock. No pipeline hazards, no forwarding logic. At 12 MHz the CPU executes 12 million instructions per second — more than sufficient for embedded demos.

**R0 hardwired to zero.** Eliminates a dedicated "load zero" instruction. `ADD Rd, R0, Rs` copies Rs to Rd; `SUB Rd, Rs, R0` is a no-op move. This pattern appears throughout the demo programs.

**16-bit instruction word.** Gives enough bits for a 4-bit opcode, two 3-bit register fields, and either a 9-bit signed immediate or a separate 3-bit function field. The branch offset fits in 9 signed bits, covering ±256 instructions from any point in the 256-word ROM.

**Harvard architecture.** Separate instruction ROM and data RAM eliminates structural hazards between fetch and data memory access in the single-cycle design.

**Fixed stack in DRAM.** The stack lives at the top of DRAM (SP starts at 0xFF). `CALL` pushes the return address with a single synchronous DRAM write; `RET` reads it back. No separate stack memory is needed.
