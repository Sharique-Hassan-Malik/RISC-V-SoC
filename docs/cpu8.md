# Architecture

## Overview

```
prog/*.asm  ──► c8asm.py  ──► prog.hex
                                │
                    ┌───────────┴───────────┐
                    │                       │
              sim/sim.py              rtl/imem.v
           (software model)               │
                    │               ┌──────┴──────┐
              tests/test_c8.py      │  cpu.v      │
                                    │  ├ regfile  │
                                    │  ├ alu      │
                                    │  ├ imem     │
                                    │  └ dmem     │
                                    └──────┬──────┘
                                           │
                                      rtl/top.v
                                           │
                                    Yosys + nextpnr
                                           │
                                    iCEstick (iCE40HX1K)
```

---

## ISA reference

### Registers

| Name | Width | Notes |
|---|---|---|
| R0–R7 | 8-bit | General purpose; R0 is hardwired to 0x00 |
| PC | 8-bit | Program counter (256-word instruction ROM) |
| SP | 8-bit | Stack pointer; initialised to 0xFF; grows downward in DRAM |
| FLAGS | 4-bit | {V, N, C, Z} — overflow, negative, carry, zero |

### Instruction encoding

All instructions are 16 bits wide.

```
R-type  [15:12]=op  [11:9]=rd  [8:6]=rs1  [5:3]=rs2  [2:0]=fn
I-type  [15:12]=op  [11:9]=rd  [8:0]=imm9  (LDI uses [7:0])
B-type  [15:12]=op  [11:9]=cc  [8:0]=off9  (signed 9-bit, PC-relative)
J-type  [15:12]=op  [11:8]=rsvd  [7:0]=addr8  (absolute)
```

### Opcode table

| Opcode | Mnemonic | Format | Operation |
|---|---|---|---|
| 0x0 | NOP | — | no operation |
| 0x1 | ADD rd, rs1, rs2 | R | rd ← rs1 + rs2 |
| 0x2 | SUB rd, rs1, rs2 | R | rd ← rs1 − rs2 |
| 0x3 | AND rd, rs1, rs2 | R | rd ← rs1 & rs2 |
| 0x4 | OR  rd, rs1, rs2 | R | rd ← rs1 \| rs2 |
| 0x5 | XOR rd, rs1, rs2 | R | rd ← rs1 ^ rs2 |
| 0x6 | SHF rd, rs1, fn  | R | fn=SHL/SHR/ROR |
| 0x7 | CMP rs1, rs2     | R | flags ← rs1 − rs2 (no writeback) |
| 0x8 | LDI rd, imm8     | I | rd ← zero_ext(imm8) |
| 0x9 | LD  rd, [rs1+imm6] | I | rd ← DRAM[rs1 + sign_ext(imm6)] |
| 0xA | ST  [rs1+imm6], rd | I | DRAM[rs1 + sign_ext(imm6)] ← rd |
| 0xB | BR  cc, off9     | B | if cc: PC ← PC + sign_ext(off9) |
| 0xC | JMP addr8        | J | PC ← addr8 |
| 0xD | CALL addr8       | J | DRAM[SP--] ← PC+1; PC ← addr8 |
| 0xE | RET              | — | PC ← DRAM[++SP] |
| 0xF | HLT              | — | halt execution |

### Condition codes (BR instruction)

| Code | Name | Condition |
|---|---|---|
| 000 | EQ | Z = 1 |
| 001 | NE | Z = 0 |
| 010 | LT | N = 1 |
| 011 | GE | N = 0 |
| 100 | CS | C = 1 |
| 101 | CC | C = 0 |
| 110 | ALW | always |
| 111 | NEV | never |

### Flag update rules

| Instruction | Z | N | C | V |
|---|---|---|---|---|
| ADD | ✓ | ✓ | carry out | signed overflow |
| SUB / CMP | ✓ | ✓ | borrow | signed overflow |
| AND / OR / XOR | ✓ | ✓ | 0 | 0 |
| SHF | ✓ | ✓ | shifted-out bit | 0 |
| LDI / LD | — | — | — | — |
| ST / BR / JMP / CALL / RET / HLT | — | — | — | — |

---

## RTL datapath (`rtl/cpu.v`)

The CPU is single-cycle: every instruction completes in exactly one clock.

