# Traps, CSRs and the timer

The core implements enough of the RISC-V privileged architecture for a program
to be interrupted and resumed: machine-mode CSRs, `ECALL`/`EBREAK`/`MRET`, and
the CLINT that supplies a timer and a software interrupt.

This document is the specification. The RTL is held to it, and where the two
disagree the answer is decided here first.

---

## Why this exists

The UART has had `IRQ_EN` and `IRQ_STAT` registers since it was written. It can
raise an interrupt, and until now nothing could receive one: the core had no
CSRs, no `mtvec`, no way to be interrupted at all. A peripheral that signals a
condition to a core that cannot listen is a wire to nowhere, and the only way to
use the UART was to poll it.

So the addition is not "a timer project". It is the missing half of an interface
that was already half-built.

---

## Machine-mode CSRs

Only M-mode exists. There is no U-mode, no S-mode, no virtual memory, and
`mstatus.MPP` is therefore hardwired to `11` (machine). Implementing a privilege
level the core cannot enter would be decoration.

| CSR | Address | Bits implemented | Notes |
|---|---|---|---|
| `mstatus` | `0x300` | `MIE` (3), `MPIE` (7), `MPP` (12:11) | `MPP` reads `11`, writes ignored |
| `mie` | `0x304` | `MSIE` (3), `MTIE` (7), `MEIE` (11) | per-cause enables |
| `mtvec` | `0x305` | `BASE` (31:2), `MODE` (1:0) | **direct mode only**; `MODE` reads `00`, writes to it ignored |
| `mscratch` | `0x340` | all 32 | scratch for the handler |
| `mepc` | `0x341` | 31:2 | bits 1:0 read as zero — instructions are 4-byte aligned |
| `mcause` | `0x342` | `INTERRUPT` (31), `CODE` (30:0) | see below |
| `mtval` | `0x343` | all 32 | written `0` for every trap this core takes |
| `mip` | `0x344` | `MSIP` (3), `MTIP` (7), `MEIP` (11) | **read-only**; the bits come from the CLINT and the UART |
| `mcycle` | `0xB00` | all 32 | low half of the cycle counter, read-only |
| `minstret` | `0xB02` | all 32 | low half of retired-instruction count, read-only |

Vectored `mtvec` is deliberately not implemented. It changes only where the
handler starts, and a single handler that reads `mcause` is what the firmware
here does anyway. Saying so is better than accepting a `MODE` write and then
ignoring it.

An access to any CSR not in this table reads zero and discards the write. A
real implementation raises an illegal-instruction exception; this core has no
illegal-instruction trap, and pretending otherwise in the decoder while the trap
does not exist would be worse than the documented gap.

## CSR instructions

`CSRRW`, `CSRRS`, `CSRRC` and their immediate forms `CSRRWI`, `CSRRSI`,
`CSRRCI`, all under `OP_SYSTEM` (`0x73`), selected by `funct3`:

| funct3 | Instruction | Write value | Written when |
|---|---|---|---|
| `001` | `CSRRW` | `rs1` | always |
| `010` | `CSRRS` | `old \| rs1` | `rs1 != x0` |
| `011` | `CSRRC` | `old & ~rs1` | `rs1 != x0` |
| `101` | `CSRRWI` | `uimm` | always |
| `110` | `CSRRSI` | `old \| uimm` | `uimm != 0` |
| `111` | `CSRRCI` | `old & ~uimm` | `uimm != 0` |

`rd` always receives the **old** value, including when `rd == x0` (in which case
the register file discards it). The `rs1 != x0` condition on set/clear matters:
`csrr rd, mip` assembles to `CSRRS rd, mip, x0`, and a read must not count as a
write to a read-only CSR.

## Where a CSR access happens

**In EX**, and this is a correctness argument rather than a convenience.

Branches resolve in EX and flush `IF/ID` and `ID/EX`. An instruction that
reaches EX therefore has no older unresolved branch in front of it — the older
branch has already left. Nothing downstream of EX can cancel it, because this
core has no exceptions raised in MEM. So an instruction in EX will retire, and a
CSR write performed there cannot be speculative.

Doing it in ID would be wrong: an instruction in ID can still be flushed by a
branch resolving in EX, so a `CSRRW` in a mispredicted shadow would corrupt
`mtvec` for the path that actually runs.

## Traps

A trap is taken **at EX**, on the instruction in EX, and it:

1. writes that instruction's PC to `mepc`,
2. writes `mcause`,
3. writes `0` to `mtval`,
4. copies `mstatus.MIE` into `mstatus.MPIE` and clears `mstatus.MIE`,
5. redirects the fetch to `mtvec.BASE`,
6. cancels the instruction in EX and everything younger.

