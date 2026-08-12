"""
sim.py — C8 CPU software simulator.

Implements the same semantics as the Verilog RTL.  Used for:
  • Verifying assembler output against expected register/memory state
  • Running test programs without FPGA hardware
  • Cycle-counting and execution tracing

Usage as a library::

    from sim import Sim
    from c8asm import assemble, to_hex

    words, _ = assemble(open("prog.asm").read())
    sim = Sim(words)
    sim.run(max_cycles=1000)
    print(sim.regs[1])          # R1 after execution
    print(sim.dmem[0x10])       # data RAM byte at 0x10

Usage as a standalone tool::

    python sim.py blink.asm --cycles 100 --trace
"""

from __future__ import annotations

import argparse
import sys
from typing import Optional


# ── Constants ──────────────────────────────────────────────────────────────

OP_NOP  = 0x0; OP_ADD  = 0x1; OP_SUB  = 0x2; OP_AND  = 0x3
OP_OR   = 0x4; OP_XOR  = 0x5; OP_SHF  = 0x6; OP_CMP  = 0x7
OP_LDI  = 0x8; OP_LD   = 0x9; OP_ST   = 0xA; OP_BR   = 0xB
OP_JMP  = 0xC; OP_CALL = 0xD; OP_RET  = 0xE; OP_HLT  = 0xF

CC_EQ=0; CC_NE=1; CC_LT=2; CC_GE=3; CC_CS=4; CC_CC=5; CC_ALW=6; CC_NEV=7

MNEM = {v: k for k, v in {
    "NOP":0,"ADD":1,"SUB":2,"AND":3,"OR":4,"XOR":5,"SHF":6,"CMP":7,
    "LDI":8,"LD":9,"ST":10,"BR":11,"JMP":12,"CALL":13,"RET":14,"HLT":15,
}.items()}


def _s8(v: int) -> int:
    """Sign-extend 8-bit value."""
    v &= 0xFF
    return v if v < 128 else v - 256


def _s9(v: int) -> int:
    """Sign-extend 9-bit value."""
    v &= 0x1FF
    return v if v < 256 else v - 512


def _s6(v: int) -> int:
    """Sign-extend 6-bit value."""
    v &= 0x3F
    return v if v < 32 else v - 64


