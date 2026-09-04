"""Cross-module tests — what is only true because these nine are one repo.

The hardware modules verify themselves through their own testbenches, which
this suite runs. What it adds is everything about them as a *system*: that the
memory map the RTL decodes is the map the firmware was assembled against, that
a program on the core can reach the accelerator, and that the S-box written
twice in two HDLs holds the same 256 bytes.

Simulations are slow. The ones that build a Verilator model are marked `slow`;
run `pytest -m "not slow"` to skip them.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from socgen import firmware, memmap, registry  # noqa: E402
from socgen.asm import Assembler, AsmError  # noqa: E402
from socgen.toolchain import missing_tools, simulate  # noqa: E402

BUILD_DIR = REPO_ROOT / ".build"

slow = pytest.mark.slow


class TestLayout:
    def test_every_module_exists_with_a_readme(self):
        for module in registry.modules():
            assert module.path.is_dir(), f"{module.name} is missing"
            assert (module.path / "README.md").is_file(), f"{module.name} has no README"

    def test_unknown_module_is_a_clear_error(self):
        with pytest.raises(KeyError, match="unknown module"):
            registry.module("nope")

    def test_every_bench_names_files_that_exist(self):
        """A recipe pointing at a missing file is a broken recipe, and finding
        out during a two-minute Verilator build is a slow way to learn it."""
        for module, bench in registry.benches(include_soc=True):
            root = registry.module(module).path
            for source in bench.sources:
                assert (root / source).is_file(), f"{module}:{bench.name} -> {source}"


class TestMemoryMap:
    def test_no_region_overlaps_another(self):
        assert memmap.overlaps() == []

    def test_every_peripheral_is_reachable_by_decode(self):
        for region in memmap.MAP:
            assert memmap.decode(region.base) is region
            assert memmap.decode(region.limit) is region

    def test_an_unmapped_address_decodes_to_nothing(self):
        assert memmap.decode(0x9000_0000) is None

    def test_registers_sit_inside_their_region(self):
        for region in memmap.MAP:
            for name, offset, _ in region.registers:
                assert offset < region.size, f"{region.name}.{name} is outside its window"

    def test_the_generated_headers_match_the_map(self):
        """The reason the map is generated rather than written three times.

        A committed header that disagrees with the table is a store that
        silently goes nowhere: no error, no exception, just a peripheral that
        never does anything.
        """
        sv = (REPO_ROOT / "rtl" / "soc_map.svh").read_text()
        c = (REPO_ROOT / "sw" / "soc_map.h").read_text()
        assert sv == memmap.to_systemverilog(), "soc_map.svh is stale — run `soc gen`"
        assert c == memmap.to_c(), "soc_map.h is stale — run `soc gen`"

    def test_the_two_headers_agree_on_every_address(self):
        sv = memmap.to_systemverilog()
        c = memmap.to_c()
        for region in memmap.MAP:
            for name, offset, _ in region.registers:
                address = region.base + offset
                assert f"{region.upper}_{name} = 32'h{address:08X}" in sv
                assert f"{region.upper}_{name}  0x{address:08X}u" in c


class TestAssembler:
    def test_a_constant_with_bit_11_set_is_loaded_correctly(self):
        """`addi` sign-extends, so a low half with bit 11 set subtracts 0x1000
        from the upper half. Getting this wrong loads an address 4 kB low —
        which, with 4 kB peripheral windows, lands in the previous peripheral."""
        asm = Assembler()
        asm.li("x1", 0x1000_0800)
        words = asm.assemble()
        upper = (words[0] >> 12) & 0xFFFFF
        assert upper == 0x10001, "the +1 correction for a negative low half is missing"

    def test_a_small_constant_needs_one_instruction(self):
        assert len(Assembler().li("x1", 5).assemble()) == 1

    def test_a_backward_branch_encodes_the_right_offset(self):
        asm = Assembler()
        asm.label("top")
        asm.addi("x1", "x1", 1)
        asm.bne("x1", "x2", "top")
        word = asm.assemble()[1]
        imm = ((((word >> 31) & 1) << 12) | (((word >> 7) & 1) << 11)
               | (((word >> 25) & 0x3F) << 5) | (((word >> 8) & 0xF) << 1))
        if imm & 0x1000:
            imm -= 0x2000
        assert imm == -4

    def test_a_branch_to_an_undefined_label_is_an_error(self):
        asm = Assembler()
        asm.beq("x0", "x0", "nowhere")
        with pytest.raises(AsmError, match="undefined label"):
            asm.assemble()

    def test_an_out_of_range_immediate_is_an_error(self):
        with pytest.raises(AsmError, match="does not fit"):
            Assembler().addi("x1", "x0", 5000)

    def test_an_unknown_register_is_an_error(self):
        with pytest.raises(AsmError, match="unknown register"):
            Assembler().addi("x99", "x0", 0)


class TestFirmwareUsesTheMap:
    def test_the_program_writes_to_the_mapped_aes_window(self):
        """The integration in one assertion: the firmware's addresses come from
        the same table the RTL header does."""
        aes = memmap.region("aes")
        program = firmware.build()
        words = program.assemble()
        # The first instruction is `lui x1, <aes base >> 12>`.
        assert (words[0] >> 12) & 0xFFFFF == aes.base >> 12
        assert words[0] & 0x7F == 0b0110111

    def test_the_expected_ciphertext_is_the_published_vector(self):
        """FIPS-197 §C.1 — the same vector the AES module's own bench uses, so
        the SoC test and the unit test cannot drift apart."""
        assert firmware.KEY == 0x2B7E151628AED2A6ABF7158809CF4F3C
        assert firmware.PLAINTEXT == 0x3243F6A8885A308D313198A2E0370734
        assert firmware.EXPECTED == 0x3925841D02DC09FBDC118597196A0B32


class TestCrossHdlConsistency:
    """The AES S-box is written twice, in Verilog and in VHDL — once for the
    accelerator, once for the TRNG's whitener. They have to be the same 256
    bytes, and neither project can check that alone.

    The two files do not even use the same shape: the Verilog is a case
    statement pairing index with value, the VHDL an ordered array. Comparing
    them means parsing both, which is why this was never going to happen by
    eye.
    """

    @staticmethod
    def _verilog_table(text: str) -> dict[int, int]:
        text = re.sub(r"//.*", "", text)
        pairs = re.findall(
            r"8'h([0-9a-fA-F]{2})\s*:\s*\w+\s*=\s*8'h([0-9a-fA-F]{2})", text
        )
        return {int(index, 16): int(value, 16) for index, value in pairs}

    @staticmethod
    def _vhdl_table(text: str) -> dict[int, int]:
        text = re.sub(r"--.*", "", text)
        body = text[text.index("SBOX"):]
        values = [int(v, 16) for v in re.findall(r'x"([0-9a-fA-F]{2})"', body)]
        return dict(enumerate(values))

    def test_both_files_define_a_complete_table(self):
        verilog = self._verilog_table(
            (registry.module("aes").path / "rtl" / "aes_sbox.v").read_text()
        )
        vhdl = self._vhdl_table(
            (registry.module("trng").path / "rtl" / "aes_sbox.vhd").read_text()
        )
        assert len(verilog) == 256, f"Verilog S-box has {len(verilog)} entries"
        assert len(vhdl) == 256, f"VHDL S-box has {len(vhdl)} entries"

    def test_each_table_is_a_permutation(self):
        """The AES S-box is a bijection on the byte. A typo that duplicates one
        value and drops another is invisible to inspection and fatal to the
        cipher."""
        for name, table in (
            ("verilog", self._verilog_table(
                (registry.module("aes").path / "rtl" / "aes_sbox.v").read_text())),
            ("vhdl", self._vhdl_table(
                (registry.module("trng").path / "rtl" / "aes_sbox.vhd").read_text())),
        ):
            assert sorted(table.values()) == list(range(256)), f"{name} is not a permutation"

    def test_the_two_tables_hold_the_same_bytes(self):
        verilog = self._verilog_table(
            (registry.module("aes").path / "rtl" / "aes_sbox.v").read_text()
        )
        vhdl = self._vhdl_table(
            (registry.module("trng").path / "rtl" / "aes_sbox.vhd").read_text()
        )
        differences = {i: (verilog[i], vhdl[i]) for i in range(256) if verilog[i] != vhdl[i]}
        assert not differences, f"S-boxes disagree at {differences}"

    def test_the_table_matches_the_published_values(self):
        verilog = self._verilog_table(
            (registry.module("aes").path / "rtl" / "aes_sbox.v").read_text()
        )
        # FIPS-197 Figure 7, first row and a few landmarks.
        assert verilog[0x00] == 0x63
        assert verilog[0x01] == 0x7C
        assert verilog[0x53] == 0xED
        assert verilog[0xFF] == 0x16


@slow
class TestSimulations:
    """Every module's own testbench, run through the shared harness."""

    @pytest.mark.parametrize(
        "module,bench",
        registry.benches(),
        ids=lambda value: value if isinstance(value, str) else value.name,
    )
    def test_module_bench_passes(self, module, bench):
        if missing_tools():
            pytest.skip(f"missing tools: {missing_tools()}")
        result = simulate(module, bench, build_dir=BUILD_DIR, timeout=900)
        if result.skipped:
            pytest.skip(result.skipped)
        assert result.ok, "\n".join(result.tail)

    def test_the_soc_runs_a_program_that_drives_the_accelerator(self):
        """The thing none of the nine could test alone.

        A program, assembled from the memory map, running on the RISC-V core,
        reaching the AES accelerator through the address decoder, producing the
        FIPS-197 ciphertext.
        """
        if missing_tools():
            pytest.skip(f"missing tools: {missing_tools()}")
        result = simulate("core", registry.SOC_BENCH, build_dir=BUILD_DIR, timeout=900)
        if result.skipped:
            pytest.skip(result.skipped)
        assert result.ok, "\n".join(result.tail)


