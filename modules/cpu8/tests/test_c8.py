"""Tests for the C8 assembler and software simulator."""

import sys
import os
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "asm"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sim"))

from c8asm import assemble, to_hex, AsmError
from sim import Sim


# ── Assembler encoding tests ───────────────────────────────────────────────

def asm1(src: str) -> int:
    """Assemble a single instruction and return the encoded word."""
    words, _ = assemble(src)
    return words[0]


def test_nop_encodes_zero():
    assert asm1("NOP") == 0x0000


def test_hlt_encodes_f000():
    assert asm1("HLT") == 0xF000


def test_ret_encodes_e000():
    assert asm1("RET") == 0xE000


def test_add_r_type():
    # ADD R3, R1, R2 → op=1 rd=3 rs1=1 rs2=2 fn=0
    # 0001_011_001_010_000 = 0x1640... let me compute:
    # [15:12]=0001  [11:9]=011  [8:6]=001  [5:3]=010  [2:0]=000
    # = 0001_011_001_010_000
    # = 0x1648
    w = asm1("ADD R3, R1, R2")
    assert (w >> 12) & 0xF == 0x1          # op = ADD
    assert (w >> 9)  & 0x7 == 3            # rd = R3
    assert (w >> 6)  & 0x7 == 1            # rs1 = R1
    assert (w >> 3)  & 0x7 == 2            # rs2 = R2
    assert w         & 0x7 == 0            # fn = 0


def test_sub_r_type():
    w = asm1("SUB R5, R2, R3")
    assert (w >> 12) & 0xF == 0x2
    assert (w >> 9)  & 0x7 == 5
    assert (w >> 6)  & 0x7 == 2
    assert (w >> 3)  & 0x7 == 3


def test_ldi_immediate():
    # LDI R1, 42 → op=8 rd=1 imm9=42
    w = asm1("LDI R1, 42")
    assert (w >> 12) & 0xF == 0x8
    assert (w >> 9)  & 0x7 == 1
    assert w & 0xFF == 42


def test_ldi_hex():
    w = asm1("LDI R3, 0xFF")
    assert w & 0xFF == 0xFF


def test_ldi_out_of_range():
    with pytest.raises(AsmError, match="out of range"):
        asm1("LDI R1, 256")


def test_ld_encoding():
    # LD R2, [R1+4] → op=9 rd=2 rs1=1 imm6=4
    w = asm1("LD R2, [R1+4]")
    assert (w >> 12) & 0xF == 0x9
    assert (w >> 9)  & 0x7 == 2
    assert (w >> 6)  & 0x7 == 1
    assert w & 0x3F == 4


def test_ld_negative_offset():
    w = asm1("LD R3, [R2-2]")
    off6 = w & 0x3F
    # sign-extend 6 bits: 0b111110 = 62 → -2
    off = off6 if off6 < 32 else off6 - 64
    assert off == -2


def test_st_encoding():
    # ST [R1+0], R3 → op=A rs2=R3 rs1=R1 imm6=0
    w = asm1("ST [R1+0], R3")
    assert (w >> 12) & 0xF == 0xA
    assert (w >> 9)  & 0x7 == 3    # source register in rd field
    assert (w >> 6)  & 0x7 == 1    # rs1 = R1


def test_br_eq_forward():
    src = """\
        NOP
        BR EQ, target
        NOP
target:
        NOP
"""
    words, labels = assemble(src)
    assert "target" in labels
    assert labels["target"] == 3
    # Branch at PC=1, target=3, offset=2
    w = words[1]
    assert (w >> 12) & 0xF == 0xB       # BR
    assert (w >> 9)  & 0x7 == 0         # EQ cc
    off9 = w & 0x1FF
    # sign-extend 9-bit
    off = off9 if off9 < 256 else off9 - 512
    assert off == 2


def test_br_alw():
    w = asm1("BR ALW, 0")
    assert (w >> 9) & 0x7 == 6   # CC_ALW


def test_jmp_encoding():
    w = asm1("JMP 0x40")
    assert (w >> 12) & 0xF == 0xC
    assert w & 0xFF == 0x40


def test_call_encoding():
    w = asm1("CALL 0x10")
    assert (w >> 12) & 0xF == 0xD
    assert w & 0xFF == 0x10


def test_shf_shl():
    w = asm1("SHF R2, R1, SHL")
    assert (w >> 12) & 0xF == 0x6
    assert w & 0x7 == 0   # fn=SHL


def test_shf_shr():
    w = asm1("SHF R2, R1, SHR")
    assert w & 0x7 == 1   # fn=SHR


def test_shf_ror():
    w = asm1("SHF R2, R1, ROR")
    assert w & 0x7 == 2   # fn=ROR


def test_cmp_encoding():
    w = asm1("CMP R3, R4")
    assert (w >> 12) & 0xF == 0x7
    assert (w >> 6)  & 0x7 == 3
    assert (w >> 3)  & 0x7 == 4


def test_label_resolution():
    src = """\
start:  LDI R1, 0
        JMP start
"""
    words, labels = assemble(src)
    assert labels["start"] == 0
    jmp_word = words[1]
    assert (jmp_word >> 12) & 0xF == 0xC
    assert jmp_word & 0xFF == 0   # jumps back to address 0


def test_dot_word():
    words, _ = assemble(".word 0xABCD")
    assert words[0] == 0xABCD


def test_org_directive():
    words, _ = assemble(".org 0x10\n NOP")
    assert 0x10 in words
    assert words[0x10] == 0x0000