```
PC ──► imem ──► insn[15:0]
                   │
               decode
               ├ op, rd, rs1, rs2, fn
               ├ imm8, imm9, addr8, imm6, cc
               │
       rs1_idx ─► regfile ──► rs1_val ──► alu.a
       rs2_idx ─► regfile ──► rs2_val ──► alu.b (or imm8 for LDI)
                                               │
                                          alu ──► alu_result, alu_flags_out
                                               │
            rf_wr_en ◄────────────────────────┘
            rf_wr_data

PC ──► +1 ──► pc_next (default)
           ├ BR:  pc + sign_ext(off9) if condition true
           ├ JMP/CALL: addr8
           └ RET: dmem[sp+1]

SP ──► sp_next:
           ├ CALL: sp - 1
           ├ RET:  sp + 1
           └ otherwise: sp (unchanged)

dmem write:
           ├ ST:   dmem[rs1 + imm6_sx] ← rd_val
           └ CALL: dmem[sp] ← pc + 1

dmem read:
           ├ LD:  rd ← dmem[rs1 + imm6_sx]
           └ RET: pc_next ← dmem[sp+1]
```

All combinational paths settle within the clock period. State (PC, SP, FLAGS,
register file, DRAM) is updated on the rising clock edge.

---

## ALU (`rtl/alu.v`)

Purely combinational. A 9-bit intermediate `wide` is used for ADD and SUB to
detect the carry out of bit 7. Overflow (V flag) is detected by checking the
sign bits of both inputs and the result:

```
V (ADD) = (~a7 & ~b7 & r7) | (a7 & b7 & ~r7)
V (SUB) = ( a7 & ~b7 & ~r7) | (~a7 & b7 & r7)
```

---

## Register file (`rtl/regfile.v`)

8 × 8-bit registers. R0 is hardwired to zero via the read logic:
`rd_data = (addr == 0) ? 8'h00 : regs[addr]`.
Writes to address 0 are silently discarded by the `if (wr_addr != 0)` guard.

Asynchronous read, synchronous write. The single write port is shared across
all write-back instructions (ADD, SUB, AND, OR, XOR, SHF, LDI, LD).

---

## Assembler (`asm/c8asm.py`)

Two-pass assembler:

**Pass 1** — scan all lines, assign instruction addresses, collect label
definitions into a `{name: address}` dictionary. `.org N` changes the current
address counter without emitting an instruction.

**Pass 2** — encode each instruction into a 16-bit word. Label references are
resolved against the pass-1 dictionary. Branch offsets are computed as
`target_addr − branch_addr` (signed 9-bit, checked for overflow).

Output: a 256-line hex file (one 4-digit hex word per line) readable directly
by Verilog's `$readmemh`.

---

## Simulator (`sim/sim.py`)

Python model that replicates the RTL semantics exactly. Used for:
- Verifying assembler output before FPGA synthesis
- Running test programs and checking register and DRAM state
- Cycle counting

The simulator passes every test that the assembler tests use, providing
end-to-end coverage of the encoding → execution pipeline without needing
Icarus Verilog.

---

## Synthesis

Targeting the Lattice iCE40HX1K on iCEstick:

```bash
# Assemble the blink demo
python asm/c8asm.py prog/blink.asm -o rtl/prog.hex

# Synthesise and place-and-route
cd rtl
yosys -p "synth_ice40 -top top -json c8.json" top.v
nextpnr-ice40 --hx1k --package tq144 --pcf c8.pcf \
              --json c8.json --asc c8.asc
icepack c8.asc c8.bin
iceprog c8.bin
```

Estimated resource usage on iCE40HX1K:
- LUTs: ~400–600 (out of 1280)
- Block RAM: 1 (instruction ROM)
- Flip-flops: ~40 (PC, SP, FLAGS, halted)

---

## Test coverage

46 pytest assertions across two groups:

| Group | Tests |
|---|---|
| Assembler encoding | NOP/HLT/RET fixed encodings; ADD/SUB/AND/OR/XOR/SHF/CMP R-type fields; LDI range check; LD/ST memory operand parsing; BR offset calculation; JMP/CALL address encoding; label resolution; .word/.org directives; error detection (unknown mnemonic, duplicate label); hex output line count |
| Simulator execution | LDI, R0 hardwire, ADD/SUB/AND/OR/XOR, SHL/SHR/ROR and carry output, CMP flag effects, ST+LD roundtrip, branch taken and not taken, JMP, CALL+RET stack mechanics, Fibonacci program (DRAM[0..7] verified), flag Z on zero result, carry on overflow, HLT freezes execution |
