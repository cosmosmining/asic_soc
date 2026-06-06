#!/usr/bin/env python3
"""pt_report_parser -- classify PrimeTime / OpenSTA timing violations and
suggest physical-design fix categories.

Physical-design signoff lives in `report_timing` text. A real block produces
thousands of these paths across many corners; an engineer cannot eyeball them.
This tool ingests one or more PrimeTime (`pt_shell`) or OpenSTA `report_timing`
dumps and turns them into an actionable, prioritized picture:

  * parse every path block: start/endpoint, launch/capture clock, path group,
    check type (setup/hold), slack, and the per-pin arrival path;
  * derive PD features per path -- logic depth, net-vs-cell delay split,
    path category (reg2reg / in2reg / reg2out / in2out), cross-domain (CDC);
  * classify each *violating* path into a fix category a PD engineer would
    actually reach for (upsize+VT swap, restructure/retime, net/placement,
    useful skew, I/O budget, hold-buffer, CDC/constraint review);
  * aggregate a Pareto so the biggest lever is obvious, and emit text / JSON /
    CSV for dashboards or a fix-tracking spreadsheet.

The parser is format-tolerant: PrimeTime and OpenSTA `report_timing` share the
same layout, and column counts vary with `-significant_digits`. Pure stdlib;
runs anywhere Python 3.8+ does.

Usage:
    pt_report_parser.py REPORT [REPORT ...] [options]
    pt_report_parser.py samples/setup_ss_corner.rpt --top 10
    pt_report_parser.py *.rpt --json out.json --csv out.csv

See tools/pd/README.md for the full flow (generate reports with
tools/primetime/report_signoff.tcl, then feed them here).
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import sys
from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional

# --------------------------------------------------------------------------- #
# Tuning knobs (PD heuristics). Overridable on the CLI.
# --------------------------------------------------------------------------- #
DEPTH_HI = 18          # logic depth (combinational cells) above which a setup
                       # path is "logic-dominated" -> restructure/retime.
NET_FRAC_HI = 0.40     # fraction of data-path delay in interconnect above which
                       # a path is "net-dominated" -> placement/routing/buffer.
MARGINAL_NS = 0.10     # |slack| under which a near-miss is best closed with
                       # useful skew / small upsizing rather than restructuring.

# Standard-cell output pin names across common libs (sky130_fd_sc_hd, Nangate,
# generic). Delay *to* an output pin is cell delay; delay to any other pin is
# interconnect (net) delay -- the basis for the net-vs-cell split.
OUTPUT_PINS = {
    "X", "Y", "Z", "ZN", "Q", "QN", "S", "SUM", "CO", "COUT", "CON",
    "O", "OUT", "Y1", "Y2", "GCLK",
}
CLOCK_PINS = {"CK", "CLK", "CLKN", "CLKIN", "GCLK", "GATE"}

# A cell whose type matches this is sequential (flop/latch), not logic depth.
_SEQ_RE = re.compile(r"(?:dff|df[rsx]?tp|edf|sdf|dlxtp|dlrtp|latch|dlatch)", re.I)

# --------------------------------------------------------------------------- #
# Line grammar
# --------------------------------------------------------------------------- #
_STARTPOINT = re.compile(r"^\s*Startpoint:\s*(?P<name>\S+)")
_ENDPOINT = re.compile(r"^\s*Endpoint:\s*(?P<name>\S+)")
_PATH_GROUP = re.compile(r"^\s*Path Group:\s*(?P<g>\S+)")
_PATH_TYPE = re.compile(r"^\s*Path Type:\s*(?P<t>\w+)")
_CLOCKED_BY = re.compile(r"clocked by (?P<clk>[^\s)]+)")
_POINT_HEADER = re.compile(r"^\s*Point\b.*\bIncr\b.*\bPath\b")
_CLOCK_EDGE = re.compile(
    r"^\s*clock\s+(?P<clk>\S+)\s+\((?:rise|fall) edge\)\s+"
    r"(?P<incr>-?\d+\.\d+)\s+(?P<path>-?\d+\.\d+)"
)
_LIB_CHECK = re.compile(r"^\s*library (?P<kind>setup|hold) time")
_EXT_DELAY = re.compile(r"(?P<dir>input|output) external delay")
_ARRIVAL = re.compile(r"^\s*data arrival time\s+(?P<val>-?\d+\.\d+)")
_REQUIRED = re.compile(r"^\s*data required time\s+(?P<val>-?\d+\.\d+)")
_SLACK = re.compile(r"^\s*slack\s+\((?P<state>MET|VIOLATED)\)\s+(?P<val>-?\d+\.\d+)")
# A pin row: <inst>/<pin> (<cell>)  <incr>  <path> [r|f]
_PIN_LINE = re.compile(
    r"^\s*(?P<inst>[\w$\\./:\[\]]+)/(?P<pin>[A-Za-z][\w]*(?:\[\d+\])?)\s+"
    r"\((?P<cell>[\w$\\.]+)\)\s+"
    r"(?P<incr>-?\d+\.\d+)\s+(?P<path>-?\d+\.\d+)\s*(?P<edge>[rf])?\s*$"
)

# Fix categories ------------------------------------------------------------ #
FIX_CDC = "CDC / constraint review (false_path | multicycle | clock_groups)"
FIX_RESTRUCTURE = "Restructure / retime / pipeline (cut logic depth)"
FIX_UPSIZE_VT = "Gate upsize + VT swap (HVT->LVT on critical cells)"
FIX_NET_PLACE = "Net / placement / routing fix (buffer, repair-transition, shorten wire)"
FIX_USEFUL_SKEW = "Useful skew / CTS adjustment"
FIX_IO_BUDGET = "I/O budget review (set_input_delay / set_output_delay)"
FIX_HOLD_BUFFER = "Hold-buffer / delay-cell insertion (P&R hold-fix step)"
FIX_HOLD_CDC = "Hold across domains: synchronizer / false_path (do NOT buffer)"


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #
@dataclass
class TimingPath:
    startpoint: str = ""
    endpoint: str = ""
    path_group: str = ""
    check_type: str = "setup"          # setup | hold
    slack: Optional[float] = None
    arrival: Optional[float] = None
    required: Optional[float] = None
    launch_clock: str = ""
    capture_clock: str = ""
    period: Optional[float] = None      # capture clock edge value, if single clk
    logic_depth: int = 0                # combinational cells on the data path
    cell_delay: float = 0.0
    net_delay: float = 0.0
    start_is_port: bool = False
    end_is_port: bool = False
    source: str = ""                    # originating report file
    worst_cell: str = ""                # largest single-arc cell (a fix target)

    # ---- derived ---------------------------------------------------------- #
    @property
    def violated(self) -> bool:
        return self.slack is not None and self.slack < 0.0

    @property
    def cross_domain(self) -> bool:
        lc, cc = self.launch_clock, self.capture_clock
        return bool(lc and cc and lc != cc)

    @property
    def net_frac(self) -> float:
        tot = self.cell_delay + self.net_delay
        return (self.net_delay / tot) if tot > 1e-12 else 0.0

    @property
    def category(self) -> str:
        if self.start_is_port and self.end_is_port:
            return "in2out"
        if self.start_is_port:
            return "in2reg"
        if self.end_is_port:
            return "reg2out"
        return "reg2reg"

    @property
    def domain(self) -> str:
        if self.cross_domain:
            return f"{self.launch_clock}->{self.capture_clock}"
        return self.launch_clock or self.capture_clock or "(unclocked)"

    @property
    def implied_fmax_mhz(self) -> Optional[float]:
        """Max frequency this path would allow: 1 / (period - slack)."""
        if self.period and self.period > 0 and self.slack is not None:
            min_period = self.period - self.slack
            if min_period > 1e-9:
                return 1000.0 / min_period
        return None


@dataclass
class FixSuggestion:
    primary: str
    rationale: str
    secondary: List[str] = field(default_factory=list)
    routing_candidate: bool = False     # net-dominated -> global-routing lever


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #
def _new_block(source: str) -> dict:
    return {
        "source": source,
        "_under": None,        # 'start' | 'end' -- which clocked-by we expect
        "_section": "pre",     # pre | data | capture
        "_seen_arrival": False,
        "path": TimingPath(source=source),
    }


def _finalize(block: dict) -> TimingPath:
    p: TimingPath = block["path"]
    # If the capture clock was never named explicitly but a single clock drove
    # the launch, assume same-clock capture (the common single-clock case).
    if not p.capture_clock and p.launch_clock:
        p.capture_clock = p.launch_clock
    return p


def parse_report(text: str, source: str = "") -> List[TimingPath]:
    """Parse a PrimeTime/OpenSTA report_timing dump into TimingPath records."""
    paths: List[TimingPath] = []
    block: Optional[dict] = None
    clock_edge_hits = 0

    for raw in text.splitlines():
        line = raw.rstrip("\n")

        m = _STARTPOINT.match(line)
        if m:
            if block is not None and block["path"].startpoint:
                paths.append(_finalize(block))
            block = _new_block(source)
            block["path"].startpoint = m.group("name")
            block["_under"] = "start"
            clock_edge_hits = 0
            cb = _CLOCKED_BY.search(line)
            if cb:
                block["path"].launch_clock = cb.group("clk")
            continue
        if block is None:
            continue
        p: TimingPath = block["path"]

        m = _ENDPOINT.match(line)
        if m:
            p.endpoint = m.group("name")
            block["_under"] = "end"
            cb = _CLOCKED_BY.search(line)
            if cb:
                p.capture_clock = cb.group("clk")
            continue

        # "(... clocked by X)" continuation lines under start/endpoint headers
        cb = _CLOCKED_BY.search(line)
        if cb and "Startpoint" not in line and "Endpoint" not in line \
                and block["_section"] == "pre":
            if block["_under"] == "end":
                p.capture_clock = p.capture_clock or cb.group("clk")
            else:
                p.launch_clock = p.launch_clock or cb.group("clk")
        if "input port" in line and block["_under"] == "start":
            p.start_is_port = True
        if "output port" in line and block["_under"] == "end":
            p.end_is_port = True

        m = _PATH_GROUP.match(line)
        if m:
            p.path_group = m.group("g")
            continue
        m = _PATH_TYPE.match(line)
        if m:
            p.check_type = "hold" if m.group("t").lower() == "min" else "setup"
            continue

        if _POINT_HEADER.match(line):
            block["_section"] = "data"
            continue

        m = _EXT_DELAY.match(line) or _EXT_DELAY.search(line)
        if m:
            if m.group("dir") == "input":
                p.start_is_port = True
            else:
                p.end_is_port = True

        m = _CLOCK_EDGE.match(line)
        if m:
            clock_edge_hits += 1
            # Second clock-edge line = capture edge; its path value is the
            # effective period for a single-clock setup path.
            if clock_edge_hits >= 2 and p.period is None:
                try:
                    p.period = float(m.group("path"))
                except ValueError:
                    pass
            continue

        m = _LIB_CHECK.match(line)
        if m:
            # Authoritative check-type signal (overrides Path Type if present).
            p.check_type = m.group("kind")
            continue

        if block["_section"] == "data":
            m = _PIN_LINE.match(line)
            if m:
                _accumulate_pin(p, m)
                continue

        m = _ARRIVAL.match(line)
        if m and not block["_seen_arrival"]:
            p.arrival = float(m.group("val"))
            block["_seen_arrival"] = True
            block["_section"] = "capture"
            continue
        m = _REQUIRED.match(line)
        if m and p.required is None:
            p.required = float(m.group("val"))
            continue

        m = _SLACK.match(line)
        if m:
            p.slack = float(m.group("val"))
            paths.append(_finalize(block))
            block = None
            continue

    if block is not None and block["path"].startpoint:
        paths.append(_finalize(block))
    return paths


def _accumulate_pin(p: TimingPath, m: "re.Match") -> None:
    pin = m.group("pin")
    cell = m.group("cell")
    try:
        incr = float(m.group("incr"))
    except ValueError:
        return
    base_pin = pin.split("[")[0]
    if base_pin in CLOCK_PINS:
        return  # clock network, not data delay
    if base_pin in OUTPUT_PINS:
        p.cell_delay += incr
        if not _SEQ_RE.search(cell):
            p.logic_depth += 1
            if incr > 0 and (not p.worst_cell or incr > getattr(p, "_worst_arc", 0.0)):
                p._worst_arc = incr  # type: ignore[attr-defined]
                p.worst_cell = cell
    else:
        p.net_delay += incr


# --------------------------------------------------------------------------- #
# Classification -> fix suggestion
# --------------------------------------------------------------------------- #
def suggest_fix(p: TimingPath, depth_hi: int = DEPTH_HI,
                net_frac_hi: float = NET_FRAC_HI,
                marginal_ns: float = MARGINAL_NS) -> FixSuggestion:
    """Map a violating path to the fix category a PD engineer would reach for."""
    if p.check_type == "hold":
        if p.cross_domain:
            return FixSuggestion(
                FIX_HOLD_CDC,
                "Hold fail between {} and {}: almost always a missing CDC "
                "synchronizer / false_path, not a real hold arc. Buffering it "
                "wastes area and hides the real bug.".format(
                    p.launch_clock, p.capture_clock),
            )
        return FixSuggestion(
            FIX_HOLD_BUFFER,
            "Same-clock hold violation ({:.3f} ns): insert delay/hold buffers on "
            "the short path in the P&R hold-fix step; confirm clock skew first. "
            "Fix conservatively -- over-insertion bloats area and can re-open "
            "setup.".format(p.slack if p.slack is not None else 0.0),
        )

    # ---- setup ------------------------------------------------------------ #
    if p.cross_domain:
        return FixSuggestion(
            FIX_CDC,
            "Launch {} != capture {}: confirm the intended relationship "
            "(set_clock_groups -asynchronous / set_false_path / "
            "set_multicycle_path) BEFORE optimizing -- the path may not be "
            "real.".format(p.launch_clock, p.capture_clock),
        )

    if p.category in ("in2reg", "reg2out", "in2out"):
        sec = []
        if p.net_frac >= net_frac_hi:
            sec.append(FIX_NET_PLACE)
        if p.logic_depth >= depth_hi:
            sec.append(FIX_RESTRUCTURE)
        return FixSuggestion(
            FIX_IO_BUDGET,
            "{} path: slack is set by the I/O delay assumption. Re-check "
            "set_input_delay/set_output_delay against the real interface budget "
            "before touching logic -- often a constraint issue, not a design "
            "one.".format(p.category),
            secondary=sec,
        )

    # reg2reg
    if p.net_frac >= net_frac_hi:
        return FixSuggestion(
            FIX_NET_PLACE,
            "Net-dominated: {:.0f}% of the {:.3f} ns data path is interconnect. "
            "Buffer/repair-transition, pull the endpoints closer in placement, "
            "and relieve routing congestion. This is exactly the lever a better "
            "global router (e.g. GNN-accelerated DGR) pulls -- shorter, less "
            "congested nets shrink this slack directly.".format(
                100 * p.net_frac, p.arrival or 0.0),
            secondary=[FIX_UPSIZE_VT],
            routing_candidate=True,
        )
    if p.logic_depth >= depth_hi:
        return FixSuggestion(
            FIX_RESTRUCTURE,
            "Logic-dominated: {} combinational levels. Upsizing alone won't "
            "close it -- restructure the cone, retime across the flops, or add a "
            "pipeline stage. (Largest single arc here: {}.)".format(
                p.logic_depth, p.worst_cell or "n/a"),
            secondary=[FIX_UPSIZE_VT],
        )
    if p.slack is not None and abs(p.slack) <= marginal_ns:
        return FixSuggestion(
            FIX_USEFUL_SKEW,
            "Near-miss ({:.3f} ns): borrow time with useful skew at CTS or a "
            "single upsize/VT swap on the worst cell ({}). Don't restructure for "
            "this little.".format(p.slack, p.worst_cell or "n/a"),
            secondary=[FIX_UPSIZE_VT],
        )
    return FixSuggestion(
        FIX_UPSIZE_VT,
        "Cell-dominated, moderate depth ({} levels): upsize the worst cells "
        "({}) and swap critical HVT cells to LVT. Cheapest effective lever "
        "here.".format(p.logic_depth, p.worst_cell or "n/a"),
        secondary=([FIX_NET_PLACE] if p.net_frac >= net_frac_hi / 2 else []),
    )


def severity(p: TimingPath) -> str:
    s = p.slack if p.slack is not None else 0.0
    if s >= 0:
        return "met"
    if s <= -0.25:
        return "critical"
    if s <= -0.10:
        return "high"
    return "low"


# --------------------------------------------------------------------------- #
# Aggregation
# --------------------------------------------------------------------------- #
@dataclass
class Analysis:
    paths: List[TimingPath]
    fixes: Dict[int, FixSuggestion]

    @property
    def violations(self) -> List[TimingPath]:
        return [p for p in self.paths if p.violated]

    def worst(self, check: Optional[str] = None) -> Optional[TimingPath]:
        pool = [p for p in self.paths
                if p.slack is not None and (check is None or p.check_type == check)]
        return min(pool, key=lambda p: p.slack) if pool else None

    def tns(self, check: Optional[str] = None) -> float:
        return sum(p.slack for p in self.paths
                   if p.violated and (check is None or p.check_type == check))

    def _count(self, key) -> Dict[str, Dict[str, float]]:
        out: Dict[str, Dict[str, float]] = {}
        for p in self.paths:
            k = key(p)
            d = out.setdefault(k, {"paths": 0, "viol": 0, "worst": 0.0, "tns": 0.0})
            d["paths"] += 1
            if p.violated:
                d["viol"] += 1
                d["tns"] += p.slack
                d["worst"] = min(d["worst"], p.slack)
        return out

    def by_check(self):
        return self._count(lambda p: p.check_type)

    def by_domain(self):
        return self._count(lambda p: p.domain)

    def by_category(self):
        return self._count(lambda p: p.category)

    def by_group(self):
        return self._count(lambda p: p.path_group or "(none)")

    def fix_histogram(self) -> Dict[str, Dict[str, float]]:
        out: Dict[str, Dict[str, float]] = {}
        for p in self.violations:
            f = self.fixes[id(p)]
            d = out.setdefault(f.primary, {"paths": 0, "tns": 0.0, "routing": 0})
            d["paths"] += 1
            d["tns"] += p.slack if p.slack is not None else 0.0
            if f.routing_candidate:
                d["routing"] += 1
        return out


def analyze(paths: List[TimingPath], **kw) -> Analysis:
    fixes = {id(p): suggest_fix(p, **kw) for p in paths if p.violated}
    return Analysis(paths=paths, fixes=fixes)


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #
def _bar(n: int, total: int, width: int = 24) -> str:
    if total <= 0:
        return ""
    fill = int(round(width * n / total))
    return "#" * fill + "." * (width - fill)


def render_text(a: Analysis, top: int = 5) -> str:
    o = io.StringIO()
    w = o.write
    srcs = sorted({p.source for p in a.paths if p.source})
    viol = a.violations
    w("=" * 74 + "\n")
    w("PrimeTime / OpenSTA Timing Analysis\n")
    w("=" * 74 + "\n")
    if srcs:
        w("source(s)   : {}\n".format(", ".join(os.path.basename(s) for s in srcs)))
    w("paths parsed: {:<6} violations: {:<6} clean: {}\n".format(
        len(a.paths), len(viol), len(a.paths) - len(viol)))
    ws = a.worst("setup")
    wh = a.worst("hold")
    if ws and ws.slack is not None:
        extra = ""
        if ws.implied_fmax_mhz:
            extra = "   implied fmax {:.1f} MHz @ {:.2f} ns period".format(
                ws.implied_fmax_mhz, ws.period or 0.0)
        w("worst setup : {:+.3f} ns   TNS {:+.3f} ns{}\n".format(
            ws.slack, a.tns("setup"), extra))
    if wh and wh.slack is not None:
        w("worst hold  : {:+.3f} ns   TNS {:+.3f} ns\n".format(
            wh.slack, a.tns("hold")))
    if not viol:
        w("\nTIMING MET -- no violations. The worst path above is positive-slack "
          "headroom.\n")
        return o.getvalue()

    def table(title, data, label_w=22):
        w("\n" + title + "\n")
        for k in sorted(data, key=lambda k: (data[k]["worst"], -data[k]["viol"])):
            d = data[k]
            if d["viol"] == 0:
                continue
            w("  {:<{lw}} viol {:>3}  worst {:+.3f}  TNS {:+.3f}\n".format(
                k[:label_w], int(d["viol"]), d["worst"], d["tns"], lw=label_w))

    table("By check type:", a.by_check())
    table("By clock domain:", a.by_domain())
    table("By path category:", a.by_category())

    w("\nTop {} violating paths:\n".format(min(top, len(viol))))
    for p in sorted(viol, key=lambda p: p.slack)[:top]:
        f = a.fixes[id(p)]
        w("  {:+.3f} {:<5} {:<7} depth {:>2} net {:>3.0f}%  {} -> {}\n".format(
            p.slack, p.check_type, p.category, p.logic_depth, 100 * p.net_frac,
            _short(p.startpoint), _short(p.endpoint)))
        w("        => {}\n".format(f.primary))

    w("\nPrioritized fix strategy (violating paths, worst-TNS first):\n")
    hist = a.fix_histogram()
    tot = len(viol)
    for cat in sorted(hist, key=lambda c: hist[c]["tns"]):
        d = hist[cat]
        flag = "  <- routing-quality lever (DeepDGR)" if d["routing"] else ""
        w("  {:>3}  {}  {}{}\n".format(
            int(d["paths"]), _bar(int(d["paths"]), tot), cat, flag))
    w("\n")
    return o.getvalue()


def _short(name: str, keep: int = 40) -> str:
    return name if len(name) <= keep else "..." + name[-(keep - 3):]


def to_json(a: Analysis) -> str:
    def path_obj(p: TimingPath) -> dict:
        d = asdict(p)
        d.update(
            violated=p.violated, category=p.category, domain=p.domain,
            cross_domain=p.cross_domain, net_frac=round(p.net_frac, 4),
            severity=severity(p),
            implied_fmax_mhz=(round(p.implied_fmax_mhz, 2)
                              if p.implied_fmax_mhz else None),
        )
        d.pop("_worst_arc", None)
        if p.violated:
            f = a.fixes[id(p)]
            d["fix"] = {"primary": f.primary, "rationale": f.rationale,
                        "secondary": f.secondary,
                        "routing_candidate": f.routing_candidate}
        return d

    summary = {
        "paths": len(a.paths),
        "violations": len(a.violations),
        "worst_setup_slack": getattr(a.worst("setup"), "slack", None),
        "worst_hold_slack": getattr(a.worst("hold"), "slack", None),
        "tns_setup": round(a.tns("setup"), 4),
        "tns_hold": round(a.tns("hold"), 4),
        "fix_histogram": a.fix_histogram(),
    }
    return json.dumps({"summary": summary,
                       "paths": [path_obj(p) for p in a.paths]}, indent=2)


def to_csv(a: Analysis) -> str:
    o = io.StringIO()
    cols = ["source", "check_type", "slack", "severity", "category", "domain",
            "path_group", "logic_depth", "net_frac", "arrival", "period",
            "implied_fmax_mhz", "worst_cell", "startpoint", "endpoint",
            "fix_primary"]
    wtr = csv.writer(o)
    wtr.writerow(cols)
    for p in a.paths:
        fix = a.fixes[id(p)].primary if p.violated else ""
        wtr.writerow([
            os.path.basename(p.source), p.check_type,
            "" if p.slack is None else round(p.slack, 4), severity(p),
            p.category, p.domain, p.path_group, p.logic_depth,
            round(p.net_frac, 4), "" if p.arrival is None else p.arrival,
            "" if p.period is None else p.period,
            round(p.implied_fmax_mhz, 2) if p.implied_fmax_mhz else "",
            p.worst_cell, p.startpoint, p.endpoint, fix,
        ])
    return o.getvalue()


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="Classify PrimeTime/OpenSTA timing violations and suggest "
                    "PD fix categories.")
    ap.add_argument("reports", nargs="+", help="report_timing dump file(s)")
    ap.add_argument("--top", type=int, default=5,
                    help="how many worst paths to list (default 5)")
    ap.add_argument("--json", metavar="FILE",
                    help="write full analysis as JSON ('-' for stdout)")
    ap.add_argument("--csv", metavar="FILE",
                    help="write one row per path as CSV ('-' for stdout)")
    ap.add_argument("--depth-hi", type=int, default=DEPTH_HI,
                    help="logic-depth threshold for 'restructure' (default %d)"
                         % DEPTH_HI)
    ap.add_argument("--net-frac-hi", type=float, default=NET_FRAC_HI,
                    help="net-delay fraction for 'net-dominated' (default %.2f)"
                         % NET_FRAC_HI)
    ap.add_argument("--marginal-ns", type=float, default=MARGINAL_NS,
                    help="|slack| for 'useful-skew' near-miss (default %.2f)"
                         % MARGINAL_NS)
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the text report (use with --json/--csv)")
    ap.add_argument("--fail-on-violation", action="store_true",
                    help="exit non-zero if any path is violated (for CI gating)")
    args = ap.parse_args(argv)

    paths: List[TimingPath] = []
    for fn in args.reports:
        try:
            with open(fn, "r", errors="replace") as fh:
                paths.extend(parse_report(fh.read(), source=fn))
        except OSError as e:
            print("error: cannot read %s: %s" % (fn, e), file=sys.stderr)
            return 2

    if not paths:
        print("warning: no timing paths parsed from %s" % ", ".join(args.reports),
              file=sys.stderr)

    a = analyze(paths, depth_hi=args.depth_hi, net_frac_hi=args.net_frac_hi,
                marginal_ns=args.marginal_ns)

    if not args.quiet:
        sys.stdout.write(render_text(a, top=args.top))

    if args.json:
        out = to_json(a)
        if args.json == "-":
            sys.stdout.write(out + "\n")
        else:
            with open(args.json, "w") as fh:
                fh.write(out)
            if not args.quiet:
                print("wrote %s" % args.json)
    if args.csv:
        out = to_csv(a)
        if args.csv == "-":
            sys.stdout.write(out)
        else:
            with open(args.csv, "w") as fh:
                fh.write(out)
            if not args.quiet:
                print("wrote %s" % args.csv)

    if args.fail_on_violation and a.violations:
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        # downstream closed early (e.g. piped to `head`); exit quietly
        try:
            sys.stdout.close()
        except Exception:
            pass
        os._exit(0)