def test_unknown_mnemonic_raises():
    with pytest.raises(AsmError, match="unknown mnemonic"):
        assemble("INVALID R1, R2")


def test_duplicate_label_raises():
    with pytest.raises(AsmError, match="duplicate label"):
        assemble("foo:\nfoo:\nNOP")


def test_to_hex_produces_256_lines():
    words, _ = assemble("NOP")
    h = to_hex(words)
    assert len(h.strip().splitlines()) == 256


# ── Simulator tests ────────────────────────────────────────────────────────

def run(src: str, cycles: int = 1000) -> Sim:
    words, _ = assemble(src)
    s = Sim(words)
    s.run(max_cycles=cycles)
    return s


def test_sim_ldi():
    s = run("LDI R1, 42\n HLT")
    assert s.regs[1] == 42


def test_sim_r0_always_zero():
    s = run("LDI R0, 99\n HLT")
    assert s.regs[0] == 0   # writes to R0 discarded


def test_sim_add():
    s = run("LDI R1, 10\n LDI R2, 20\n ADD R3, R1, R2\n HLT")
    assert s.regs[3] == 30


def test_sim_sub():
    s = run("LDI R1, 50\n LDI R2, 13\n SUB R3, R1, R2\n HLT")
    assert s.regs[3] == 37


def test_sim_and():
    s = run("LDI R1, 0xFF\n LDI R2, 0x0F\n AND R3, R1, R2\n HLT")
    assert s.regs[3] == 0x0F


def test_sim_or():
    s = run("LDI R1, 0xA0\n LDI R2, 0x0B\n OR R3, R1, R2\n HLT")
    assert s.regs[3] == 0xAB


def test_sim_xor():
    s = run("LDI R1, 0xFF\n LDI R2, 0xFF\n XOR R3, R1, R2\n HLT")
    assert s.regs[3] == 0x00


def test_sim_shl():
    s = run("LDI R1, 1\n SHF R2, R1, SHL\n HLT")
    assert s.regs[2] == 2


def test_sim_shr():
    s = run("LDI R1, 8\n SHF R2, R1, SHR\n HLT")
    assert s.regs[2] == 4


def test_sim_ror_carry():
    s = run("LDI R1, 1\n SHF R2, R1, ROR\n HLT")
    assert s.regs[2] == 0x80   # LSB rotated to MSB
    assert s.flags[2] == 1     # carry = shifted-out LSB


def test_sim_cmp_sets_zero_flag():
    s = run("LDI R1, 5\n LDI R2, 5\n CMP R1, R2\n HLT")
    assert s.flags[0] == 1   # Z=1


def test_sim_cmp_sets_negative_flag():
    s = run("LDI R1, 3\n LDI R2, 5\n CMP R1, R2\n HLT")
    assert s.flags[1] == 1   # N=1 (3-5 = -2, negative)


def test_sim_st_ld_roundtrip():
    s = run("LDI R1, 0xAB\n ST [R0+0], R1\n LD R2, [R0+0]\n HLT")
    assert s.dmem[0] == 0xAB
    assert s.regs[2] == 0xAB


def test_sim_branch_taken():
    src = """\
        LDI R1, 0
        LDI R2, 0
        CMP R1, R2
        BR EQ, skip
        LDI R3, 99      ; should NOT execute
skip:
        LDI R4, 42
        HLT
"""
    s = run(src)
    assert s.regs[3] == 0    # skipped
    assert s.regs[4] == 42   # executed


def test_sim_branch_not_taken():
    src = """\
        LDI R1, 1
        LDI R2, 2
        CMP R1, R2
        BR EQ, skip
        LDI R3, 77     ; should execute
skip:
        HLT
"""
    s = run(src)
    assert s.regs[3] == 77


def test_sim_jmp():
    src = """\
        JMP end
        LDI R1, 99     ; should be skipped
end:
        LDI R2, 42
        HLT
"""
    s = run(src)
    assert s.regs[1] == 0
    assert s.regs[2] == 42


def test_sim_call_ret():
    src = """\
        CALL sub
        LDI R2, 99
        HLT
sub:
        LDI R1, 42
        RET
"""
    s = run(src)
    assert s.regs[1] == 42
    assert s.regs[2] == 99


def test_sim_fibonacci():
    """Run fibonacci.asm and verify first 8 Fibonacci numbers in DRAM."""
    prog_path = os.path.join(os.path.dirname(__file__),
                              "..", "prog", "fibonacci.asm")
    with open(prog_path) as f:
        src = f.read()
    words, _ = assemble(src)
    s = Sim(words)
    s.run(max_cycles=50_000)
    expected = [0, 1, 1, 2, 3, 5, 8, 13]
    for i, exp in enumerate(expected):
        assert s.dmem[i] == exp, f"DRAM[{i}]={s.dmem[i]} expected {exp}"


def test_sim_flag_z_after_add_zero():
    s = run("LDI R1, 0\n LDI R2, 0\n ADD R3, R1, R2\n HLT")
    assert s.flags[0] == 1   # Z=1, result is zero


def test_sim_flag_carry_add():
    s = run("LDI R1, 0xFF\n LDI R2, 1\n ADD R3, R1, R2\n HLT")
    assert s.regs[3] == 0     # 0xFF + 1 = 0x100, truncated to 0
    assert s.flags[2] == 1    # carry set


def test_sim_halts():
    s = run("HLT\n LDI R1, 99\n LDI R2, 77")
    assert s.halted
    assert s.regs[1] == 0   # instructions after HLT not executed
