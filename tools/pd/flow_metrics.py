#!/usr/bin/env python3
"""flow_metrics -- roll the RTL-to-GDSII flow reports into one PD scorecard.

After a run you have area scattered in a Yosys/`stat` dump, slack in an
OpenSTA/OpenROAD summary, and the clock target buried in a config. A reviewer
(or you, three weeks later) wants one line: how big, how fast, did it close.
This tool scrapes the committed reports and prints the numbers that matter --
cell count, area, target utilization, WNS/TNS, worst setup/hold, and the
*achieved fmax* implied by the worst setup slack -- as Markdown and JSON.

Measured vs. derived is labeled explicitly: area and slack are measured;
fmax = 1 / (clock_period - worst_setup_slack) is derived from them.

Usage:
    flow_metrics.py                     # auto-discover under gds_flow/
    flow_metrics.py --area A.rpt --timing T.rpt --config C.json --md -
"""
from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import dataclass, asdict
from typing import Optional

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@dataclass
class FlowMetrics:
    design: str = "riscv_pipeline"
    pdk: str = "sky130_fd_sc_hd"
    # ---- measured ----
    cells: Optional[int] = None
    area_um2: Optional[float] = None
    seq_area_pct: Optional[float] = None
    wns_ns: Optional[float] = None
    tns_ns: Optional[float] = None
    worst_setup_ns: Optional[float] = None
    worst_hold_ns: Optional[float] = None
    achieved_util_pct: Optional[float] = None
    # ---- targets / config ----
    clock_period_ns: Optional[float] = None
    target_util_pct: Optional[float] = None

    # ---- derived ----
    @property
    def area_mm2(self) -> Optional[float]:
        return round(self.area_um2 / 1e6, 3) if self.area_um2 else None

    @property
    def timing_met(self) -> Optional[bool]:
        checks = [v for v in (self.worst_setup_ns, self.worst_hold_ns)
                  if v is not None]
        if not checks and self.wns_ns is None:
            return None
        if self.wns_ns is not None and self.wns_ns < 0:
            return False
        return all(v >= 0 for v in checks)

    @property
    def fmax_mhz(self) -> Optional[float]:
        if self.clock_period_ns and self.worst_setup_ns is not None:
            min_period = self.clock_period_ns - self.worst_setup_ns
            if min_period > 1e-9:
                return round(1000.0 / min_period, 1)
        return None

    @property
    def target_fmax_mhz(self) -> Optional[float]:
        if self.clock_period_ns:
            return round(1000.0 / self.clock_period_ns, 1)
        return None


# --------------------------------------------------------------------------- #
# Scrapers -- each returns the fields it can find; merged into FlowMetrics.
# --------------------------------------------------------------------------- #
def parse_area(text: str) -> dict:
    out: dict = {}
    m = re.search(r"Chip area for module\s+'\\?[\w]+':\s+([\d.]+)", text)
    if m:
        out["area_um2"] = float(m.group(1))
    m = re.search(r"Number of cells:\s+(\d+)", text)
    if not m:
        m = re.search(r"^\s*(\d+)\s+[\d.eE+]+\s+cells\s*$", text, re.M)
    if m:
        out["cells"] = int(m.group(1))
    m = re.search(r"sequential elements:\s+[\d.]+\s+\(([\d.]+)%\)", text)
    if m:
        out["seq_area_pct"] = float(m.group(1))
    return out


def parse_timing(text: str) -> dict:
    """Parse an OpenSTA/OpenROAD report_tns/wns/worst_slack summary."""
    out: dict = {}
    m = re.search(r"^\s*tns\s+(-?[\d.]+)", text, re.M)
    if m:
        out["tns_ns"] = float(m.group(1))
    m = re.search(r"^\s*wns\s+(-?[\d.]+)", text, re.M)
    if m:
        out["wns_ns"] = float(m.group(1))
    # worst setup/hold tied to the report_worst_slack -max/-min context
    mode = None
    for line in text.splitlines():
        if re.search(r"report_worst_slack\s+-max|\(Setup\)", line):
            mode = "setup"
        elif re.search(r"report_worst_slack\s+-min|\(Hold\)", line):
            mode = "hold"
        m = re.search(r"worst slack\s+(-?[\d.]+)", line)
        if m and mode:
            out["worst_%s_ns" % mode] = float(m.group(1))
    return out


def parse_config(text: str) -> dict:
    out: dict = {}
    try:
        cfg = json.loads(text)
    except json.JSONDecodeError:
        return out
    if "CLOCK_PERIOD" in cfg:
        out["clock_period_ns"] = float(cfg["CLOCK_PERIOD"])
    if "FP_CORE_UTIL" in cfg:
        out["target_util_pct"] = float(cfg["FP_CORE_UTIL"])
    if "DESIGN_NAME" in cfg:
        out["design"] = cfg["DESIGN_NAME"]
    return out


def parse_ol_summary(text: str) -> dict:
    """Optional: pull achieved utilization from an OpenLane metrics.csv/json
    if the user points us at one (not committed by default)."""
    out: dict = {}
    try:
        data = json.loads(text)
        for k in ("DesignArea_util", "core_util", "FP_CORE_UTIL_achieved"):
            if k in data:
                out["achieved_util_pct"] = float(data[k])
                break
    except json.JSONDecodeError:
        m = re.search(r"(?:core_?util|utilization)[,:\s]+([\d.]+)", text, re.I)
        if m:
            out["achieved_util_pct"] = float(m.group(1))
    return out


