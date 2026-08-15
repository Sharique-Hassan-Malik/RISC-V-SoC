/*
 * c8_isa.h — C8 Custom 8-bit RISC ISA definition.
 *
 * All instruction fields described here apply equally to the Verilog RTL,
 * the Python assembler and the Python simulator.
 *
 * ──────────────────────────────────────────────────────────────────────────
 * Programmer's model
 * ──────────────────────────────────────────────────────────────────────────
 *
 *  Registers:
 *    R0–R7  8-bit general-purpose; R0 is hardwired to 0x00 (reads always 0,
 *           writes are silently discarded)
 *    PC     8-bit program counter (addresses 256 × 16-bit instruction words)
 *    SP     8-bit stack pointer   (addresses 256 × 8-bit data bytes)
 *    FLAGS  {V, N, C, Z}  overflow, negative, carry, zero
 *           Updated by: ADD SUB AND OR XOR SHF CMP
 *           NOT updated by: LDI LD ST BR JMP CALL RET HLT NOP
 *
 *  Memory:
 *    Instruction ROM  256 × 16-bit words  (byte-addresses 0x0000–0x01FF)
 *    Data RAM         256 × 8-bit bytes   (byte-addresses 0x00–0xFF)
 *    Stack            grows downward from SP=0xFF in data RAM
 *
 * ──────────────────────────────────────────────────────────────────────────
 * Instruction encoding (16 bits, fixed width)
 * ──────────────────────────────────────────────────────────────────────────
 *
 *  R-type  [15:12]=op  [11:9]=rd  [8:6]=rs1  [5:3]=rs2  [2:0]=fn
 *  I-type  [15:12]=op  [11:9]=rd  [8:0]=imm9  (signed 9-bit)
 *  B-type  [15:12]=op  [11:9]=cc  [8:0]=off9  (signed 9-bit, PC-relative)
 *  J-type  [15:12]=op  [11:8]=rsvd [7:0]=addr8 (absolute 8-bit PC address)
 *  N-type  [15:0]=0x0000 (NOP / HLT use fixed encodings)
 *
 * ──────────────────────────────────────────────────────────────────────────
 * Opcode table
 * ──────────────────────────────────────────────────────────────────────────
 *
 *  4'h0  NOP                  no operation
 *  4'h1  ADD  rd, rs1, rs2    rd ← rs1 + rs2        (fn=0: no carry-in)
 *  4'h2  SUB  rd, rs1, rs2    rd ← rs1 − rs2
 *  4'h3  AND  rd, rs1, rs2    rd ← rs1 & rs2
 *  4'h4  OR   rd, rs1, rs2    rd ← rs1 | rs2
 *  4'h5  XOR  rd, rs1, rs2    rd ← rs1 ^ rs2
 *  4'h6  SHF  rd, rs1, fn     fn=0: SHL rd,rs1  fn=1: SHR rd,rs1  fn=2: ROR
 *  4'h7  CMP  rs1, rs2        flags ← rs1 − rs2  (no writeback, rd ignored)
 *  4'h8  LDI  rd, imm8        rd ← zero_ext(imm8)  (bits [7:0] of imm9)
 *  4'h9  LD   rd, [rs1+imm6]  rd ← DRAM[rs1 + sign_ext(imm6)]
 *                              imm6 = imm9[5:0], sign-extended
 *  4'hA  ST   [rs1+imm6], rd  DRAM[rs1 + sign_ext(imm6)] ← rd
 *                              rd field encodes source; rs1 in [8:6]
 *  4'hB  BR   cc, off9        if condition(cc): PC ← PC + sign_ext(off9)
 *  4'hC  JMP  addr8           PC ← addr8  (unconditional absolute)
 *  4'hD  CALL addr8           DRAM[SP--] ← PC+1; PC ← addr8
 *  4'hE  RET                  PC ← DRAM[++SP]
 *  4'hF  HLT                  halt (freeze PC)
 *
 * ──────────────────────────────────────────────────────────────────────────
 * Condition codes (cc field, bits [11:9] of B-type)
 * ──────────────────────────────────────────────────────────────────────────
 *
 *  3'b000  EQ   Z = 1
 *  3'b001  NE   Z = 0
 *  3'b010  LT   N = 1
 *  3'b011  GE   N = 0
 *  3'b100  CS   C = 1  (carry set)
 *  3'b101  CC   C = 0  (carry clear)
 *  3'b110  ALW  always (unconditional branch, equivalent to JMP with offset)
 *  3'b111  NEV  never  (effectively a NOP)
 *
 * ──────────────────────────────────────────────────────────────────────────
 * Flag update rules
 * ──────────────────────────────────────────────────────────────────────────
 *
 *  Z  result == 0
 *  N  result[7] == 1
 *  C  carry out of bit 7  (ADD/SUB/SHF only; AND/OR/XOR clear C)
 *  V  signed overflow     (ADD/SUB only; others clear V)
 */

#ifndef C8_ISA_H
#define C8_ISA_H

/* Opcodes */
#define OP_NOP  0x0u
#define OP_ADD  0x1u
#define OP_SUB  0x2u
#define OP_AND  0x3u
#define OP_OR   0x4u
#define OP_XOR  0x5u
#define OP_SHF  0x6u
#define OP_CMP  0x7u
#define OP_LDI  0x8u
#define OP_LD   0x9u
#define OP_ST   0xAu
#define OP_BR   0xBu
#define OP_JMP  0xCu
#define OP_CALL 0xDu
#define OP_RET  0xEu
#define OP_HLT  0xFu

/* Condition codes */
#define CC_EQ  0u
#define CC_NE  1u
#define CC_LT  2u
#define CC_GE  3u
#define CC_CS  4u
#define CC_CC  5u
#define CC_ALW 6u
#define CC_NEV 7u

/* SHF function codes */
#define SHF_SHL 0u
#define SHF_SHR 1u
#define SHF_ROR 2u

/* Stack base (SP initialised here on reset) */
#define STACK_BASE 0xFFu

#endif /* C8_ISA_H */
