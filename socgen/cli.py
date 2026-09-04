"""`soc` — one command over nine hardware modules and the SoC they compose.

    soc modules                what is here, in which HDL, and how to run it
    soc map                    the memory map
    soc gen                    regenerate the SV and C headers, and the firmware
    soc sim                    simulate everything, including the SoC
    soc sim --only core        one module
    soc lint                   Verilator's lint pass over the synthesisable RTL
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import firmware, memmap, registry
from .toolchain import REPO_ROOT, lint, missing_tools, simulate

BUILD_DIR = REPO_ROOT / ".build"


def _wrap(text: str, width: int) -> list[str]:
    words, lines, line = text.split(), [], []
    for word in words:
        if sum(len(w) + 1 for w in line) + len(word) > width and line:
            lines.append(" ".join(line))
            line = []
        line.append(word)
    if line:
        lines.append(" ".join(line))
    return lines


def _cmd_modules(args) -> int:
    print()
    for module in registry.modules():
        print(f"  {module.name:12} {module.language:15} "
              f"{len(module.benches)} bench(es)"
              f"{'   @ ' + module.peripheral if module.peripheral else ''}")
        print(f"  {'':12} {module.title}")
        for line in _wrap(module.summary, 70):
            print(f"  {'':12} {line}")
        print()
    absent = missing_tools()
    print(f"  tools: {'all present' if not absent else 'missing ' + ', '.join(absent)}")
    print()
    return 0


def _cmd_map(args) -> int:
    print()
    print(memmap.to_markdown())
    print()
    for entry in memmap.MAP:
        if not entry.registers:
            continue
        print(f"  {entry.name}")
        for name, offset, meaning in entry.registers:
            print(f"    0x{entry.base + offset:08X}  {name:9} {meaning}")
        print()
    if memmap.overlaps():
        print(f"  OVERLAPPING REGIONS: {memmap.overlaps()}")
        return 1
    return 0


def _cmd_gen(args) -> int:
    written = memmap.write()
    hex_path = firmware.write(REPO_ROOT / "sim" / "program.hex")
    print()
    for path in [*written, hex_path]:
        print(f"  wrote {path.relative_to(REPO_ROOT)}")
    print()
    return 0


def _cmd_sim(args) -> int:
    selected = registry.benches(include_soc=not args.no_soc)
    if args.only:
        selected = [(m, b) for m, b in selected if m in args.only or b.name in args.only]
    if not selected:
        print("soc: nothing selected", file=sys.stderr)
        return 2

    print()
    failures = 0
    for module, bench in selected:
        result = simulate(module, bench, build_dir=BUILD_DIR, timeout=args.timeout)
        if result.skipped:
            state = f"skip ({result.skipped})"
        elif result.ok:
            state = "PASS"
        else:
            state = "FAIL"
            failures += 1
        print(f"  {result.bench:26} {state:34} {result.elapsed:6.1f}s")
        if not result.ok and not result.skipped and args.verbose:
            for line in result.tail:
                print(f"      {line}")
    print()
    return 1 if failures else 0


def _cmd_lint(args) -> int:
    print()
    failures = 0
    for module, bench in registry.benches():
        result = lint(module, bench)
        state = f"skip ({result.skipped})" if result.skipped else ("clean" if result.ok else "ISSUES")
        if not result.ok and not result.skipped:
            failures += 1
        print(f"  {result.bench:32} {state}")
        if not result.ok and not result.skipped and args.verbose:
            for line in result.tail:
                print(f"      {line}")
    print()
    return 1 if failures else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="soc",
        description="A RISC-V SoC and the nine hardware modules it is built from.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("modules", help="the modules, their HDL and their benches")
    sub.add_parser("map", help="the SoC memory map")
    sub.add_parser("gen", help="regenerate headers and firmware from the map")

    sim = sub.add_parser("sim", help="build and run simulations")
    sim.add_argument("--only", action="append", metavar="NAME")
    sim.add_argument("--no-soc", action="store_true", help="skip the SoC bench")
    sim.add_argument("--timeout", type=float, default=900.0)
    sim.add_argument("-v", "--verbose", action="store_true")

    linter = sub.add_parser("lint", help="Verilator lint over the synthesisable RTL")
    linter.add_argument("-v", "--verbose", action="store_true")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return {
        "modules": _cmd_modules,
        "map": _cmd_map,
        "gen": _cmd_gen,
        "sim": _cmd_sim,
        "lint": _cmd_lint,
    }[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