@slow
class TestKnownCoreDefects:
    """Reproducers for the defects the SoC integration exposed.

    Each was committed failing, as a strict xfail, because a bug without a
    reproducer gets argued about. All of them pass now — the core was fixed
    rather than the tests relaxed — and they stay as the regression guards.
    """

    def test_a_single_instruction_loop_body_runs_the_right_number_of_times(self):
        if missing_tools():
            pytest.skip(f"missing tools: {missing_tools()}")
        result = simulate("core", registry.DEFECT_BENCH, build_dir=BUILD_DIR, timeout=900)
        if result.skipped:
            pytest.skip(result.skipped)
        assert result.ok, "\n".join(result.tail)

    def test_a_status_poll_terminates(self):
        """The one that took three goes. A poll is a load followed by a branch
        on the loaded value, which is the shortest program that needs the fetch
        pipeline, the load path and the predictor all to be right at once."""
        if missing_tools():
            pytest.skip(f"missing tools: {missing_tools()}")
        result = simulate("core", registry.POLL_BENCH, build_dir=BUILD_DIR, timeout=900)
        if result.skipped:
            pytest.skip(result.skipped)
        assert result.ok, "\n".join(result.tail)

    def test_a_load_returns_the_word_at_its_own_address(self):
        """A load preceded by an access to a *different* address. The core's
        own load test uses address 0 preceded by NOPs, whose dmem_addr is also
        0, so a load that sampled the bus a cycle early still read the right
        word."""
        if missing_tools():
            pytest.skip(f"missing tools: {missing_tools()}")
        result = simulate("core", registry.LOAD_BENCH, build_dir=BUILD_DIR, timeout=900)
        if result.skipped:
            pytest.skip(result.skipped)
        assert result.ok, "\n".join(result.tail)


class TestCli:
    def test_modules_listing_covers_the_repo(self, capsys):
        from socgen import cli

        assert cli.main(["modules"]) == 0
        out = capsys.readouterr().out
        for module in registry.modules():
            assert module.name in out

    def test_map_prints_every_region(self, capsys):
        from socgen import cli

        assert cli.main(["map"]) == 0
        out = capsys.readouterr().out
        for region in memmap.MAP:
            assert region.name in out
