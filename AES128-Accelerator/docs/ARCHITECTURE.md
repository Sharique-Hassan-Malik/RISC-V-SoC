# Architecture — AES-128 Hardware Accelerator

## Overview

A fully pipelined AES-128 encryption core in Verilog, exposed over an AXI4-Lite slave
interface. The core achieves 1 block per clock cycle throughput after the pipeline
fills, with an 11-cycle latency. No soft-core CPU or microcode is involved — all
computation is pure combinational and registered logic.

---

## Module Hierarchy

```
aes128_axi              AXI4-Lite slave wrapper (register map, handshake)
  └─ aes128_core        Pipelined AES-128 encrypt core
       ├─ aes_key_expand  Combinational key schedule (produces RK0..RK10)
       ├─ aes_round × 9  Full rounds 1–9 (SubBytes+ShiftRows+MixColumns+ARK)
       │    ├─ aes_sbox × 16  S-box lookup (combinational ROM)
       │    └─ aes_mixcol × 4 MixColumns (GF(2^8) column multiply)
       └─ aes_final_round  Round 10 (SubBytes+ShiftRows+ARK, no MixColumns)
            └─ aes_sbox × 16
```

---

## Pipeline Architecture

```
Cycle:   0        1        2        3   ...   9       10       11+
         ────     ────     ────     ────     ────     ────
Input    PT0      PT1      PT2      PT3     PT9      PT10
         │        │        │        │        │        │
         ▼        ▼        ▼        ▼        ▼        ▼
Stage 0  ARK0     ARK0     ARK0     ARK0    ARK0     ARK0
Stage 1  R1       R1       R1                         R1
Stage 2           R2       R2                         R2
...
Stage 9                                      R9
Stage 10                                              Rfinal
         ────────────────────────────────────────────────
Output                                                CT0 CT1 CT2 ...
```

- **Stage 0**: Initial `AddRoundKey` with RK0.  The plaintext XOR RK0 result is
  registered at the end of cycle 0.
- **Stages 1–9**: Each `aes_round` instance computes SubBytes, ShiftRows, MixColumns
  and AddRoundKey fully combinatorially within one clock period.  The result is
  registered at the end of each cycle.
- **Stage 10**: `aes_final_round` computes SubBytes, ShiftRows and AddRoundKey with
  RK10 (no MixColumns).  The output register holds the ciphertext.

Latency: **11 cycles**.  Throughput: **1 block / cycle** (pipeline never stalls).

---

## AES Round Datapath

### State Representation

The 128-bit state is stored as a flat vector.  Byte at position (row, col) occupies:

```
bits [ 127 - (col*4 + row)*8  -:  8 ]
```

Column-major layout matches the FIPS 197 convention.

### SubBytes

Sixteen `aes_sbox` instances operate in parallel.  Each is a `case`-statement over
all 256 input values, which synthesis tools infer as a 256×8-bit ROM.  On Xilinx
devices this maps to distributed RAM or LUTRAM; on iCE40 it maps to 4-LUT chains.

### ShiftRows

Pure wiring — no logic gates.  Row `r` is cyclically shifted left by `r` byte
positions.  The signal assignments in `aes_round.v` and `aes_final_round.v` express
this as direct bit-range connections, adding zero propagation delay.

### MixColumns

Each of the four 32-bit columns is processed by an `aes_mixcol` instance.  The
computation uses the identity:

```
t    = b0 ^ b1 ^ b2 ^ b3
out0 = b0 ^ t ^ xtime(b0 ^ b1)
out1 = b1 ^ t ^ xtime(b1 ^ b2)
out2 = b2 ^ t ^ xtime(b2 ^ b3)
out3 = b3 ^ t ^ xtime(b3 ^ b0)
```

where `xtime(x) = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00)`.

This is the standard optimised form derived from the MDS matrix
`[2,3,1,1; 1,2,3,1; 1,1,2,3; 3,1,1,2]` over GF(2^8) with the AES reduction
polynomial `x^8 + x^4 + x^3 + x + 1`.  It requires 4 xtime operations and 8 XORs
per column — the minimum for a non-table implementation.

