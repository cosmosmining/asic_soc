"""Tests for flow_metrics: scraping the real committed flow reports and the
derived PD numbers (area, utilization target, WNS/TNS, achieved fmax)."""
import json

import flow_metrics as fmtool


def test_parse_area_sky130():
    txt = """
       20789 2.01E+05 cells
   Chip area for module '\\riscv_pipeline': 201453.209600
     of which used for sequential elements: 73685.670400 (36.58%)
"""
    d = fmtool.parse_area(txt)
    assert d["cells"] == 20789
    assert abs(d["area_um2"] - 201453.2096) < 1e-3
    assert abs(d["seq_area_pct"] - 36.58) < 1e-6


def test_parse_area_numbered_format():
    txt = "   Number of cells:              29810\n" \
          "   Chip area for module '\\riscv_pipeline': 317868.611200\n"
    d = fmtool.parse_area(txt)
    assert d["cells"] == 29810
    assert abs(d["area_um2"] - 317868.6112) < 1e-3


def test_parse_timing_summary():
    txt = """
report_tns
tns 0.00
report_wns
wns 0.00
report_worst_slack -max (Setup)
worst slack 6.52
report_worst_slack -min (Hold)
worst slack 0.06
"""
    d = fmtool.parse_timing(txt)
    assert d["tns_ns"] == 0.0 and d["wns_ns"] == 0.0
    assert d["worst_setup_ns"] == 6.52
    assert d["worst_hold_ns"] == 0.06


def test_parse_config():
    txt = json.dumps({"DESIGN_NAME": "riscv_pipeline",
                      "CLOCK_PERIOD": 20, "FP_CORE_UTIL": 16})
    d = fmtool.parse_config(txt)
    assert d["clock_period_ns"] == 20.0
    assert d["target_util_pct"] == 16.0
    assert d["design"] == "riscv_pipeline"


def test_derived_fmax_and_status():
    fm = fmtool.FlowMetrics(clock_period_ns=20.0, worst_setup_ns=6.52,
                            worst_hold_ns=0.06, wns_ns=0.0, tns_ns=0.0,
                            area_um2=201453.2096)
    assert fm.timing_met is True
    assert fm.fmax_mhz == 74.2          # 1000 / (20 - 6.52)
    assert fm.target_fmax_mhz == 50.0
    assert fm.area_mm2 == 0.201         # 201453 um2, matches docs


def test_violated_status():
    fm = fmtool.FlowMetrics(clock_period_ns=4.0, worst_setup_ns=-0.6, wns_ns=-0.6)
    assert fm.timing_met is False
    # A violated design still has a real max frequency: you must slow the clock
    # by |slack|, so min period = 4 - (-0.6) = 4.6 ns -> 217.4 MHz, below the
    # 250 MHz target. fmax tells you exactly how far short you are.
    assert fm.fmax_mhz == 217.4
    assert fm.target_fmax_mhz == 250.0
    assert fm.fmax_mhz < fm.target_fmax_mhz


def test_autodiscover_real_reports_roundtrip():
    disc = fmtool.autodiscover()
    # the repo ships an area report, a timing summary, and a config
    assert "area" in disc and "timing" in disc and "config" in disc
    fm = fmtool.collect(disc.get("area"), disc.get("timing"), disc.get("config"))
    # Numbers are scraped from the live flow reports (which change when the flow
    # re-runs), so assert structure + self-consistency rather than magic values.
    assert isinstance(fm.cells, int) and fm.cells > 0
    assert fm.area_mm2 and fm.area_mm2 > 0
    assert fm.clock_period_ns and fm.worst_setup_ns is not None
    # achieved fmax is derived consistently from the parsed slack + period
    assert fm.fmax_mhz == round(1000.0 / (fm.clock_period_ns - fm.worst_setup_ns), 1)
    assert isinstance(fm.timing_met, bool)
    md = fmtool.render_markdown(fm)
    assert "Achieved fmax" in md and str(fm.fmax_mhz) in md
    obj = json.loads(fmtool.to_json(fm))
    assert obj["fmax_mhz"] == fm.fmax_mhz and obj["cells"] == fm.cells
