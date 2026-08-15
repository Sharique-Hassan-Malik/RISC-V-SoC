# The SoC, and what it exposed

`rtl/soc_top.sv` is the file none of the eight projects contained: the RISC-V
core with peripherals on its data bus, decoded against a map that the firmware
is also generated from.

## Structure

```
   riscv_core ──┬── dmem_addr/wdata/we ──► address decode (top nibble)
                │                              ├── 0x0… RAM
                └── dmem_rdata ◄── read mux ───┼── 0x1… UART   (APB)
                                               ├── 0x2… AES    (aes_regs)
                                               └── 0x3… TRNG   (synthesis only)
```

The decode is on the top nibble because one four-bit comparison is a single LUT
level and four peripherals do not need a finer split.

`aes_regs.sv` exists because the accelerator arrived with an AXI-lite wrapper
and this core has a single-cycle load/store port. Bridging AXI to reach a block
that needs four write cycles would have been more interconnect than design, so
the adapter presents the generated register layout directly.

The TRNG is deliberately absent from the simulated SoC. It is VHDL, and mixing
VHDL into a Verilator or Icarus elaboration needs a mixed-language flow this
repository does not have. The map reserves its window; saying so is better than
pretending the simulation covers it.

## The read mux is registered

RAM reads synchronously, so the core samples read data the cycle *after* it
drives the address. Peripherals therefore have to register their reads too, and
the mux selects on a registered select. A combinational peripheral read returns
its value one cycle early — by the time the core looks, the address has moved on
and the read returns whatever the next address decodes to.

That was the first bug in this file, and its symptom was a status poll that
never saw `done`.

## Known defects

Both are in the core, both are reproduced, neither is worked around silently.

### 1. A single-instruction loop body runs once too many

```
loop:  addi x1, x1, 1
       bne  x1, x2, loop
       sw   x1, 0(x3)      ← stores 6 when it should store 5
```

Two or more instructions in the body behave correctly. The core's own loop test
has a two-instruction body, which is why its twenty tests never saw this.

Reproducer: `sim/tb_defects.sv`, run by `soc sim --only defects` and by the
`xfail(strict=True)` test in `tests/test_integration.py`. It fails today and
will start passing the day the core is fixed — which is the notification you
want from a known bug.

**Not yet diagnosed.** The store's data comes from the forwarding network while
the architectural register holds the right value, which points at a result
surviving in EX/MEM after the instruction that produced it was flushed. That is
a hypothesis, not a finding.

### 2. Peripheral loads do not reach the register file

Writes to peripherals work. Loads from RAM work. A load from a peripheral
leaves the destination register unchanged, even though `dmem_rdata` carries the
right value on the right cycle — verified by probing the bus.

The SoC firmware waits a fixed number of cycles rather than polling a status
register, with a comment in `socgen/firmware.py` explaining that it is avoiding
a broken path rather than choosing a simpler one.

## The fix that was applied

`if_stage.sv` computed:

```systemverilog
mispredicted = ex_branch_valid && (ex_branch_taken != bht[bht_idx_update][1]);
```

comparing the outcome against the branch history table's contents *at
resolution time*, not against the prediction actually made when the branch was
fetched. Those differ whenever the same branch is in flight more than once,
which is what a tight loop does: an earlier iteration resolves and updates the
BHT entry while a later iteration is still in the pipeline. Reading the entry at
resolution then says "we predicted taken" about an instruction fetched under a
not-taken prediction, the mismatch is invisible, and no flush happens.

The prediction now travels down the pipeline with its instruction
(`predicted_fetch` → `ifid_predicted` → `idex_predicted`), and the comparison is
against that. The core's twenty tests pass unchanged.