class Sim:
    """Cycle-accurate software model of the C8 CPU."""

    def __init__(self, words: dict[int, int] | None = None) -> None:
        self.imem: list[int] = [words.get(i, 0) for i in range(256)] \
            if words else [0] * 256
        self.dmem: list[int] = [0] * 256
        self.regs: list[int] = [0] * 8   # R0–R7; R0 reads as 0
        self.pc:   int = 0
        self.sp:   int = 0xFF
        # FLAGS: index 0=Z, 1=N, 2=C, 3=V
        self.flags: list[int] = [0, 0, 0, 0]
        self.halted:  bool = False
        self.cycles:  int  = 0
        self._trace:  bool = False

    def reset(self) -> None:
        self.pc    = 0
        self.sp    = 0xFF
        self.flags = [0, 0, 0, 0]
        self.halted = False
        self.cycles = 0

    def load(self, words: dict[int, int]) -> None:
        self.imem = [words.get(i, 0) for i in range(256)]

    def _reg_read(self, idx: int) -> int:
        return 0 if idx == 0 else (self.regs[idx] & 0xFF)

    def _reg_write(self, idx: int, val: int) -> None:
        if idx != 0:
            self.regs[idx] = val & 0xFF

    def _set_flags(self, result: int, carry: int = 0, overflow: int = 0) -> None:
        r = result & 0xFF
        self.flags[0] = 1 if r == 0 else 0          # Z
        self.flags[1] = (r >> 7) & 1                 # N
        self.flags[2] = carry & 1                     # C
        self.flags[3] = overflow & 1                  # V

    def _branch_taken(self, cc: int) -> bool:
        z, n, c = self.flags[0], self.flags[1], self.flags[2]
        return [z, not z, bool(n), not n, bool(c), not c, True, False][cc]

    def step(self) -> bool:
        """Execute one instruction.  Returns False when halted."""
        if self.halted:
            return False

        insn   = self.imem[self.pc] & 0xFFFF
        op     = (insn >> 12) & 0xF
        rd_idx = (insn >> 9)  & 0x7
        rs1_idx= (insn >> 6)  & 0x7
        rs2_idx= (insn >> 3)  & 0x7
        fn     = insn         & 0x7
        imm9   = insn         & 0x1FF
        imm8   = insn         & 0xFF
        addr8  = insn         & 0xFF
        imm6   = insn         & 0x3F
        cc     = (insn >> 9)  & 0x7

        rs1    = self._reg_read(rs1_idx)
        rs2    = self._reg_read(rs2_idx)
        pc_inc = (self.pc + 1) & 0xFF

        if self._trace:
            print(f"  PC={self.pc:02X}  {insn:04X}  {MNEM.get(op,'???'):<4}"
                  f"  R{rd_idx}={self._reg_read(rd_idx):02X}"
                  f"  R{rs1_idx}={rs1:02X}  R{rs2_idx}={rs2:02X}"
                  f"  FLAGS={''.join(str(f) for f in reversed(self.flags))}")

        next_pc = pc_inc

        if op == OP_NOP:
            pass

        elif op == OP_ADD:
            wide = rs1 + rs2
            r    = wide & 0xFF
            self._set_flags(r, carry=wide >> 8,
                            overflow=((~rs1 & ~rs2 & r) | (rs1 & rs2 & ~r)) >> 7)
            self._reg_write(rd_idx, r)

        elif op == OP_SUB:
            wide = rs1 - rs2
            r    = wide & 0xFF
            self._set_flags(r, carry=(wide >> 8) & 1,
                            overflow=((rs1 & ~rs2 & ~r) | (~rs1 & rs2 & r)) >> 7)
            self._reg_write(rd_idx, r)

        elif op == OP_AND:
            r = rs1 & rs2
            self._set_flags(r)
            self._reg_write(rd_idx, r)

        elif op == OP_OR:
            r = rs1 | rs2
            self._set_flags(r)
            self._reg_write(rd_idx, r)

        elif op == OP_XOR:
            r = rs1 ^ rs2
            self._set_flags(r)
            self._reg_write(rd_idx, r)

        elif op == OP_SHF:
            sh = fn & 0x3
            if sh == 0:   # SHL
                r = (rs1 << 1) & 0xFF; c = (rs1 >> 7) & 1
            elif sh == 1: # SHR
                r = rs1 >> 1;          c = rs1 & 1
            else:          # ROR
                r = ((rs1 >> 1) | ((rs1 & 1) << 7)) & 0xFF; c = rs1 & 1
            self.flags[2] = c
            self.flags[0] = 1 if r == 0 else 0
            self.flags[1] = (r >> 7) & 1
            self.flags[3] = 0
            self._reg_write(rd_idx, r)

        elif op == OP_CMP:
            wide = rs1 - rs2
            r    = wide & 0xFF
            self._set_flags(r, carry=(wide >> 8) & 1,
                            overflow=((rs1 & ~rs2 & ~r) | (~rs1 & rs2 & r)) >> 7)
            # No writeback

        elif op == OP_LDI:
            self._reg_write(rd_idx, imm8)

        elif op == OP_LD:
            addr = (rs1 + _s6(imm6)) & 0xFF
            self._reg_write(rd_idx, self.dmem[addr])

        elif op == OP_ST:
            # ST [rs1+imm6], rs2 — rd_idx field encodes source register
            src  = self._reg_read(rd_idx)
            addr = (rs1 + _s6(imm6)) & 0xFF
            self.dmem[addr] = src

        elif op == OP_BR:
            if self._branch_taken(cc):
                off = _s9(imm9)
                next_pc = (self.pc + off) & 0xFF

        elif op == OP_JMP:
            next_pc = addr8

        elif op == OP_CALL:
            self.dmem[self.sp] = pc_inc
            self.sp = (self.sp - 1) & 0xFF
            next_pc = addr8

        elif op == OP_RET:
            self.sp = (self.sp + 1) & 0xFF
            next_pc = self.dmem[self.sp]

        elif op == OP_HLT:
            self.halted = True
            self.cycles += 1
            return False

        self.pc = next_pc
        self.cycles += 1
        return True

    def run(self, max_cycles: int = 100_000, trace: bool = False) -> int:
        """Run until HLT or max_cycles.  Returns cycle count."""
        self._trace = trace
        while not self.halted and self.cycles < max_cycles:
            self.step()
        return self.cycles

    def dump(self) -> str:
        lines = [f"PC={self.pc:02X}  SP={self.sp:02X}  "
                 f"FLAGS Z={self.flags[0]} N={self.flags[1]} "
                 f"C={self.flags[2]} V={self.flags[3]}  "
                 f"HALTED={self.halted}"]
        lines.append("Registers:")
        for i in range(8):
            lines.append(f"  R{i}={self._reg_read(i):02X} ({self._reg_read(i)})")
        return "\n".join(lines)


# ── CLI ────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="C8 CPU simulator")
    ap.add_argument("input",             help="assembly source or .hex file")
    ap.add_argument("--cycles", type=int, default=10_000)
    ap.add_argument("--trace",  action="store_true")
    ap.add_argument("--dump",   action="store_true", help="print final state")
    args = ap.parse_args()

    if args.input.endswith(".hex"):
        with open(args.input) as f:
            words = {i: int(ln, 16)
                     for i, ln in enumerate(f) if ln.strip()}
    else:
        sys.path.insert(0, ".")
        from c8asm import assemble
        with open(args.input) as f:
            src = f.read()
        words, _ = assemble(src)

    sim = Sim(words)
    n = sim.run(max_cycles=args.cycles, trace=args.trace)
    print(f"Halted after {n} cycles")
    if args.dump:
        print(sim.dump())


if __name__ == "__main__":
    main()
