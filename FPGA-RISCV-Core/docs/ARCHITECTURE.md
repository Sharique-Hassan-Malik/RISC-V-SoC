# Architecture

## Overview

A 5-stage pipelined RV32I processor implemented in SystemVerilog.  The
pipeline covers the full base integer ISA including load/store with
byte-enable, all branch types, JAL and JALR.  Data hazards are resolved
by full data forwarding; a one-cycle bubble is inserted only for
load-use hazards.  A 2-bit saturating counter branch predictor with a
direct-mapped branch target buffer reduces branch misprediction penalties.
Five hardware performance counters track cycles, instructions retired,
branch count, misprediction count and stall cycles.

---

## Pipeline Stages

```
 IF        ID        EX        MEM       WB
────────  ────────  ────────  ────────  ────────
 PC reg   RegFile   ALU       DMem      Mux
 BHT/BTB  Decoder   AABB      Byte-ext  RegWrite
 IMEM     ImmGen    Fwd mux
          → ctrl    Branch
```

### IF — Instruction Fetch

Maintains the 32-bit PC and interfaces with the synchronous instruction memory
(word-addressed, 1-cycle latency — the register appears at the IF/ID boundary
the cycle after the address is presented).

**Branch prediction (2-bit saturating counter BHT + BTB):**

The Branch History Table has 64 entries indexed by `PC[7:2]`.  Each entry
holds a 2-bit saturating counter:
```
00 = Strongly Not Taken
01 = Weakly   Not Taken  ← initial state
10 = Weakly   Taken
11 = Strongly Taken
```

When the counter's MSB is 1 the branch is predicted taken and the PC is
redirected to the address stored in the matching BTB entry.  Otherwise the
PC advances to PC+4.

The BTB is a direct-mapped cache with 64 entries indexed the same way as
the BHT.  It stores the branch target address seen most recently at that
index.  On a correctly predicted taken branch the PC redirects without
any penalty cycle.

**Resolution and flush:**

When the EX stage resolves a branch (`ex_branch_valid`):
- The BHT counter is updated (increment on taken, decrement on not-taken).
- The BTB target is updated to the resolved target.
- A misprediction is detected when `actual_taken ≠ bht[idx][1]`.
  - On misprediction: PC is corrected; IF/ID and ID/EX are flushed (2-cycle penalty).
  - On correct prediction: no action.

JAL and JALR are always resolved in EX and always flush 2 stages.

### ID — Instruction Decode

The register file has two asynchronous read ports.  Write-through from WB
ensures the register file value is always current — no separate WB→ID
forwarding mux is needed in the stage itself.

The immediate generator supports all five RV32I immediate formats (I, S, B,
U, J) by examining the opcode field and rearranging instruction bits
according to the encoding table.

The control decoder produces a `ctrl_t` packed struct covering:
`reg_write`, `mem_read`, `mem_write`, `mem_to_reg`, `branch`, `jal`,
`jalr`, `alu_src`, `lui`, `auipc`, `alu_op`, `funct3`.

### EX — Execute

**Data forwarding:**

Two forwarding muxes (one per ALU input) with 3-way selection:
```
fwd_a/b = 2'b00  →  register file value (from ID/EX pipeline register)
fwd_a/b = 2'b01  →  EX/MEM ALU result  (MEM stage, 1 cycle old)
fwd_a/b = 2'b10  →  WB data            (WB stage,  2 cycles old)
```

MEM-stage forwarding takes priority when both MEM and WB sources match
the same register (e.g. two consecutive writes to the same rd).

**ALU:**

12-operation ALU: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND,
LUI (pass-through for U-type immediates), and AUIPC (uses PC as operand A).

**Branch evaluation:**

The branch comparator evaluates the funct3-encoded condition against the
ALU output:
- BEQ/BNE: check ALU SUB result == 0 or ≠ 0
- BLT/BGE: check ALU_SLT result == 1 or == 0
- BLTU/BGEU: check ALU_SLTU result

The resolved target `PC + imm` (B-type) or `(rs1 + imm) & ~1` (JALR) is
sent to the IF stage.

### MEM — Memory Access

Generates byte-enables for sub-word stores:
```
SB: be = 4'b0001 << addr[1:0]
SH: be = addr[1] ? 4'b1100 : 4'b0011
SW: be = 4'b1111
```

Load sign/zero extension is performed combinationally after the synchronous
memory read:
- LB: sign-extend byte at `addr[1:0]`
- LBU: zero-extend
- LH/LHU: halfword at `addr[1]`
- LW: 32-bit word (no extension)

### WB — Write-Back

A simple 2-to-1 mux: ALU result or memory read data, selected by
`ctrl.mem_to_reg`.  The write-enable and data are forwarded to the ID stage
register file write port.

---

## Hazard Unit

### Load-use stall

