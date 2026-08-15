# Architecture and Integration Guide

## Overview

Two reusable, parameterized IP cores — a UART and an SPI master — packaged as
self-contained SystemVerilog modules with APB slave interfaces, FIFO-backed
data paths and hardware interrupt outputs.  Both cores are designed to be
instantiated directly in any design that provides an APB bus fabric.  A shared
`sync_fifo` module is used by both cores.  Constrained-random testbenches verify
all configurable parameters end-to-end using loopback connections.

---

## Module Hierarchy

```
uart_core
├── sync_fifo  (TX 8-bit FIFO)
├── sync_fifo  (RX 10-bit FIFO: {parity_err, framing_err, data})
├── uart_tx    (serialiser, configurable framing)
└── uart_rx    (16× oversampling receiver, majority vote)

spi_core
├── sync_fifo  (TX 32-bit FIFO)
├── sync_fifo  (RX 32-bit FIFO)
└── spi_master (CPOL/CPHA, variable width, LSB/MSB-first)
```

---

## UART Core

### Framing

```
[IDLE=1] [START=0] [D0..Dn-1] [PARITY?] [STOP1] [STOP2?] [IDLE=1]
```

Data is transmitted LSB-first.  The parity bit (when enabled) follows the
last data bit.  Two stop bits extend the idle period between frames.

### Baud rate

The baud divisor determines both the TX bit period and the RX oversample clock:

```
TX bit period      = (cfg_div + 1) clock cycles
RX oversample tick = (cfg_div + 1) / 16 clock cycles  (16× oversampling)
Baud rate          = CLK_HZ / (cfg_div + 1)
cfg_div            = CLK_HZ / baud - 1
```

Common values at `CLK_HZ = 50 MHz`:

| Baud rate | cfg_div | Actual baud | Error |
|---|---|---|---|
| 9 600 | 5207 | 9 600.6 | 0.006% |
| 115 200 | 433 | 115 207 | 0.006% |
| 921 600 | 53 | 925 926 | 0.47% |

### Receive oversampling

The RX engine samples the input 16 times per bit period.  Samples at positions
6, 7 and 8 (0-indexed from the start of the bit period) are used in a 2-of-3
majority vote to determine the bit value.  This filters glitches shorter than
one oversample clock period.

### Error detection

Two bits accompany every received byte into the RX FIFO:

- **Framing error** (bit 8): the stop bit sampled at bit-period centre was 0.
- **Parity error** (bit 9): the received parity bit did not match the expected value.

Both are visible in STATUS_REG and in the raw 10-bit RX FIFO output.

---

## SPI Core

### SPI modes

| Mode | CPOL | CPHA | SCK idle | Sample edge | Drive edge |
|---|---|---|---|---|---|
| 0 | 0 | 0 | Low | Rising | Falling |
| 1 | 0 | 1 | Low | Falling | Rising |
| 2 | 1 | 0 | High | Falling | Rising |
| 3 | 1 | 1 | High | Rising | Falling |

The `cfg_mode[1:0]` register field encodes {CPOL, CPHA}.

### Transaction flow

```
Write to DATA_TX
    │
    ▼
TX FIFO  →  spi_master.start asserted
                │
                ▼
            CS asserted (active level set by cfg_cs_pol)
                │
                ▼
            SCK generated: cfg_bits clocks
            MOSI: TX data shifted out (MSB-first or LSB-first)
            MISO: captured into shift register
                │
                ▼
            CS deasserted
            RX word pushed to RX FIFO
                │
    ▼
Read from DATA_RX
```

Transactions execute continuously as long as data is in the TX FIFO with no
inter-transaction gap except the CS deassert/reassert sequence.

### Clock frequency

```
SCK frequency = CLK_HZ / (2 × (cfg_div + 1))
cfg_div = 0  → SCK = CLK_HZ / 2  (maximum speed)
cfg_div = 4  → SCK = CLK_HZ / 10
```

---

## APB Register Maps

### UART register map

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | DATA_REG | R/W | Write: TX FIFO push. Read: RX FIFO pop |
| 0x04 | STAT_REG | R | `[6:5]` errors, `[4]` overrun, `[3:0]` FIFO flags |
| 0x08 | DIV_REG | R/W | Baud divisor (CLK_HZ/baud - 1) |
| 0x0C | CTRL_REG | R/W | `[5]` stop2, `[4:3]` parity, `[2:0]` data_bits |
| 0x10 | IRQ_EN | R/W | `[2:0]` interrupt enables |
| 0x14 | IRQ_STAT | R/W1C | `[2:0]` interrupt flags (write 1 to clear) |

### SPI register map

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | DATA_TX | W | Push 32-bit word to TX FIFO |
| 0x04 | DATA_RX | R | Pop 32-bit word from RX FIFO |
| 0x08 | STAT | R | `[4]` busy, `[3:0]` FIFO flags |
| 0x0C | CTRL | R/W | div, mode, bits, lsb_first, cs_sel, cs_pol |
| 0x10 | IRQ_EN | R/W | Interrupt enables |
| 0x14 | IRQ_STAT | R/W1C | Interrupt flags |

