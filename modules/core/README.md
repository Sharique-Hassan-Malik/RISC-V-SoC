# FPGA RISCV Core

> Part of the [RISC-V SoC](../../README.md). Simulates standalone from this
> folder, or through `soc sim --only <name>`, which already knows the flags.

A 5-stage pipelined RV32I processor in SystemVerilog.  The pipeline covers
the complete base integer ISA — all ALU operations, loads and stores with
byte/halfword/word granularity, all branch types, JAL, JALR, LUI and AUIPC.
Data hazards are resolved by full EX→MEM and MEM→WB forwarding; only
load-use hazards require a stall (one cycle bubble).  A 2-bit saturating
counter branch predictor with a 64-entry branch target buffer predicts taken
branches with zero penalty cycles; mispredictions cause a 2-cycle flush.
Five hardware performance counters expose pipeline behaviour for analysis.

---

## What it does

Executes RV32I programs loaded into the instruction memory.  The five pipeline
stages advance in lockstep each clock cycle.  On any given cycle the core has
up to five instructions simultaneously in-flight: one being fetched, one being
decoded, one executing in the ALU, one accessing data memory and one writing
back to the register file.  The hazard unit and forwarding paths make this
transparent to the programmer for most instruction sequences; only a load
immediately followed by a use of the loaded register produces any observable
stall.

---

## The hard part

**Full data forwarding across three pipeline stages.**  The forwarding unit
compares four register file addresses simultaneously (EX.rs1, EX.rs2 against
EX/MEM.rd and MEM/WB.rd) and selects the correct bypass path.  MEM-stage
forwarding takes priority when both MEM and WB sources match the same
destination register — this handles the case where two consecutive instructions
write the same `rd` and the first is still in WB while the second has just left
EX.  Without the priority rule the newer value would be overwritten by an
older one.

**Branch predictor PC redirect without wasting cycles on correct predictions.**
The BHT lookup and BTB target read happen combinationally during the IF stage,
so the PC can be redirected to a predicted target on the very next cycle.  A
correctly predicted taken branch therefore has zero overhead — the branch does
not even look like a branch from a performance perspective.  The misprediction
penalty is exactly 2 cycles (the instructions in IF and ID are flushed by
asserting their pipeline registers' synchronous reset).

**Separating the BHT update from the prediction.**  The BHT is indexed by
`pc[7:2]` during fetch, but the update comes from EX two cycles later.
The update index uses `ex_branch_pc[7:2]` — the PC of the branch instruction
that was just resolved — not the current PC.  Without this distinction,
aliasing would corrupt the prediction of the next instruction at the same BHT
index.

---

## Architecture

See `docs/ARCHITECTURE.md` for the complete pipeline diagram, forwarding
priority rules, BHT/BTB operation, load-use stall detection, hazard unit
logic equations, performance counter descriptions and resource estimates.

---

## ISA coverage

Full RV32I base integer instruction set:
- Arithmetic: ADD, ADDI, SUB, SLL, SLLI, SLT, SLTI, SLTU, SLTIU, XOR, XORI, SRL, SRLI, SRA, SRAI, OR, ORI, AND, ANDI
- Upper immediate: LUI, AUIPC
- Branches: BEQ, BNE, BLT, BGE, BLTU, BGEU
- Jumps: JAL, JALR
- Loads: LB, LH, LW, LBU, LHU
- Stores: SB, SH, SW
- System: FENCE, ECALL, EBREAK (decoded as NOP, no trap support)

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
```

The testbench runs six test suites:
1. All basic ALU operations (ADD through SRA)
2. EX→EX and MEM→EX forwarding
3. Load-use stall (LW followed by immediate use)
4. BEQ taken and BNE not-taken
5. JAL and JALR
6. 64-iteration loop (branch predictor warm-up and saturation)

---

## Results

| Metric | Value |
|---|---|
| ISA | RV32I (full base integer) |
| Pipeline depth | 5 stages (IF/ID/EX/MEM/WB) |
| CPI (no hazards) | 1.0 |
| Load-use stall penalty | 1 cycle per load-use pair |
| Branch misprediction penalty | 2 cycles |
| Branch predictor type | 2-bit saturating counter BHT + BTB |
| BHT/BTB entries | 64 (indexed by PC[7:2]) |
| Loop predictor accuracy | ≥ 97% after 2 warmup iterations |
| Estimated LUT usage | ~720 (Artix-7 / iCE40HX4K) |
| Estimated FF usage | ~704 |
