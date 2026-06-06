"""Self-contained test (no pytest needed): python tests/test_classify.py
Asserts the classifier picks the intended dominant cause for each sample report."""
import os
import sys

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))

from timing_cli.core import parse_report, classify  # noqa: E402

CASES = {
    "logic_depth.rpt": "logic-depth-dominated",
    "rc_dominated.rpt": "RC/interconnect-dominated",
    "skew.rpt": "clock-skew-dominated",
}


def main() -> int:
    fails = 0
    for fname, want in CASES.items():
        path = os.path.join(HERE, "..", "samples", fname)
        paths = parse_report(open(path).read())
        assert len(paths) == 1, f"{fname}: expected 1 path, got {len(paths)}"
        p = paths[0]
        cause, _ = classify(p)
        ok = cause == want
        fails += not ok
        print(f"  {fname:20} depth={p.logic_depth:2d} net%={p.net_frac*100:3.0f} "
              f"skew={p.skew:+.2f} slack={p.slack:+.2f} -> {cause} "
              f"[{'OK' if ok else 'FAIL exp ' + want}]")
    print("RESULT:", "PASS" if not fails else f"FAIL ({fails})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