Taking it at EX is what makes it **precise**. The instruction in EX has done
nothing architectural: stores happen in MEM, register writes in WB. Cancelling
it leaves no half-completed effect, and the older instructions in MEM and WB
drain normally, so the machine state the handler sees is exactly "every
instruction before `mepc` completed, and none after it started".

Taking interrupts in MEM instead would be a bug worth naming: a store commits in
MEM, so an interrupt that cancelled a store already on the bus would set `mepc`
to an instruction that had *partly* executed, and `mret` would run it twice.

### Causes

| `mcause` | Meaning |
|---|---|
| `0x8000_0003` | machine software interrupt (`MSIP`) |
| `0x8000_0007` | machine timer interrupt (`MTIP`) |
| `0x8000_000B` | machine external interrupt (`MEIP`, from the UART) |
| `0x0000_0008` | environment call from M-mode (`ECALL`) |
| `0x0000_0003` | breakpoint (`EBREAK`) |

An interrupt is taken when `mstatus.MIE` **and** the matching `mie` bit **and**
the matching `mip` bit are all set. Priority when several are pending is
external, then software, then timer, which is the order the privileged
specification gives.

`ECALL` and `EBREAK` are taken unconditionally — they are not maskable, and
`mstatus.MIE` does not gate them.

### `MRET`

Restores the interrupted context: `PC ← mepc`, `mstatus.MIE ← mstatus.MPIE`,
`mstatus.MPIE ← 1`. It is taken at EX and redirects the fetch exactly as a trap
does, in the other direction.

### Redirect priority

At the fetch, `trap > jump > branch misprediction > prediction > PC+4`. A trap
outranks a branch resolving in the same cycle because the trap cancels that
branch: the branch is the instruction in EX, and it will be re-fetched from
`mepc` after `mret`.

---

## The CLINT

Memory-mapped at the `clint` region of the map (see `socgen/memmap.py`; the
addresses below are offsets within it).

| Offset | Register | Width | Notes |
|---|---|---|---|
| `0x0000` | `MSIP` | 32 | bit 0 is the software interrupt; writing 1 raises it, 0 clears |
| `0x4000` | `MTIMECMP` low | 32 | |
| `0x4004` | `MTIMECMP` high | 32 | |
| `0xBFF8` | `MTIME` low | 32 | |
| `0xBFFC` | `MTIME` high | 32 | |

The offsets are the ones SiFive's CLINT uses and that every RISC-V bootloader
already expects. Inventing tidier ones would mean every piece of existing
firmware is wrong on this core for no gain.

`MTIME` is a free-running 64-bit counter incremented once per clock. `MTIP` is
the level `mtime >= mtimecmp`, continuously evaluated — it is **not** a latched
event. That is why the handler must write a new `mtimecmp` before returning:
returning without doing so leaves `MTIP` high and the handler re-enters
immediately.

This is worth stating because it is the classic first bug with a RISC-V timer,
and it is a property of the interface rather than a mistake in the handler.

### Writing `MTIMECMP` is not atomic on RV32

`mtimecmp` is 64 bits behind a 32-bit bus, so a two-store update passes through
a state where the halves are mixed. If the low half is written first, the pair
can briefly name a time already past and fire a spurious interrupt.

The sequence that avoids it, and the one the firmware here uses, is the one the
privileged specification gives:

```
    li  t0, -1
    sw  t0,  MTIMECMP_LO(base)   # intermediate is no smaller than the OLD value
    sw  hi,  MTIMECMP_HI(base)   # intermediate is no smaller than the NEW value
    sw  lo,  MTIMECMP_LO(base)   # the new value
```

The `-1` is the whole trick, and the intuition runs the wrong way: the
intermediate low half must be made **maximal**, not minimal. Parking it at `0`
— which reads like "disarm the timer first" — sets the pair to the smallest
value it can hold, so `mtime >= mtimecmp` is true immediately and the update
fires the very interrupt it was meant to avoid. `tb_clint` asserts both
directions, so the plausible-but-backwards version cannot come back.

---

## What is not implemented

- **No U-mode or S-mode**, so no `mideleg`/`medeleg` and no `sret`.
- **No vectored `mtvec`.** `MODE` is hardwired to `00`.
- **No illegal-instruction, misaligned-access or access-fault exceptions.** The
  core has no fault detection to raise them from; an unimplemented CSR reads
  zero rather than trapping.
- **No nested interrupts.** `mstatus.MIE` is cleared on entry and the handler
  is expected to leave it clear until `mret`. Nothing prevents a handler from
  setting it, but nothing has been tested that way.
- **`mip` is read-only.** There is no way to raise a software interrupt except
  through the CLINT's `MSIP` register, which is the only writer the hardware
  has.
