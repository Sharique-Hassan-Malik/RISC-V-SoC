"""Building and simulating nine hardware modules in three HDLs, one way.

Every project here knew how to build itself and none of it was written down.
The knowledge is real and unobvious:

  * The RISC-V core is SystemVerilog with a `localparam` assignment pattern
    that Icarus rejects outright, so it needs Verilator.
  * Several modules `` `include `` a package or header by bare filename, so the
    tool has to run **from the module's own directory** with that directory on
    the search path. From anywhere else the include is simply not found.
  * The GHDL packaged on Debian uses the mcode backend, where `ghdl -e` writes
    no binary at all. VHDL is analysed and then run with `ghdl -r`, which
    elaborates in the same step.
  * A VHDL testbench with free-running oscillators never terminates, so it
    needs `--stop-time`.

None of that belongs in nine READMEs. It belongs here, once, checked by tests
that actually run the simulations.
"""

from __future__ import annotations

import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
MODULES_ROOT = REPO_ROOT / "modules"

VERILOG = "verilog"
SYSTEMVERILOG = "systemverilog"
VHDL = "vhdl"

TOOL_FOR = {
    VERILOG: "iverilog",
    SYSTEMVERILOG: "verilator",
    VHDL: "ghdl",
}


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


def missing_tools() -> list[str]:
    return [tool for tool in ("iverilog", "vvp", "verilator", "ghdl") if not have(tool)]


@dataclass(frozen=True)
class Bench:
    """One simulation: which testbench, in which language, with which sources."""

    name: str
    language: str
    top: str
    sources: tuple[str, ...]
    include_dirs: tuple[str, ...] = ()
    stop_time: str = ""
    # Icarus defaults to Verilog-2005. Several "Verilog" modules use
    # SystemVerilog spellings that only appear under -g2012 — a declaration
    # inside an unnamed block, for instance — so the standard is per bench.
    standard: str = "2012"
    # A line the simulation prints when it is satisfied. Checked because a
    # simulator exits zero after a failed assertion just as happily as after a
    # passing one.
    expect: str = ""
    # Something to do in the working directory first. The SoC bench uses it to
    # assemble its firmware, because `$readmemh("program.hex")` resolves
    # against the working directory and the working directory is the module's.
    prepare: Callable[[Path], None] | None = None


@dataclass
class Result:
    bench: str
    ok: bool = False
    ran: bool = False
    skipped: str = ""
    elapsed: float = 0.0
    command: str = ""
    tail: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "bench": self.bench,
            "ok": self.ok,
            "ran": self.ran,
            **({"skipped": self.skipped} if self.skipped else {}),
            "elapsed_s": round(self.elapsed, 2),
        }


def _run(command: Sequence[str], cwd: Path, timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(part) for part in command], cwd=cwd,
        capture_output=True, text=True, timeout=timeout,
    )


def simulate(module: str, bench: Bench, *, build_dir: Path, timeout: float = 900.0) -> Result:
    """Build and run one testbench, from the module's own directory."""
    result = Result(bench=f"{module}:{bench.name}")
    tool = TOOL_FOR[bench.language]
    if not have(tool):
        result.skipped = f"{tool} is not installed"
        return result
    if bench.language == VERILOG and not have("vvp"):
        result.skipped = "vvp is not installed"
        return result

    cwd = MODULES_ROOT / module
    build_dir.mkdir(parents=True, exist_ok=True)
    if bench.prepare is not None:
        bench.prepare(cwd)
    started = time.perf_counter()

    try:
        if bench.language == VERILOG:
            output = build_dir / f"{module}_{bench.name}.vvp"
            includes = [arg for directory in bench.include_dirs for arg in ("-I", directory)]
            build = _run(
                ["iverilog", f"-g{bench.standard}", *includes, "-o", output, *bench.sources],
                cwd, timeout,
            )
            if build.returncode != 0:
                result.command = "iverilog"
                result.tail = build.stderr.strip().splitlines()[-8:]
                return result
            run = _run(["vvp", output], cwd, timeout)

        elif bench.language == SYSTEMVERILOG:
            objdir = build_dir / f"{module}_{bench.name}"
            includes = [arg for directory in bench.include_dirs for arg in ("-y", directory)]
            build = _run(
                ["verilator", "--binary", "-Wno-fatal", *includes,
                 "--top-module", bench.top, "--Mdir", objdir, "-o", bench.top,
                 *bench.sources],
                cwd, timeout,
            )
            if build.returncode != 0:
                result.command = "verilator"
                result.tail = build.stderr.strip().splitlines()[-8:]
                return result
            run = _run([objdir / bench.top], cwd, timeout)

        else:  # VHDL
            workdir = build_dir / f"{module}_{bench.name}_ghdl"
            workdir.mkdir(parents=True, exist_ok=True)
            analyse = _run(
                ["ghdl", "-a", f"--workdir={workdir}", "--std=08", *bench.sources],
                cwd, timeout,
            )
            if analyse.returncode != 0:
                result.command = "ghdl -a"
                result.tail = analyse.stderr.strip().splitlines()[-8:]
                return result
            # `ghdl -e` produces no binary on the mcode backend; -r elaborates
            # and runs in one step.
            command = ["ghdl", "-r", f"--workdir={workdir}", "--std=08", bench.top]
            if bench.stop_time:
                command.append(f"--stop-time={bench.stop_time}")
            run = _run(command, cwd, timeout)

    except subprocess.TimeoutExpired:
        result.elapsed = time.perf_counter() - started
        result.tail = [f"timed out after {timeout:g}s"]
        return result

    result.elapsed = time.perf_counter() - started
    result.ran = True
    output_text = (run.stdout or "") + (run.stderr or "")
    result.tail = output_text.strip().splitlines()[-10:]
    # A simulator exits zero whether or not the design passed, so the pass
    # marker the testbench prints is what decides.
    result.ok = run.returncode == 0 and (
        bench.expect in output_text if bench.expect else True
    )
    return result


def lint(module: str, bench: Bench, *, timeout: float = 300.0) -> Result:
    """Verilator's lint pass — the only static check that spans SV and Verilog."""
    result = Result(bench=f"{module}:{bench.name}:lint")
    if bench.language == VHDL:
        result.skipped = "Verilator does not read VHDL"
        return result
    if not have("verilator"):
        result.skipped = "verilator is not installed"
        return result

    cwd = MODULES_ROOT / module
    includes = [arg for directory in bench.include_dirs for arg in ("-y", directory)]
    started = time.perf_counter()
    completed = _run(
        ["verilator", "--lint-only", "-Wno-fatal", *includes,
         "--top-module", bench.top, *bench.sources],
        cwd, timeout,
    )
    result.elapsed = time.perf_counter() - started
    result.ran = True
    result.ok = completed.returncode == 0
    result.tail = completed.stderr.strip().splitlines()[-8:]
    return result