# --------------------------------------------------------------------------- #
def collect(area=None, timing=None, config=None, ol_summary=None) -> FlowMetrics:
    fm = FlowMetrics()
    fields = {}
    for path, fn in ((area, parse_area), (timing, parse_timing),
                     (config, parse_config), (ol_summary, parse_ol_summary)):
        if path and os.path.exists(path):
            with open(path, errors="replace") as fh:
                fields.update(fn(fh.read()))
    for k, v in fields.items():
        setattr(fm, k, v)
    return fm


def autodiscover() -> dict:
    g = os.path.join(_REPO, "gds_flow")
    cand = {
        "area": [os.path.join(g, "riscv_pipeline_sky130_area.rpt"),
                 os.path.join(g, "reports", "synthesis_area.rpt")],
        "timing": [os.path.join(g, "reports", "cts_timing_summary.rpt")],
        "config": [os.path.join(g, "openlane_config.json")],
    }
    found = {}
    for key, paths in cand.items():
        for p in paths:
            if os.path.exists(p):
                found[key] = p
                break
    return found


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #
def _fmt(v, unit="", nd=3):
    if v is None:
        return "n/a"
    if isinstance(v, bool):
        return "yes" if v else "NO"
    if isinstance(v, float):
        return ("{:." + str(nd) + "f}{}").format(v, unit)
    return "{}{}".format(v, unit)


def render_markdown(fm: FlowMetrics) -> str:
    met = fm.timing_met
    status = "n/a" if met is None else ("**MET**" if met else "**VIOLATED**")
    rows = [
        ("Design", fm.design, ""),
        ("PDK / library", fm.pdk, ""),
        ("Std cells", _fmt(fm.cells), "measured"),
        ("Cell area", _fmt(fm.area_mm2, " mm2") +
         (" ({} um2)".format(_fmt(fm.area_um2, "", 0)) if fm.area_um2 else ""),
         "measured"),
        ("Sequential area", _fmt(fm.seq_area_pct, " %", 1), "measured"),
        ("Target util (floorplan)", _fmt(fm.target_util_pct, " %", 0), "config"),
        ("Achieved core util", _fmt(fm.achieved_util_pct, " %", 1),
         "measured" if fm.achieved_util_pct is not None
         else "n/a (point --ol-summary at run)"),
        ("Clock target", _fmt(fm.clock_period_ns, " ns", 1) +
         (" ({} MHz)".format(_fmt(fm.target_fmax_mhz, "", 1))
          if fm.target_fmax_mhz else ""), "config"),
        ("WNS", _fmt(fm.wns_ns, " ns"), "measured"),
        ("TNS", _fmt(fm.tns_ns, " ns"), "measured"),
        ("Worst setup slack", _fmt(fm.worst_setup_ns, " ns"), "measured"),
        ("Worst hold slack", _fmt(fm.worst_hold_ns, " ns"), "measured"),
        ("Timing", status, "measured"),
        ("Achieved fmax", _fmt(fm.fmax_mhz, " MHz", 1), "derived: 1/(T-WNS)"),
    ]
    w = max(len(r[0]) for r in rows)
    out = ["# {} -- physical-design scorecard ({})".format(fm.design, fm.pdk),
           "",
           "| {:<{w}} | Value | Source |".format("Metric", w=w),
           "|{}|-------|--------|".format("-" * (w + 2))]
    for name, val, src in rows:
        out.append("| {:<{w}} | {} | {} |".format(name, val, src, w=w))
    out.append("")
    if fm.fmax_mhz and fm.target_fmax_mhz:
        head = fm.fmax_mhz - fm.target_fmax_mhz
        out.append("> Closed at {:.0f} MHz target with {:+.2f} ns setup slack "
                   "=> {:.1f} MHz achievable ({:+.1f} MHz headroom)."
                   .format(fm.target_fmax_mhz, fm.worst_setup_ns or 0,
                           fm.fmax_mhz, head))
    return "\n".join(out) + "\n"


def render_text(fm: FlowMetrics) -> str:
    return render_markdown(fm)


def to_json(fm: FlowMetrics) -> str:
    d = asdict(fm)
    d.update(area_mm2=fm.area_mm2, timing_met=fm.timing_met,
             fmax_mhz=fm.fmax_mhz, target_fmax_mhz=fm.target_fmax_mhz)
    return json.dumps(d, indent=2)


# --------------------------------------------------------------------------- #
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Summarize RTL-to-GDSII flow reports into a PD scorecard.")
    ap.add_argument("--area", help="Yosys stat / area report")
    ap.add_argument("--timing", help="OpenSTA report_tns/wns/worst_slack summary")
    ap.add_argument("--config", help="OpenLane config.json (clock + util)")
    ap.add_argument("--ol-summary", help="OpenLane metrics.csv/json (achieved util)")
    ap.add_argument("--json", metavar="FILE", help="write JSON ('-' for stdout)")
    ap.add_argument("--md", metavar="FILE", help="write Markdown ('-' for stdout)")
    args = ap.parse_args(argv)

    if not any([args.area, args.timing, args.config]):
        disc = autodiscover()
        args.area = args.area or disc.get("area")
        args.timing = args.timing or disc.get("timing")
        args.config = args.config or disc.get("config")

    fm = collect(args.area, args.timing, args.config, args.ol_summary)

    wrote_file = False
    if args.md and args.md != "-":
        with open(args.md, "w") as fh:
            fh.write(render_markdown(fm))
        print("wrote", args.md)
        wrote_file = True
    if args.json and args.json != "-":
        with open(args.json, "w") as fh:
            fh.write(to_json(fm))
        print("wrote", args.json)
        wrote_file = True

    # stdout: JSON if explicitly '-', else Markdown (default when no file given)
    if args.json == "-":
        print(to_json(fm))
    elif args.md == "-" or not wrote_file:
        import sys
        sys.stdout.write(render_markdown(fm))
    return 0


if __name__ == "__main__":
    import sys
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        os._exit(0)
