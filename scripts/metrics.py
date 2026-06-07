#!/usr/bin/env python3
"""metrics.py - distil per-stage flow artifacts into reports/summary.json.

A pt_shell log or a yosys stat dump is far too verbose to feed an agent every
loop. This collects the few numbers that actually gate progress -- test pass/
fail, synthesised cell/FF counts, formal status, and physical signoff (DRC/LVS/
slack) -- into one small JSON, while the full reports stay on disk for drilling
into a specific failure. Missing artifacts are reported as "not run", never an
error, so it is safe to call at any point in the flow.
"""
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return None


def synth_metrics():
    """Cell / flop counts from the *last* yosys `stat` block (reports/synth.log).

    yosys prints stat more than once per run; parse only the final block so the
    counts are not double-summed."""
    txt = _read(ROOT / "reports/synth.log")
    if not txt:
        return {"status": "not run"}
    blocks = re.split(r"\n\d+\. Printing statistics\.", txt)
    last = blocks[-1] if len(blocks) > 1 else txt
    cells = re.search(r"Number of cells:\s+(\d+)", last)
    ffs = sum(int(n) for n in re.findall(r"\$_(?:S?DFF\w*)_\s+(\d+)", last))
    top = re.search(r"===\s+(\S+)\s+===", last)
    out = {"status": "ok"}
    if top:
        out["top"] = top.group(1)
    if cells:
        out["cells"] = int(cells.group(1))
    if ffs:
        out["flops"] = ffs
    return out


def formal_metrics():
    """PASS/FAIL per SymbiYosys task (flow/formal/<name>/status)."""
    tasks = {}
    for status in glob.glob(str(ROOT / "flow/formal/*/status")):
        name = Path(status).parent.name
        tasks[name] = (_read(status) or "").strip().split("\n")[-1] or "unknown"
    if not tasks:
        return {"status": "not run"}
    ok = all(v.upper().startswith("PASS") for v in tasks.values())
    return {"status": "pass" if ok else "fail", "tasks": tasks}


def cocotb_metrics():
    """Test counts from the cocotb JUnit results.xml."""
    xmls = sorted(glob.glob(str(ROOT / "build/**/results.xml"), recursive=True)) + \
        sorted(glob.glob(str(ROOT / "sim/**/results.xml"), recursive=True))
    if not xmls:
        return {"status": "not run"}
    total = fails = 0
    for x in xmls:
        try:
            root = ET.parse(x).getroot()
        except ET.ParseError:
            continue
        for tc in root.iter("testcase"):
            total += 1
            if any(tc.iter("failure")) or any(tc.iter("error")):
                fails += 1
    return {"status": "pass" if fails == 0 and total else "fail",
            "tests": total, "failed": fails}


def signoff_metrics():
    """DRC/LVS/timing from the committed physical-signoff csv (OpenLane 2-row)."""
    csv = _read(ROOT / "gds_flow/signoff/metrics.csv")
    if not csv:
        return {"status": "not run"}
    rows = [r for r in csv.splitlines() if r.strip()]
    if len(rows) < 2:
        return {"status": "ok", "raw": csv[:200]}
    hdr = [h.strip() for h in rows[0].split(",")]
    val = [v.strip() for v in rows[1].split(",")]
    rec = dict(zip(hdr, val))
    # pull the handful of signoff numbers that actually gate a tapeout
    keys = {
        "tritonRoute_violations": "route_drc",
        "Magic_violations": "magic_drc",
        "lvs_total_errors": "lvs_errors",
        "wns": "wns_ns",
        "tns": "tns_ns",
        "DIEAREA_mm^2": "die_mm2",
        "synth_cell_count": "cells",
    }
    out = {"status": "ok"}
    for src, dst in keys.items():
        if src in rec and rec[src] not in ("", "-1"):
            out[dst] = rec[src]
    return out


def main():
    summary = {
        "synth": synth_metrics(),
        "formal": formal_metrics(),
        "cocotb": cocotb_metrics(),
        "signoff": signoff_metrics(),
    }
    out = ROOT / "reports/summary.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
