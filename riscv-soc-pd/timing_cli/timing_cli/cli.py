"""timing-report — classify STA timing violations and suggest fixes."""
from __future__ import annotations
import argparse
import sys
from .core import parse_report, classify


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="timing-report",
        description="Classify OpenSTA/PrimeTime timing violations (logic depth vs "
                    "RC vs clock skew) and emit a fix-suggestion table.")
    ap.add_argument("report", help="report_timing text file")
    ap.add_argument("--all", action="store_true", help="include MET paths")
    args = ap.parse_args(argv)

    with open(args.report) as f:
        paths = parse_report(f.read())

    print(f"{'endpoint':32}{'slack':>8}{'depth':>7}{'net%':>6}{'skew':>7}  cause")
    print("-" * 92)
    nviol = 0
    for p in paths:
        cause, fix = classify(p)
        if p.violated:
            nviol += 1
        elif not args.all:
            continue
        print(f"{p.endpoint[:32]:32}{p.slack:8.2f}{p.logic_depth:7d}"
              f"{p.net_frac*100:5.0f}%{p.skew:7.2f}  {cause}")
        print(f"{'':40}-> {fix}")
    print(f"\n{nviol} violating path(s) of {len(paths)}")
    return 1 if nviol else 0


if __name__ == "__main__":
    sys.exit(main())