```
detect = (id_ex_ctrl.mem_read)
       & ((id_ex_rd == id_rs1 && id_rs1 ≠ 0)
       |  (id_ex_rd == id_rs2 && id_rs2 ≠ 0))
```

When detected:
- Stall IF and ID (PC and IF/ID pipeline register hold their values).
- Insert a bubble (NOP) into the ID/EX register.

This produces exactly one stall cycle — the load result is then available in
the EX/MEM register for MEM→EX forwarding on the next cycle.

### Forwarding priority

```
if EX/MEM.reg_write && EX/MEM.rd == EX.rs1 → fwd_a = MEM  (01)
if MEM/WB.reg_write && MEM/WB.rd == EX.rs1
   && !(EX/MEM match)                       → fwd_a = WB   (10)
else                                         → fwd_a = ID   (00)
```

Symmetric for fwd_b.

---

## Performance Counters

| Counter | Description |
|---|---|
| `perf_cycles` | Total clock cycles |
| `perf_instret` | Instructions retired (non-bubble instructions leaving WB) |
| `perf_branches` | Total branch instructions resolved |
| `perf_mispredicts` | Branch mispredictions (IF flush events) |
| `perf_stall_cycles` | Cycles spent stalled on load-use hazards |

CPI (cycles per instruction) = `perf_cycles / perf_instret`.
Misprediction rate = `perf_mispredicts / perf_branches`.

For a tight 64-iteration loop the branch predictor should achieve ≤ 3
mispredictions (the first few warmup iterations before the counter saturates
to Strongly Taken), yielding a misprediction rate below 5%.

---

## Pipeline Diagram (no hazards)

```
Cycle:  1   2   3   4   5   6   7
Instr1: IF  ID  EX  MEM WB
Instr2:     IF  ID  EX  MEM WB
Instr3:         IF  ID  EX  MEM WB
```

**Load-use stall:**
```
Cycle:  1   2   3   4   5   6   7   8
LW:     IF  ID  EX  MEM WB
ADD:        IF  ID  **  EX  MEM WB      ** = bubble (stall)
```

**Mispredicted branch (2-cycle flush):**
```
Cycle:  1   2   3   4   5   6   7
BEQ:    IF  ID  EX  MEM WB
I1:         IF  ID  xx  (flushed)
I2:             IF  xx  (flushed)
correct:            IF  ID  EX  MEM WB
```

---

## Simulation

```bash
# Icarus Verilog
iverilog -g2012 -o tb_riscv \
    sim/tb_riscv.sv rtl/riscv_core.sv rtl/if_stage.sv rtl/id_stage.sv \
    rtl/ex_stage.sv rtl/mem_stage.sv rtl/wb_stage.sv rtl/hazard_unit.sv \
    rtl/rv32i_pkg.sv rtl/memories.sv
vvp tb_riscv
gtkwave tb_riscv.vcd

# ModelSim / Questa
vsim -do "vlib work; \
    vlog -sv rtl/rv32i_pkg.sv rtl/*.sv rtl/memories.sv sim/tb_riscv.sv; \
    vsim -t 1ns tb_riscv; run -all"
```

The testbench loads programs directly into `u_imem.mem[]` and verifies
register file contents via hierarchical references.

---

## Resource Estimate (iCE40HX4K or Xilinx Artix-7)

| Block | LUTs | FFs |
|---|---|---|
| IF (BHT + BTB) | ~200 | 130 |
| ID (decoder + regfile) | ~200 | 35 |
| EX (ALU + forwarding) | ~150 | 10 |
| MEM (byte ops) | ~60 | 5 |
| WB | ~10 | 0 |
| Hazard unit | ~40 | 0 |
| Pipeline registers | 0 | ~300 |
| Performance counters | ~60 | 224 |
| **Total** | **~720** | **~704** |

---

## File Map

| File | Description |
|---|---|
| `rtl/rv32i_pkg.sv` | RV32I ISA constants, alu_op_t enum, ctrl_t struct |
| `rtl/if_stage.sv` | PC register, BHT/BTB predictor, flush/stall control |
| `rtl/id_stage.sv` | Register file, immediate generator, control decoder |
| `rtl/ex_stage.sv` | ALU, forwarding muxes, branch/jump resolution |
| `rtl/mem_stage.sv` | Data memory interface, byte-enable, load extension |
| `rtl/wb_stage.sv` | Write-back mux |
| `rtl/hazard_unit.sv` | Load-use stall and forwarding path selection |
| `rtl/riscv_core.sv` | Top level — pipeline registers, performance counters |
| `rtl/memories.sv` | Simulation instruction and data memory models |
| `sim/tb_riscv.sv` | Cycle-accurate testbench: ALU, forwarding, hazards, predictor |
| `docs/ARCHITECTURE.md` | This document |