---

## Integration Guide

### 1. Adding to a Vivado / Quartus project

Include all `.sv` files from `rtl/` in the project source list.  Both cores
depend on `sync_fifo.sv`; ensure it is compiled before the cores that use it.

### 2. Instantiation example (UART)

```systemverilog
uart_core #(
    .CLK_HZ       (100_000_000),
    .TX_FIFO_DEPTH(32),
    .RX_FIFO_DEPTH(32),
    .DIV_W        (16)
) u_uart (
    .clk     (clk),
    .rst     (rst),
    .psel    (apb_psel),
    .penable (apb_penable),
    .pwrite  (apb_pwrite),
    .paddr   (apb_paddr[4:0]),
    .pwdata  (apb_pwdata),
    .prdata  (apb_prdata),
    .pready  (apb_pready),
    .uart_tx (uart_tx_pin),
    .uart_rx (uart_rx_pin),
    .irq     (uart_irq)
);
```

### 3. Instantiation example (SPI)

```systemverilog
spi_core #(
    .CLK_HZ       (100_000_000),
    .TX_FIFO_DEPTH(8),
    .RX_FIFO_DEPTH(8),
    .CS_COUNT     (4),
    .DIV_W        (8),
    .DATA_W       (16)
) u_spi (
    .clk    (clk),
    .rst    (rst),
    .psel   (spi_psel),
    .penable(spi_penable),
    .pwrite (spi_pwrite),
    .paddr  (spi_paddr[4:0]),
    .pwdata (spi_pwdata),
    .prdata (spi_prdata),
    .pready (spi_pready),
    .sck    (spi_sck),
    .mosi   (spi_mosi),
    .miso   (spi_miso),
    .cs_n   (spi_cs_n),
    .irq    (spi_irq)
);
```

### 4. Software driver skeleton (bare-metal C)

```c
// UART driver (register base = 0x40010000)
#define UART_BASE   0x40010000UL
#define UART_DATA   (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_STAT   (*(volatile uint32_t*)(UART_BASE + 0x04))
#define UART_DIV    (*(volatile uint32_t*)(UART_BASE + 0x08))
#define UART_CTRL   (*(volatile uint32_t*)(UART_BASE + 0x0C))

void uart_init(uint32_t clk_hz, uint32_t baud) {
    UART_DIV  = clk_hz / baud - 1;
    UART_CTRL = (1 << 5) | (0 << 3) | 7;  // 2-stop, no parity, 8-bit
}

void uart_putc(char c) {
    while (UART_STAT & 1) {}  // wait while TX full
    UART_DATA = (uint8_t)c;
}

int uart_getc(void) {
    if (UART_STAT & 8) return -1;  // RX empty
    return UART_DATA & 0xFF;
}
```

---

## Simulation

```bash
# UART testbench
iverilog -g2012 -o tb_uart \
    sim/tb_uart.sv rtl/uart_core.sv rtl/uart_tx.sv rtl/uart_rx.sv \
    rtl/sync_fifo.sv
vvp tb_uart

# SPI testbench
iverilog -g2012 -o tb_spi \
    sim/tb_spi.sv rtl/spi_core.sv rtl/spi_master.sv rtl/sync_fifo.sv
vvp tb_spi
```

---

## Testbench Coverage

The constrained-random testbenches exercise the following parameter space:

| Parameter | UART range tested | SPI range tested |
|---|---|---|
| Baud / SCK | 9600 to 921600 | div 0..15 |
| Data bits | 5, 6, 7, 8 | 4..32 bits |
| Parity | None, odd, even | n/a |
| Stop bits | 1, 2 | n/a |
| SPI mode | n/a | 0, 1, 2, 3 |
| Bit order | n/a | MSB and LSB first |
| Burst size | 1..24 bytes | 1..6 words |

Each received value is compared against the expected value from a scoreboard
queue.  Error flags (framing, parity, overrun) are checked to be clear after
every successful transfer.

---

## File Map

| File | Description |
|---|---|
| `rtl/sync_fifo.sv` | Parameterized synchronous FIFO (shared by both cores) |
| `rtl/uart_tx.sv` | UART serialiser with baud divider and framing state machine |
| `rtl/uart_rx.sv` | UART receiver with 16× oversampling and majority vote |
| `rtl/uart_core.sv` | UART IP core: FIFOs + TX/RX engines + APB registers |
| `rtl/spi_master.sv` | SPI master engine: CPOL/CPHA, variable width, LSB/MSB |
| `rtl/spi_core.sv` | SPI IP core: FIFOs + master engine + APB registers |
| `sim/tb_uart.sv` | Constrained-random UART testbench (loopback, scoreboard) |
| `sim/tb_spi.sv` | Constrained-random SPI testbench (loopback, all modes) |
| `docs/ARCHITECTURE.md` | This document |
