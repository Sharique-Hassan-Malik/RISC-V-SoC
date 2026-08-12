# FPGA UART SPI IP

Parameterized, reusable UART and SPI master IP cores for FPGA designs.
Both cores expose an APB slave interface, have independently configurable
FIFO depths and clock dividers, and generate hardware interrupts.  A shared
synchronous FIFO module is used for both cores' TX and RX data paths.
Constrained-random self-checking testbenches verify all configurable
parameters end-to-end using loopback connections, with scoreboards that
compare every transferred byte or word against expected values.

---

## What it does

**UART core** — transmits and receives serial data at any baud rate achievable
from the system clock.  Frame format (5–8 data bits, no/odd/even parity, 1–2
stop bits) is runtime-configurable via a single CTRL register.  The receiver
uses 16× oversampling with a 2-of-3 majority vote at the bit centre to reject
noise.  Framing and parity errors are reported per received byte and accumulate
in status flags.

**SPI master core** — executes SPI transactions in any of the four standard
modes (CPOL × CPHA).  Transfer width is configurable from 4 to 32 bits per
transaction.  Bit order (MSB-first or LSB-first) is selectable.  Transactions
execute back-to-back as long as words remain in the TX FIFO.  Up to eight
hardware chip-select outputs are supported with configurable polarity.

---

## The hard part

**UART RX synchronisation and oversampling.**  The RX input is asynchronous
to the system clock.  A 2-FF synchroniser removes metastability; a
divide-by-16 counter generates the oversample clock; and samples at positions
6, 7 and 8 within each bit period are majority-voted to produce a clean bit
value.  The false-start guard (checking the start bit is still low at its
centre) prevents noise glitches from triggering spurious frames.

**SPI mode correctness across all four CPOL/CPHA combinations.**  The SCK
polarity, the edge on which MOSI is driven, and the edge on which MISO is
sampled differ between modes.  The state machine handles CPHA=1 by inserting
a half-clock lead phase before the first edge, and uses the `sck_int XOR cpol`
expression to determine which half-period is the active (sampling) edge
regardless of CPOL.

**APB zero-wait-state reads that trigger FIFO pops.**  The RX FIFO pop must
happen during the same APB read cycle that returns the data.  This is handled
by driving `rx_fifo_rd` directly from the combinational decode path
(`psel && !pwrite && addr == DATA`) rather than registering it, so the FIFO
read pointer advances on the same cycle the data is presented to the host.

---

## Architecture

See `docs/ARCHITECTURE.md` for the full module hierarchy, UART framing
diagram, baud rate table, SPI mode table, APB register maps, integration
examples with SystemVerilog instantiation code, a bare-metal C driver
skeleton and testbench coverage tables.

---

## Parameters

### uart_core

| Parameter | Default | Description |
|---|---|---|
| `CLK_HZ` | 50 000 000 | System clock frequency |
| `TX_FIFO_DEPTH` | 16 | TX FIFO depth (power of 2) |
| `RX_FIFO_DEPTH` | 16 | RX FIFO depth (power of 2) |
| `DIV_W` | 16 | Baud divisor register width |

### spi_core

| Parameter | Default | Description |
|---|---|---|
| `CLK_HZ` | 50 000 000 | System clock frequency |
| `TX_FIFO_DEPTH` | 8 | TX FIFO depth |
| `RX_FIFO_DEPTH` | 8 | RX FIFO depth |
| `CS_COUNT` | 1 | Number of chip-select outputs |
| `DIV_W` | 8 | SCK divider width |
| `DATA_W` | 32 | Maximum transaction width in bits |

---

## Simulation

```bash
# UART constrained-random test (loopback TX→RX)
iverilog -g2012 -o tb_uart \
    sim/tb_uart.sv rtl/uart_core.sv rtl/uart_tx.sv rtl/uart_rx.sv \
    rtl/sync_fifo.sv
vvp tb_uart

# SPI constrained-random test (loopback MOSI→MISO)
iverilog -g2012 -o tb_spi \
    sim/tb_spi.sv rtl/spi_core.sv rtl/spi_master.sv rtl/sync_fifo.sv
vvp tb_spi
```

Both testbenches print per-test PASS/FAIL lines and a final summary.

---

## Results

| Metric | UART | SPI |
|---|---|---|
| Baud/SCK range | Any: CLK_HZ/2 to CLK_HZ/65536 | CLK_HZ/2 to CLK_HZ/512 |
| RX oversampling | 16× with majority vote | n/a |
| Parity | None / odd / even | n/a |
| Stop bits | 1 or 2 | n/a |
| Data width | 5–8 bits | 4–32 bits |
| SPI modes | n/a | 0, 1, 2, 3 (all CPOL/CPHA) |
| Bit order | LSB-first only | MSB-first or LSB-first |
| Chip selects | n/a | Up to 8 |
| FIFO depth | Configurable | Configurable |
| APB wait states | 0 | 0 |
| Interrupt | tx_empty, rx_not_empty, overrun | tx_empty, rx_not_empty |
