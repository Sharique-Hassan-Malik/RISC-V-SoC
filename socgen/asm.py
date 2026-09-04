"""Just enough RV32I to write firmware for this SoC, in Python.

There is no RISC-V toolchain in this repository and adding a dependency on one
to run a test would be the wrong trade: the programs that exercise an address
decoder are twenty instructions long.

What makes this worth having rather than hand-encoding hex is that it imports
`socgen.memmap`. The firmware, the SystemVerilog header and the C header all
take their addresses from the same table, so a program that pokes the AES
accelerator cannot be pointed at the wrong window by a map change — the test
would fail to assemble, or fail loudly, rather than silently writing into
nothing.

    from socgen.asm import Assembler
    asm = Assembler()
    asm.li("x1", memmap.region("aes").base)
    asm.sw("x2", "x1", 0x20)
    asm.write_hex(path)
"""

from __future__ import annotations

from pathlib import Path

REGISTERS = {f"x{i}": i for i in range(32)}
REGISTERS.update({"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4})


class AsmError(ValueError):
    pass


def _reg(name: str | int) -> int:
    if isinstance(name, int):
        if not 0 <= name < 32:
            raise AsmError(f"register out of range: x{name}")
        return name
    try:
        return REGISTERS[name]
    except KeyError:
        raise AsmError(f"unknown register {name!r}") from None


def _check_imm(value: int, bits: int, *, signed: bool = True) -> int:
    if signed:
        low, high = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    else:
        low, high = 0, (1 << bits) - 1
    if not low <= value <= high:
        raise AsmError(f"immediate {value} does not fit in {bits} signed bits")
    return value & ((1 << bits) - 1)


class Assembler:
    """Emits words in order; labels are resolved on `assemble()`."""

    def __init__(self) -> None:
        self._words: list[int | tuple] = []
        self._labels: dict[str, int] = {}

    # -- position ------------------------------------------------------------

    @property
    def pc(self) -> int:
        """Byte address of the next instruction."""
        return len(self._words) * 4

    def label(self, name: str) -> "Assembler":
        if name in self._labels:
            raise AsmError(f"label {name!r} defined twice")
        self._labels[name] = self.pc
        return self

    # -- formats -------------------------------------------------------------

    def _emit(self, word: int) -> "Assembler":
        self._words.append(word & 0xFFFF_FFFF)
        return self

    def _r(self, funct7: int, rs2, rs1, funct3: int, rd, opcode: int) -> "Assembler":
        return self._emit(
            (funct7 << 25) | (_reg(rs2) << 20) | (_reg(rs1) << 15)
            | (funct3 << 12) | (_reg(rd) << 7) | opcode
        )

    def _i(self, imm: int, rs1, funct3: int, rd, opcode: int) -> "Assembler":
        return self._emit(
            (_check_imm(imm, 12) << 20) | (_reg(rs1) << 15)
            | (funct3 << 12) | (_reg(rd) << 7) | opcode
        )

    def _s(self, imm: int, rs2, rs1, funct3: int, opcode: int) -> "Assembler":
        value = _check_imm(imm, 12)
        return self._emit(
            ((value >> 5) << 25) | (_reg(rs2) << 20) | (_reg(rs1) << 15)
            | (funct3 << 12) | ((value & 0x1F) << 7) | opcode
        )

    def _b(self, offset: int, rs2, rs1, funct3: int) -> "Assembler":
        value = _check_imm(offset, 13)
        return self._emit(
            (((value >> 12) & 1) << 31) | (((value >> 5) & 0x3F) << 25)
            | (_reg(rs2) << 20) | (_reg(rs1) << 15) | (funct3 << 12)
            | (((value >> 1) & 0xF) << 8) | (((value >> 11) & 1) << 7) | 0b1100011
        )

    # -- instructions --------------------------------------------------------

    def lui(self, rd, imm20: int) -> "Assembler":
        return self._emit(((imm20 & 0xFFFFF) << 12) | (_reg(rd) << 7) | 0b0110111)

    def addi(self, rd, rs1, imm: int) -> "Assembler":
        return self._i(imm, rs1, 0b000, rd, 0b0010011)

    def add(self, rd, rs1, rs2) -> "Assembler":
        return self._r(0, rs2, rs1, 0b000, rd, 0b0110011)

    def andi(self, rd, rs1, imm: int) -> "Assembler":
        return self._i(imm, rs1, 0b111, rd, 0b0010011)

    def sw(self, rs2, rs1, offset: int = 0) -> "Assembler":
        return self._s(offset, rs2, rs1, 0b010, 0b0100011)

    def lw(self, rd, rs1, offset: int = 0) -> "Assembler":
        return self._i(offset, rs1, 0b010, rd, 0b0000011)

    def beq(self, rs1, rs2, target: str) -> "Assembler":
        self._words.append(("beq", rs1, rs2, target, self.pc))
        return self

    def bne(self, rs1, rs2, target: str) -> "Assembler":
        self._words.append(("bne", rs1, rs2, target, self.pc))
        return self

    def nop(self) -> "Assembler":
        return self.addi("x0", "x0", 0)

    # -- SYSTEM: CSRs and traps ---------------------------------------------
    #
    # A CSR address is a 12-bit *unsigned* index, so it goes into the
    # instruction directly rather than through `_check_imm`, whose signed range
    # stops at 0x7FF and would reject every counter CSR (0xB00 and up).

    def _system(self, csr: int, rs1_or_uimm, funct3: int, rd) -> "Assembler":
        if not 0 <= csr <= 0xFFF:
            raise ValueError(f"CSR address {csr:#x} does not fit in 12 bits")
        src = rs1_or_uimm if isinstance(rs1_or_uimm, int) and funct3 & 0b100 \
            else _reg(rs1_or_uimm)
        if funct3 & 0b100 and not 0 <= src <= 31:
            raise ValueError(f"CSR immediate {src} does not fit in 5 bits")
        return self._emit(
            (csr << 20) | (src << 15) | (funct3 << 12) | (_reg(rd) << 7) | 0b1110011
        )

    def csrrw(self, rd, csr: int, rs1) -> "Assembler":
        return self._system(csr, rs1, 0b001, rd)

    def csrrs(self, rd, csr: int, rs1) -> "Assembler":
        return self._system(csr, rs1, 0b010, rd)

    def csrrc(self, rd, csr: int, rs1) -> "Assembler":
        return self._system(csr, rs1, 0b011, rd)

    def csrrwi(self, rd, csr: int, uimm: int) -> "Assembler":
        return self._system(csr, uimm, 0b101, rd)

    def csrrsi(self, rd, csr: int, uimm: int) -> "Assembler":
        return self._system(csr, uimm, 0b110, rd)

    def csrrci(self, rd, csr: int, uimm: int) -> "Assembler":
        return self._system(csr, uimm, 0b111, rd)

    def ecall(self) -> "Assembler":
        return self._emit(0x0000_0073)

    def ebreak(self) -> "Assembler":
        return self._emit(0x0010_0073)

    def mret(self) -> "Assembler":
        return self._emit(0x3020_0073)

    # -- pseudo-instructions -------------------------------------------------

    def csrw(self, csr: int, rs1) -> "Assembler":
        """`csrw csr, rs1` — write, discarding the old value."""
        return self.csrrw("x0", csr, rs1)

    def csrr(self, rd, csr: int) -> "Assembler":
        """`csrr rd, csr` — read. Assembles to CSRRS with rs1 = x0, which the
        hardware must not treat as a write; that is what makes reading a
        read-only CSR legal."""
        return self.csrrs(rd, csr, "x0")

    def csrs(self, csr: int, rs1) -> "Assembler":
        """`csrs csr, rs1` — set the bits of rs1."""
        return self.csrrs("x0", csr, rs1)

    def csrc(self, csr: int, rs1) -> "Assembler":
        """`csrc csr, rs1` — clear the bits of rs1."""
        return self.csrrc("x0", csr, rs1)

    def li(self, rd, value: int) -> "Assembler":
        """Load a 32-bit constant.

        `addi` sign-extends its 12-bit immediate, so a low half with bit 11 set
        subtracts 0x1000 from the upper half. Adding it back before the `lui` is
        the standard correction, and forgetting it is the classic way to load an
        address that is 4 kB too low — which, on a memory map with 4 kB
        peripheral windows, lands squarely in the previous peripheral.
        """
        value &= 0xFFFF_FFFF
        low = value & 0xFFF
        high = (value >> 12) & 0xFFFFF
        if low & 0x800:
            high = (high + 1) & 0xFFFFF
            low -= 0x1000
        if high:
            self.lui(rd, high)
            if low:
                self.addi(rd, rd, low)
        else:
            self.addi(rd, "x0", low)
        return self

    # -- output --------------------------------------------------------------

    def assemble(self) -> list[int]:
        """Resolve branches and return the instruction words."""
        words: list[int] = []
        for entry in self._words:
            if isinstance(entry, int):
                words.append(entry)
                continue
            kind, rs1, rs2, target, at = entry
            if target not in self._labels:
                raise AsmError(f"branch to undefined label {target!r}")
            offset = self._labels[target] - at
            saved, self._words = self._words, []
            self._b(offset, rs2, rs1, 0b000 if kind == "beq" else 0b001)
            words.append(self._words[0])
            self._words = saved
        return words

    def write_hex(self, path: str | Path) -> Path:
        """Write `$readmemh` format — one 32-bit word per line."""
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            "\n".join(f"{word:08x}" for word in self.assemble()) + "\n",
            encoding="utf-8",
        )
        return target
