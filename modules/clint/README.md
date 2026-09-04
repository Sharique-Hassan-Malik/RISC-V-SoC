# CLINT — core-local interruptor

> Part of the [RISC-V SoC](../../README.md) — nine FPGA projects, one memory
> map. Runs standalone from this folder; `soc sim --only clint` runs its bench.

The machine timer and the software interrupt: a free-running 64-bit `mtime`, a
64-bit `mtimecmp`, and the `msip` bit. Small, and it is what makes an interrupt
able to reach the core at all.

```
soc sim --only clint
```

## Why it exists

The UART has had `IRQ_EN` and `IRQ_STAT` registers since it was written. It
could raise an interrupt, and nothing could receive one — the core had no CSRs,
no `mtvec`, no way to be interrupted. The only way to use the UART was to poll
it.

This is the other end of that wire, together with the CSR file and trap logic in
[`core`](../core). The full behaviour is specified in
[`docs/traps.md`](../../docs/traps.md).

## Registers

Offsets within the CLINT window (`0x4000_0000`, from the generated map):

| Offset | Register | Notes |
|---|---|---|
| `0x0000` | `MSIP` | bit 0 raises the machine software interrupt |
| `0x4000` | `MTIMECMP` low | |
| `0x4004` | `MTIMECMP` high | |
| `0xBFF8` | `MTIME` low | read-only |
| `0xBFFC` | `MTIME` high | read-only |

The offsets are SiFive's, which is why the window is 64 kB rather than the 4 kB
the other peripherals get. Inventing tidier ones would mean every piece of
existing RISC-V firmware is wrong on this core, for no gain.

## Three things the bench pins down

**`mtip` is a level, not an event.** It is the continuous comparison
`mtime >= mtimecmp`, so it stays asserted until the handler moves the deadline.
A handler that returns without re-arming re-enters immediately. That is the
classic first bug with a RISC-V timer, and it is a property of the interface
rather than a mistake in the handler — so the bench asserts the level behaviour
directly.

The alternative, latching it into a sticky flag, trades an obvious re-entry for
a silently missed tick. The obvious failure is the better one.

**`mtimecmp` resets to all-ones.** At zero the comparison is true from the first
cycle out of reset, so a core that enabled interrupts before programming the
timer would take an interrupt it never asked for. All-ones means "no deadline".

**Updating `mtimecmp` on RV32 is not atomic**, and the safe order is
counter-intuitive. The 64-bit deadline is two 32-bit stores, so the update
passes through a mixed pair. The intermediate low half must be made **maximal**:

```
    li  t0, -1
    sw  t0, MTIMECMP_LO(base)   # no smaller than the OLD value
    sw  hi, MTIMECMP_HI(base)   # no smaller than the NEW value
    sw  lo, MTIMECMP_LO(base)
```

Parking the low half at `0` reads like "disarm the timer first" and is exactly
wrong — it sets the pair to the smallest value it can hold, so the comparison is
immediately true and the update fires the interrupt it was meant to avoid. The
bench asserts *both* wrong orders fire and the specified order does not, so the
plausible-but-backwards version cannot come back.

## Reads are synchronous

`rdata` is registered: the word for an address presented on cycle T arrives at
T+1. That is the convention every other slave on this bus follows, and the SoC's
read mux is registered one cycle behind the select to match.

A combinational read looks correct in isolation and is wrong in the system —
by the time the mux selects the CLINT the address bus has moved on, so a load
returns the data belonging to whatever access followed it. A `lw` of `mtime`
then yields the next access's word instead of the time, and the handler arms its
next deadline from a number that is not a timestamp.

## Layout

```
rtl/clint.sv        the timer, the comparator and msip
sim/tb_clint.sv     20 self-checking assertions
```

## License

MIT — see [`LICENSE`](../../LICENSE).
