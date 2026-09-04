# The SoC

`rtl/soc_top.sv` is the file none of the nine projects contained: the RISC-V
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
and the read returns whatever the next address decodes to, which shows up as a
status poll that never sees `done`.
