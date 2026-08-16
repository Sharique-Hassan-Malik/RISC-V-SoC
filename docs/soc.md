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

## Defects

### 1. A single-instruction loop body ran once too many — FIXED

```
loop:  addi x1, x1, 1
       bne  x1, x2, loop
       sw   x1, 0(x3)      ← stored 6 when it should store 5
```

Two or more instructions in the body behaved correctly, which is why the core's
own twenty tests never saw it.

**Cause.** A redirect has to kill *two* fetched instructions, not one. The
instruction memory reads synchronously, so at the moment a branch resolves
there is one instruction in IF/ID and another still inside the memory, fetched
from the wrong path before the redirect. `flush_if_id` cleared only the first.
The second landed in IF/ID a cycle after the flush and executed — and on a
single-instruction body that second instruction *is* the body.

**Fix.** `riscv_core.sv` carries a `fetch_valid` bit alongside `pc_fetch`. A
redirect clears it, so the in-flight fetch becomes a NOP when it arrives. Two
bubbles, which is what the header comment always claimed.

Reproducer: `sim/tb_defects.sv`, `soc sim --only defects`. It passes now, and
stays as the regression guard.

### 2. The predictor redirected on instructions that were not branches — FIXED

Found while fixing the first one, and worse than it. The BHT and BTB were
indexed by `PC[7:2]` with **no tag**, so two addresses 256 bytes apart shared an
entry — and a prediction is made from the PC alone, before the instruction is
fetched, let alone decoded. A NOP at `0x110` inherited the strongly-taken state
of the loop branch at `0x10` and sent the fetch to that branch's target.

Nothing corrected it. `mispredicted` required `ex_branch_valid`, which is false
for a NOP, so the core simply carried on executing from wherever the BTB
pointed — in the core's own loop test, straight back into a loop it had already
left.

That test passed anyway, because defect 1 was masking it: the leaked wrong-path
instruction re-executed the branch, and the extra resolution weakened the BHT
entry just enough that the aliasing NOP was not predicted taken. Fixing one
exposed the other.

**Fix.** `if_stage.sv` gained a BTB tag, so an entry only predicts for the PC
that created it; and a `bogus_redirect` term, so a prediction that redirected
the fetch for something that turns out not to be a taken branch is corrected to
`pc + 4`. The tag makes it rare, the correction makes it impossible.

### 3. A status poll never terminates — NOT FIXED

The remaining one, and it is characterised much more sharply than it was.

**What is not wrong**, measured on the bus:

* the AES block completes and sets `done_q` — the ciphertext is correct;
* `dmem_rdata` carries `0x00000001` on exactly the cycle the core samples it;
* a straight-line load of the same register lands in the register file, which
  `sim/tb_defects.sv` now checks explicitly.

So it is not the peripheral read path, which is what this file used to say.

**What is wrong.** The poll is

```
0x7c   lw  x2, 0x24(x1)
0x80   beq x2, x0, -4
```

and BTB index 31 — `PC[7:2]` of `0x7c`, the *load* — holds `0x78` with a
matching tag. The load is therefore predicted taken, the fetch is redirected
backwards to the `CTRL` write, and the branch at `0x80` never reaches ID/EX at
all. AES is restarted every iteration and the loop never ends.

Which branch resolution wrote that entry is not established. No instruction at
`0x7c` is a branch, and `ex_branch_valid` is low for the load, so the write
should not have happened. Since the tag matches, it was written by something
with `ex_branch_pc[31:8] == 0` and `PC[7:2] == 31`.

Reproducer: `sim/tb_poll.sv`, `soc sim --only poll`, and a strict `xfail` in
`tests/test_integration.py`. `socgen/firmware.py` waits a fixed 32 cycles
instead of polling, with a comment pointing here.

## An earlier fix, for context

Before any of the above, `if_stage.sv` computed:

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
against that.

That fix was necessary and not sufficient: it made the *direction* comparison
honest, which is what let defect 1 above be seen for what it was, and it is what
`bogus_redirect` in defect 2 builds on — you cannot ask "did this instruction's
prediction redirect the fetch?" until the prediction travels with the
instruction.