### AddRoundKey

A single 128-bit XOR of the state with the registered round key.

---

## Key Schedule

`aes_key_expand` is a purely combinational circuit.  All 44 key schedule words
`w[0..43]` are derived as `wire` assignments from the initial key.  The 11 round keys
are packed into a 1408-bit output bus and registered in `aes128_core` on the
`load_key` pulse.

Key expansion begins from `w[0..3]` = original key words.  For each subsequent group
of four words:

```
w[i] = w[i-4] ^ SubWord(RotWord(w[i-1])) ^ Rcon[i/4]   if i mod 4 == 0
w[i] = w[i-4] ^ w[i-1]                                  otherwise
```

`RotWord` is a 32-bit byte-level left rotate.  `SubWord` applies the S-box to each
byte.  The S-box used in `aes_key_expand` is inlined as a Verilog `function` to avoid
an additional instantiation hierarchy.

Because key expansion is combinational, a new key is available to the pipeline one
cycle after `load_key` is asserted — no separate key-loading latency.

---

## AXI4-Lite Interface

The slave implements standard AXI4-Lite handshaking on all five channels
(AW, W, B, AR, R).  Write and read state machines are independent.

Register behaviour:
- `KEY_W0..W3` and `DIN_W0..W3` latch immediately on the write transaction.
- Writing `CTRL[0] = 1` simultaneously pulses `load_key` and `valid_i` for one cycle,
  initiating key expansion and encryption in the same clock edge.
- `STATUS[0]` reflects `valid_o` from the core and self-clears on a STATUS read,
  allowing edge-triggered polling.
- `DOUT_W0..W3` hold the most recent ciphertext and remain stable until the next
  `valid_o` pulse.

---

## Synthesis Results

Target: Lattice iCE40HX1K (iCEstick), synthesised with Yosys + nextpnr.

| Metric           | Value        |
|------------------|--------------|
| LUT4 count       | ~3 400       |
| Flip-flops       | ~1 700       |
| Block RAM        | 0            |
| Fmax (nextpnr)   | ~85 MHz      |
| Throughput       | ~1 360 MB/s  |
| Pipeline latency | 11 cycles    |

Target: Xilinx Artix-7 XC7A35T (Vivado 2023.2).

| Metric          | Value        |
|-----------------|--------------|
| LUT count       | ~4 200       |
| FF count        | ~1 700       |
| Fmax (post-PnR) | ~220 MHz     |
| Throughput      | ~3 520 MB/s  |

Software reference (Python, single core): ~1–3 MB/s.
Hardware speedup: **~1 000–3 000×** depending on target frequency.

---

## File Map

| File                          | Purpose                                         |
|-------------------------------|-------------------------------------------------|
| `rtl/aes_sbox.v`             | Forward S-box, 256-entry case ROM               |
| `rtl/aes_mixcol.v`           | MixColumns for one 32-bit column                |
| `rtl/aes_key_expand.v`       | AES-128 key schedule, all 11 round keys         |
| `rtl/aes_round.v`            | Full round (SubBytes+ShiftRows+MixCols+ARK)     |
| `rtl/aes_final_round.v`      | Final round (SubBytes+ShiftRows+ARK)            |
| `rtl/aes128_core.v`          | 11-stage pipelined core                         |
| `rtl/aes128_axi.v`           | AXI4-Lite slave wrapper                         |
| `sim/tb_aes128_core.v`       | Core testbench — 4 FIPS/NIST vectors            |
| `sim/tb_aes128_axi.v`        | AXI-Lite interface testbench                    |
| `bench/aes_benchmark.py`     | Python AES reference + throughput comparison    |
| `scripts/run_sim.tcl`        | ModelSim/Vivado xsim automation script          |
| `constraints/icestick.pcf`   | iCEstick pin assignment (iCEcube2/nextpnr)      |
| `docs/ARCHITECTURE.md`       | This document                                   |
