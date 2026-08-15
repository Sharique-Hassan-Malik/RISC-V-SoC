#!/usr/bin/env python3
"""
c8asm.py — assembler for the C8 custom 8-bit CPU.

Usage
-----
    python c8asm.py input.asm -o prog.hex          # Intel hex output
    python c8asm.py input.asm -o prog.hex --bin    # also write prog.bin
    python c8asm.py input.asm --list               # annotated listing

Assembly syntax
---------------
    ; comment
    label:              ; label definition (no instruction)
    NOP
    ADD  R3, R1, R2     ; R-type
    LDI  R1, 42         ; immediate (0–255)
    LDI  R1, 0xFF       ; hex immediate
    LD   R2, [R1+4]     ; load byte from DRAM[R1+4]
    LD   R2, [R1-2]     ; negative offsets allowed
    ST   [R1+0], R3     ; store byte
    BR   EQ, target     ; branch on condition
    JMP  target         ; unconditional absolute jump
    CALL sub            ; subroutine call
    RET
    HLT
    .word 0xABCD        ; emit raw 16-bit word
    .org  0x10          ; set current address

Condition codes for BR: EQ NE LT GE CS CC ALW NEV
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from typing import Optional


# ── ISA constants ──────────────────────────────────────────────────────────

OPCODES = {
    "NOP":  0x0, "ADD": 0x1, "SUB": 0x2, "AND": 0x3,
    "OR":   0x4, "XOR": 0x5, "SHF": 0x6, "CMP": 0x7,
    "LDI":  0x8, "LD":  0x9, "ST":  0xA, "BR":  0xB,
    "JMP":  0xC, "CALL":0xD, "RET": 0xE, "HLT": 0xF,
}

SHF_FN  = {"SHL": 0, "SHR": 1, "ROR": 2}
CC_CODES = {"EQ": 0, "NE": 1, "LT": 2, "GE": 3,
            "CS": 4, "CC": 5, "ALW": 6, "NEV": 7}
REG_RE  = re.compile(r"^[Rr]([0-7])$")


# ── Error type ─────────────────────────────────────────────────────────────

class AsmError(Exception):
    def __init__(self, msg: str, line_no: int = 0):
        super().__init__(f"line {line_no}: {msg}" if line_no else msg)
        self.line_no = line_no


# ── Token helpers ──────────────────────────────────────────────────────────

def parse_int(tok: str, line_no: int = 0) -> int:
    """Parse a decimal, hex (0x...) or binary (0b...) integer."""
    tok = tok.strip()
    try:
        if tok.startswith("0x") or tok.startswith("0X"):
            return int(tok, 16)
        if tok.startswith("0b") or tok.startswith("0B"):
            return int(tok, 2)
        return int(tok)
    except ValueError:
        raise AsmError(f"invalid integer literal '{tok}'", line_no)


def parse_reg(tok: str, line_no: int = 0) -> int:
    m = REG_RE.match(tok.strip())
    if not m:
        raise AsmError(f"expected register (R0–R7), got '{tok}'", line_no)
    return int(m.group(1))


def encode_r(op: int, rd: int, rs1: int, rs2: int, fn: int = 0) -> int:
    return (op << 12) | (rd << 9) | (rs1 << 6) | (rs2 << 3) | fn


def encode_i(op: int, rd: int, imm9: int) -> int:
    return (op << 12) | (rd << 9) | (imm9 & 0x1FF)


def encode_j(op: int, addr8: int) -> int:
    return (op << 12) | (addr8 & 0xFF)


def encode_b(op: int, cc: int, off9: int) -> int:
    return (op << 12) | (cc << 9) | (off9 & 0x1FF)


# ── Assembler ──────────────────────────────────────────────────────────────

@dataclass
class Line:
    no:    int
    raw:   str
    label: Optional[str]
    mnem:  Optional[str]
    args:  list[str]
    addr:  int = 0
    word:  Optional[int] = None   # encoded instruction word (16-bit)


def _strip(src: str) -> list[Line]:
    """Tokenise source lines into Line objects."""
    lines: list[Line] = []
    for no, raw in enumerate(src.splitlines(), 1):
        text = raw.split(";")[0].strip()   # strip comment
        if not text:
            continue

        label = None
        if ":" in text:
            parts = text.split(":", 1)
            label = parts[0].strip()
            text  = parts[1].strip()

        if not text:
            lines.append(Line(no, raw, label, None, []))
            continue

        tokens = re.split(r"[,\s]+", text.strip())
        tokens = [t for t in tokens if t]
        mnem = tokens[0].upper()
        args = tokens[1:]
        lines.append(Line(no, raw, label, mnem, args))
    return lines


def _first_pass(lines: list[Line]) -> dict[str, int]:
    """Assign addresses and collect label → address map."""
    pc = 0
    labels: dict[str, int] = {}
    for ln in lines:
        ln.addr = pc
        if ln.label:
            if ln.label in labels:
                raise AsmError(f"duplicate label '{ln.label}'", ln.no)
            labels[ln.label] = pc
        if ln.mnem is None:
            continue
        if ln.mnem == ".ORG":
            pc = parse_int(ln.args[0], ln.no)
            ln.addr = pc
        elif ln.mnem == ".WORD":
            pc += 1
        else:
            pc += 1
    return labels


def _resolve(tok: str, labels: dict[str, int], line_no: int) -> int:
    """Resolve a token as an integer or label."""
    tok = tok.strip()
    if tok in labels:
        return labels[tok]
    return parse_int(tok, line_no)


def _parse_mem(arg: str, line_no: int) -> tuple[int, int]:
    """Parse [Rx+N] or [Rx-N] → (reg_idx, signed_offset)."""
    arg = arg.strip()
    m = re.match(r"\[([Rr][0-7])([+-]\d+|[+-]0x[0-9a-fA-F]+)?\]$", arg)
    if not m:
        raise AsmError(f"invalid memory operand '{arg}'", line_no)
    reg = parse_reg(m.group(1), line_no)
    off = int(m.group(2), 0) if m.group(2) else 0
    if off < -32 or off > 31:
        raise AsmError(f"offset {off} out of imm6 range [-32, 31]", line_no)
    return reg, off


def _second_pass(lines: list[Line], labels: dict[str, int]) -> None:
    """Encode each instruction into a 16-bit word."""
    for ln in lines:
        if ln.mnem is None:
            continue
        m   = ln.mnem
        a   = ln.args
        n   = ln.no

        if m == ".ORG":
            continue

        if m == ".WORD":
            ln.word = parse_int(a[0], n) & 0xFFFF
            continue

        if m == "NOP":
            ln.word = 0x0000
            continue

        if m == "HLT":
            ln.word = 0xF000
            continue

        if m == "RET":
            ln.word = 0xE000
            continue

        op = OPCODES.get(m)
        if op is None:
            raise AsmError(f"unknown mnemonic '{m}'", n)

        if m in ("ADD", "SUB", "AND", "OR", "XOR"):
            if len(a) != 3:
                raise AsmError(f"{m} requires rd, rs1, rs2", n)
            ln.word = encode_r(op, parse_reg(a[0], n),
                                parse_reg(a[1], n), parse_reg(a[2], n))

        elif m == "CMP":
            if len(a) != 2:
                raise AsmError("CMP requires rs1, rs2", n)
            ln.word = encode_r(op, 0, parse_reg(a[0], n), parse_reg(a[1], n))

        elif m == "SHF":
            # SHF rd, rs1, SHL|SHR|ROR
            if len(a) != 3:
                raise AsmError("SHF requires rd, rs1, SHL|SHR|ROR", n)
            fn_name = a[2].upper()
            if fn_name not in SHF_FN:
                raise AsmError(f"unknown shift function '{fn_name}'", n)
            ln.word = encode_r(op, parse_reg(a[0], n),
                                parse_reg(a[1], n), 0, SHF_FN[fn_name])

        elif m == "LDI":
            if len(a) != 2:
                raise AsmError("LDI requires rd, imm8", n)
            rd  = parse_reg(a[0], n)
            imm = _resolve(a[1], labels, n)
            if imm < 0 or imm > 255:
                raise AsmError(f"LDI immediate {imm} out of range [0, 255]", n)
            ln.word = encode_i(op, rd, imm)

        elif m == "LD":
            if len(a) != 2:
                raise AsmError("LD requires rd, [rs1+imm6]", n)
            rd = parse_reg(a[0], n)
            rs1, off = _parse_mem(a[1], n)
            ln.word = (op << 12) | (rd << 9) | (rs1 << 6) | (off & 0x3F)

        elif m == "ST":
            if len(a) != 2:
                raise AsmError("ST requires [rs1+imm6], rs2", n)
            rs1, off = _parse_mem(a[0], n)
            rs2 = parse_reg(a[1], n)
            # ST encoding: [15:12]=op [11:9]=rs2 [8:6]=rs1 [5:0]=imm6
            ln.word = (op << 12) | (rs2 << 9) | (rs1 << 6) | (off & 0x3F)

        elif m == "BR":
            if len(a) != 2:
                raise AsmError("BR requires cc, label_or_offset", n)
            cc_name = a[0].upper()
            if cc_name not in CC_CODES:
                raise AsmError(f"unknown condition code '{cc_name}'", n)
            cc_val = CC_CODES[cc_name]
            target = _resolve(a[1], labels, n)
            off9 = target - ln.addr   # PC-relative
            if off9 < -256 or off9 > 255:
                raise AsmError(f"branch offset {off9} out of range [-256, 255]", n)
            ln.word = encode_b(op, cc_val, off9)

        elif m in ("JMP", "CALL"):
            if len(a) != 1:
                raise AsmError(f"{m} requires one address argument", n)
            addr = _resolve(a[0], labels, n)
            if addr < 0 or addr > 255:
                raise AsmError(f"address {addr} out of range [0, 255]", n)
            ln.word = encode_j(op, addr)

        else:
            raise AsmError(f"unhandled mnemonic '{m}'", n)


def assemble(src: str) -> tuple[dict[int, int], dict[str, int]]:
    """
    Assemble source text.

    Returns (addr_to_word, labels) where addr_to_word maps each instruction
    address (0–255) to its 16-bit encoded word.
    """
    lines  = _strip(src)
    labels = _first_pass(lines)
    _second_pass(lines, labels)

    words: dict[int, int] = {}
    for ln in lines:
        if ln.word is not None:
            if ln.addr > 255:
                raise AsmError(f"address {ln.addr} exceeds ROM size (256 words)",
                                ln.no)
            words[ln.addr] = ln.word
    return words, labels


def to_hex(words: dict[int, int], fill: int = 0x0000) -> str:
    """Produce a Verilog $readmemh-compatible hex file (256 lines)."""
    lines = []
    for addr in range(256):
        lines.append(f"{words.get(addr, fill):04X}")
    return "\n".join(lines) + "\n"


def to_listing(src: str, words: dict[int, int], labels: dict[str, int]) -> str:
    """Return an annotated assembly listing."""
    inv_labels: dict[int, str] = {v: k for k, v in labels.items()}
    out: list[str] = []
    raw_lines = _strip(src)
    _second_pass(raw_lines, labels)

    out.append(f"{'Addr':>4}  {'Word':>4}  {'Disasm':<40}  Source")
    out.append("-" * 72)

    for ln in raw_lines:
        if ln.label and ln.mnem is None:
            out.append(f"                 {ln.label}:")
            continue
        if ln.word is None:
            continue
        label_str = f"{inv_labels.get(ln.addr, '')}:" if ln.addr in inv_labels else ""
        out.append(f"{ln.addr:04X}  {ln.word:04X}  {label_str:<8}  {ln.raw.strip()}")

    return "\n".join(out) + "\n"


# ── CLI ────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="C8 assembler")
    ap.add_argument("input",               help="assembly source file")
    ap.add_argument("-o", "--output",      help="output .hex file",
                    default=None)
    ap.add_argument("--bin",               action="store_true",
                    help="also write raw binary (.bin)")
    ap.add_argument("--list",              action="store_true",
                    help="print annotated listing to stdout")
    args = ap.parse_args()

    with open(args.input, "r") as f:
        src = f.read()

    try:
        words, labels = assemble(src)
    except AsmError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    out_path = args.output or (args.input.rsplit(".", 1)[0] + ".hex")
    hex_str  = to_hex(words)
    with open(out_path, "w") as f:
        f.write(hex_str)
    print(f"Assembled {len(words)} words → {out_path}")

    if args.bin:
        bin_path = out_path.replace(".hex", ".bin")
        with open(bin_path, "wb") as f:
            for addr in range(256):
                w = words.get(addr, 0)
                f.write(bytes([w >> 8, w & 0xFF]))
        print(f"Binary → {bin_path}")

    if args.list:
        print(to_listing(src, words, labels))


if __name__ == "__main__":
    main()
