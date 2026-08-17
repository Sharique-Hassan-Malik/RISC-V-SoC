"""The eight modules, their HDL, and how each one is actually simulated.

The `Bench` entries here are the executable form of what used to be prose in
eight READMEs: which files, which include path, which top level, and what the
testbench prints when it is happy.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .toolchain import MODULES_ROOT, SYSTEMVERILOG, VERILOG, VHDL, Bench


def _write_defect_program(cwd: Path) -> None:
    """A loop that counts to five and stores the counter.

    Five iterations, one instruction in the body. On a correct core the stored
    value is 5; on this one it is 6.
    """
    from .asm import Assembler
    from . import memmap

    asm = Assembler()
    asm.li("x1", 0)
    asm.li("x2", 5)
    asm.li("x3", memmap.region("ram").base)
    asm.label("loop")
    asm.addi("x1", "x1", 1)
    asm.bne("x1", "x2", "loop")
    asm.sw("x1", "x3", 0)

    # Defect 2: a load from a peripheral reaching the register file.
    # AES 0x24 is the `done` status bit, which reads 0 out of reset. Reading a
    # known-zero register is not much of a test, so the value is loaded, had 7
    # added to it, and stored: the store proves the load's destination register
    # took part in the arithmetic rather than being left at whatever it held.
    asm.li("x4", memmap.region("aes").base + 0x24)
    asm.li("x5", 0xDEAD)              # poison, so an untouched x5 is visible
    asm.lw("x5", "x4", 0)             # x5 <- AES done (0)
    asm.addi("x5", "x5", 7)
    asm.sw("x5", "x3", 4)             # ram[1] should be 7, not 0xDEAD + 7

    asm.label("end")
    asm.beq("x0", "x0", "end")
    asm.write_hex(cwd / "program.hex")


def _write_firmware(cwd: Path) -> None:
    """Assemble the SoC's program into the simulation's working directory.

    `imem` loads it with `$readmemh("program.hex")`, which resolves against the
    working directory — so the firmware has to be built where the simulation
    runs, not where the source lives. Generating it here rather than committing
    a hex blob is also the point: the addresses come from the same memory map
    the RTL header is generated from.
    """
    from . import firmware

    firmware.write(cwd / "program.hex")


@dataclass(frozen=True)
class Module:
    name: str
    title: str
    summary: str
    language: str
    benches: tuple[Bench, ...] = ()
    peripheral: str = ""          # its address range in the SoC, if it has one

    @property
    def path(self) -> Path:
        return MODULES_ROOT / self.name


_CORE_RTL = (
    "rtl/rv32i_pkg.sv", "rtl/riscv_core.sv", "rtl/if_stage.sv", "rtl/id_stage.sv",
    "rtl/ex_stage.sv", "rtl/mem_stage.sv", "rtl/wb_stage.sv", "rtl/hazard_unit.sv",
    "rtl/memories.sv",
)


MANIFEST: tuple[Module, ...] = (
    Module(
        name="core", title="RV32I pipeline", language=SYSTEMVERILOG,
        summary="A five-stage RISC-V core: hazard detection, forwarding, a "
                "branch predictor and performance counters.",
        benches=(
            Bench(
                name="riscv", language=SYSTEMVERILOG, top="tb_riscv",
                sources=(*_CORE_RTL, "sim/tb_riscv.sv"),
                include_dirs=("rtl",), expect="SIMULATION PASSED",
            ),
        ),
    ),
    Module(
        name="cpu8", title="8-bit CPU", language=VERILOG,
        summary="A small accumulator machine with its own assembler and a "
                "Python instruction-set simulator to check the RTL against.",
    ),
    Module(
        name="uart-spi", title="UART and SPI IP", language=SYSTEMVERILOG,
        summary="Parameterised UART with a synchronous FIFO, and an SPI master "
                "covering all four clock modes.",
        peripheral="0x1000_0000",
        benches=(
            Bench(name="uart", language=SYSTEMVERILOG, top="tb_uart",
                  sources=("rtl/uart_rx.sv", "rtl/uart_tx.sv", "rtl/sync_fifo.sv",
                           "rtl/uart_core.sv", "sim/tb_uart.sv"),
                  include_dirs=("rtl",)),
            Bench(name="spi", language=SYSTEMVERILOG, top="tb_spi",
                  sources=("rtl/spi_core.sv", "rtl/spi_master.sv", "sim/tb_spi.sv"),
                  include_dirs=("rtl",)),
        ),
    ),
    Module(
        name="aes", title="AES-128 accelerator", language=VERILOG,
        summary="A round-based AES-128 core with an AXI-lite wrapper, checked "
                "against the FIPS-197 vectors.",
        peripheral="0x2000_0000",
        benches=(
            Bench(name="core", language=VERILOG, top="tb_aes128_core",
                  sources=("rtl/aes_sbox.v", "rtl/aes_mixcol.v", "rtl/aes_round.v",
                           "rtl/aes_final_round.v", "rtl/aes_key_expand.v",
                           "rtl/aes128_core.v", "sim/tb_aes128_core.v"),
                  include_dirs=("rtl",), expect="All 4 vectors PASSED"),
        ),
    ),
    Module(
        name="trng", title="Ring-oscillator TRNG", language=VHDL,
        summary="Entropy from ring-oscillator jitter, de-biased by von Neumann "
                "and whitened through an AES S-box, with NIST STS tooling.",
        peripheral="0x3000_0000",
        benches=(
            Bench(name="trng", language=VHDL, top="tb_trng",
                  sources=("rtl/ring_osc.vhd", "rtl/von_neumann.vhd",
                           "rtl/aes_sbox.vhd", "rtl/aes_whitener.vhd",
                           "rtl/uart_out.vhd", "rtl/trng_top.vhd", "sim/tb_trng.vhd"),
                  stop_time="500us"),
        ),
    ),
    Module(
        name="pong", title="VGA Pong", language=VERILOG,
        summary="A complete game in hardware: VGA timing, sprite rendering, "
                "collision, scoring and switch debouncing.",
        benches=(
            Bench(name="ball", language=VERILOG, top="tb_ball",
                  sources=("rtl/ball.v", "sim/tb_ball.v"),
                  include_dirs=("rtl",), expect="0 failed"),
        ),
    ),
    Module(
        name="mandelbrot", title="VGA Mandelbrot", language=VHDL,
        summary="Fixed-point Mandelbrot iteration feeding a framebuffer and VGA "
                "output, with a Python model to verify the arithmetic.",
        benches=(
            # The testbench drives the whole design, not just the iterator, so
            # every entity it reaches has to be analysed first.
            Bench(name="mandelbrot", language=VHDL, top="tb_mandelbrot",
                  sources=("rtl/vga_pkg.vhd", "rtl/fp_mul.vhd",
                           "rtl/mandelbrot_iter.vhd", "rtl/mandelbrot_engine.vhd",
                           "rtl/framebuffer.vhd", "rtl/colour_map.vhd",
                           "rtl/vga_sync.vhd", "rtl/synth_top.vhd",
                           "sim/tb_mandelbrot.vhd"),
                  stop_time="2ms"),
        ),
    ),
    Module(
        name="synth", title="Polyphonic synthesiser", language=VERILOG,
        summary="Voice allocation, phase accumulators, a biquad filter and a "
                "PWM DAC — a MIDI-driven synth in fabric.",
        benches=(
            Bench(name="synth", language=VERILOG, top="tb_synth",
                  sources=("rtl/q15_mul.v", "rtl/dds_osc.v", "rtl/adsr_env.v",
                           "rtl/midi_rx.v", "rtl/sample_clk.v",
                           "rtl/note_to_phase.v", "rtl/voice_alloc.v",
                           "rtl/voice_mixer.v", "rtl/biquad_df1.v",
                           "rtl/pwm_dac.v", "rtl/cc_store.v", "rtl/synth_top.v",
                           "sim/tb_synth.v"),
                  include_dirs=("rtl",)),
        ),
    ),
)

# The SoC itself is not a module under modules/ — it is what the modules add up
# to, so its sources span several of them and it lives at the repository root.
SOC_BENCH = Bench(
    name="soc",
    language=SYSTEMVERILOG,
    top="tb_soc",
    sources=(
        "../../sim/tb_soc.sv", "../../rtl/soc_top.sv", "../../rtl/aes_regs.sv",
        *_CORE_RTL,
        "../uart-spi/rtl/uart_rx.sv", "../uart-spi/rtl/uart_tx.sv",
        "../uart-spi/rtl/sync_fifo.sv", "../uart-spi/rtl/uart_core.sv",
        "../aes/rtl/aes_sbox.v", "../aes/rtl/aes_mixcol.v", "../aes/rtl/aes_round.v",
        "../aes/rtl/aes_final_round.v", "../aes/rtl/aes_key_expand.v",
        "../aes/rtl/aes128_core.v",
    ),
    include_dirs=("rtl", "../../rtl", "../uart-spi/rtl", "../aes/rtl"),
    expect="SOC SIMULATION PASSED",
    prepare=_write_firmware,
)


def _write_load_program(cwd: Path) -> None:
    """Two loads from different addresses, back to back.

    The core's own load test loads from address 0 preceded by NOPs, whose
    dmem_addr is also 0 — so a load that samples the bus one cycle early still
    reads the right word. This one makes the previous address different.
    """
    from .asm import Assembler
    from . import memmap

    ram = memmap.region("ram").base
    asm = Assembler()
    asm.li("x1", ram)
    asm.li("x2", 0xAAAA0000)
    asm.sw("x2", "x1", 0)                     # ram[0] = AAAA0000
    asm.li("x3", 0xBBBB0000)
    asm.sw("x3", "x1", 16)                    # ram[4] = BBBB0000
    asm.nop(); asm.nop(); asm.nop()

    asm.lw("x4", "x1", 16)                    # x4 = BBBB0000
    asm.nop(); asm.nop(); asm.nop()
    asm.lw("x5", "x1", 0)                     # x5 = AAAA0000
    asm.nop(); asm.nop(); asm.nop()
    asm.sw("x5", "x1", 32)                    # ram[8] should be AAAA0000
    asm.label("end")
    asm.beq("x0", "x0", "end")
    asm.write_hex(cwd / "program.hex")


def _write_poll_program(cwd: Path) -> None:
    """Start AES, poll STATUS.done, then store a marker.

    Reaching the store is the whole test. See sim/tb_poll.sv.
    """
    from .asm import Assembler
    from . import memmap

    aes = memmap.region("aes")
    asm = Assembler()
    asm.li("x1", aes.base)
    asm.li("x3", memmap.region("ram").base)

    asm.li("x2", 1)
    asm.sw("x2", "x1", 0x20)                  # CTRL: start
    asm.label("wait")
    asm.lw("x2", "x1", 0x24)                  # STATUS.done
    asm.beq("x2", "x0", "wait")

    asm.li("x4", 0xA5A50001)
    asm.sw("x4", "x3", 0)
    asm.label("end")
    asm.beq("x0", "x0", "end")
    asm.write_hex(cwd / "program.hex")


LOAD_BENCH = Bench(
    name="load",
    language=SYSTEMVERILOG,
    top="tb_load",
    sources=(
        "../../sim/tb_load.sv", "../../rtl/soc_top.sv", "../../rtl/aes_regs.sv",
        *_CORE_RTL,
        "../uart-spi/rtl/uart_rx.sv", "../uart-spi/rtl/uart_tx.sv",
        "../uart-spi/rtl/sync_fifo.sv", "../uart-spi/rtl/uart_core.sv",
        "../aes/rtl/aes_sbox.v", "../aes/rtl/aes_mixcol.v", "../aes/rtl/aes_round.v",
        "../aes/rtl/aes_final_round.v", "../aes/rtl/aes_key_expand.v",
        "../aes/rtl/aes128_core.v",
    ),
    include_dirs=("rtl", "../../rtl", "../uart-spi/rtl", "../aes/rtl"),
    expect="LOADS CORRECT",
    prepare=_write_load_program,
)


POLL_BENCH = Bench(
    name="poll",
    language=SYSTEMVERILOG,
    top="tb_poll",
    sources=(
        "../../sim/tb_poll.sv", "../../rtl/soc_top.sv", "../../rtl/aes_regs.sv",
        *_CORE_RTL,
        "../uart-spi/rtl/uart_rx.sv", "../uart-spi/rtl/uart_tx.sv",
        "../uart-spi/rtl/sync_fifo.sv", "../uart-spi/rtl/uart_core.sv",
        "../aes/rtl/aes_sbox.v", "../aes/rtl/aes_mixcol.v", "../aes/rtl/aes_round.v",
        "../aes/rtl/aes_final_round.v", "../aes/rtl/aes_key_expand.v",
        "../aes/rtl/aes128_core.v",
    ),
    include_dirs=("rtl", "../../rtl", "../uart-spi/rtl", "../aes/rtl"),
    expect="POLL FIXED",
    prepare=_write_poll_program,
)


DEFECT_BENCH = Bench(
    name="defects",
    language=SYSTEMVERILOG,
    top="tb_defects",
    sources=(
        "../../sim/tb_defects.sv", "../../rtl/soc_top.sv", "../../rtl/aes_regs.sv",
        *_CORE_RTL,
        "../uart-spi/rtl/uart_rx.sv", "../uart-spi/rtl/uart_tx.sv",
        "../uart-spi/rtl/sync_fifo.sv", "../uart-spi/rtl/uart_core.sv",
        "../aes/rtl/aes_sbox.v", "../aes/rtl/aes_mixcol.v", "../aes/rtl/aes_round.v",
        "../aes/rtl/aes_final_round.v", "../aes/rtl/aes_key_expand.v",
        "../aes/rtl/aes128_core.v",
    ),
    include_dirs=("rtl", "../../rtl", "../uart-spi/rtl", "../aes/rtl"),
    expect="DEFECTS FIXED",
    prepare=_write_defect_program,
)


_BY_NAME = {module.name: module for module in MANIFEST}


def modules() -> list[Module]:
    return list(MANIFEST)


def module(name: str) -> Module:
    try:
        return _BY_NAME[name]
    except KeyError:
        raise KeyError(
            f"unknown module {name!r}; choose from {', '.join(sorted(_BY_NAME))}"
        ) from None


def benches(include_soc: bool = False) -> list[tuple[str, Bench]]:
    found = [(m.name, bench) for m in MANIFEST for bench in m.benches]
    if include_soc:
        # Run from the core's directory: its `include` of rv32i_pkg.sv is by
        # bare filename, so that directory has to be the working one.
        found.append(("core", SOC_BENCH))
    return found
