"""Parse OpenSTA / PrimeTime `report_timing` text and classify each violating
path by its dominant cause (logic depth vs RC/interconnect vs clock skew), with a
fix suggestion. Format-tolerant: keys off the Delay/Time/Description rows common
to both tools."""
from __future__ import annotations
import re
from dataclasses import dataclass, field

# a cell-arc row carries a library cell in parens + a pin path (has '/')
_CELL = re.compile(r"\(([A-Za-z]\w*__\w+|sky130\w+)\)")
_NUM = re.compile(r"-?\d+\.\d+")


@dataclass
class Path:
    startpoint: str = "?"
    endpoint: str = "?"
    slack: float = 0.0
    violated: bool = False
    logic_depth: int = 0          # number of cell arcs on the data path
    cell_delay: float = 0.0
    net_delay: float = 0.0
    launch_clk: float = 0.0
    capture_clk: float = 0.0
    raw: str = field(default="", repr=False)

    @property
    def total_delay(self) -> float:
        return self.cell_delay + self.net_delay

    @property
    def net_frac(self) -> float:
        return self.net_delay / self.total_delay if self.total_delay else 0.0

    @property
    def skew(self) -> float:
        return self.capture_clk - self.launch_clk


def parse_report(text: str) -> list[Path]:
    """Split a report into per-path blocks and extract the fields we classify on."""
    blocks = re.split(r"(?=^\s*Startpoint:)", text, flags=re.M)
    paths: list[Path] = []
    for b in blocks:
        if "Startpoint:" not in b:
            continue
        p = Path(raw=b)
        m = re.search(r"Startpoint:\s*(\S+)", b)
        if m:
            p.startpoint = m.group(1)
        m = re.search(r"Endpoint:\s*(\S+)", b)
        if m:
            p.endpoint = m.group(1)
        clk_seen = 0
        for line in b.splitlines():
            low = line.lower()
            if "clock network delay" in low:
                nums = _NUM.findall(line)
                if nums:
                    if clk_seen == 0:
                        p.launch_clk = float(nums[0])
                    else:
                        p.capture_clk = float(nums[0])
                    clk_seen += 1
                continue
            if "slack" in low:
                nums = _NUM.findall(line)
                if nums:
                    p.slack = float(nums[0])
                    p.violated = "violated" in low or p.slack < 0
                continue
            if any(k in low for k in ("data arrival", "data required",
                                      "library setup", "clock clk", "----")):
                continue
            nums = _NUM.findall(line)
            if not nums:
                continue
            incr = float(nums[0])
            if _CELL.search(line) and "/" in line:        # cell arc
                p.logic_depth += 1
                p.cell_delay += incr
            elif "net " in low or "(net)" in low:           # interconnect
                p.net_delay += incr
        paths.append(p)
    return paths


def classify(p: Path, *, depth_thresh: int = 12, net_thresh: float = 0.45,
             skew_thresh: float = 0.30) -> tuple[str, str]:
    """Return (dominant_cause, fix_suggestion)."""
    if not p.violated and p.slack >= 0:
        return ("MET", "-")
    if p.net_frac > net_thresh:
        return ("RC/interconnect-dominated",
                "buffer/upsize long nets; improve placement to shorten wirelength")
    if p.logic_depth > depth_thresh:
        return ("logic-depth-dominated",
                "pipeline or restructure: reduce logic levels between flops")
    if abs(p.skew) > skew_thresh:
        return ("clock-skew-dominated",
                "rebalance CTS / apply useful skew; check clock insertion delay")
    return ("marginal/mixed",
            "resize the few critical cells or relax the period slightly")
