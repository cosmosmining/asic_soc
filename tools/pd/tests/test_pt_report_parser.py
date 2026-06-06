"""Unit tests for pt_report_parser: parsing, feature extraction, fix
classification, aggregation, and serialization.

Run:  pytest tools/pd/tests -q
"""
import json
import os

import pt_report_parser as pt
from conftest import SAMPLES

SETUP = os.path.join(SAMPLES, "setup_ss_corner.rpt")
HOLD = os.path.join(SAMPLES, "hold_ff_corner.rpt")
CLEAN = os.path.join(SAMPLES, "clean_signoff.rpt")


def _read(path):
    with open(path) as fh:
        return fh.read()


def _paths(path):
    return pt.parse_report(_read(path), source=path)


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #
def test_setup_sample_path_count():
    paths = _paths(SETUP)
    assert len(paths) == 6
    assert sum(p.violated for p in paths) == 5


def test_slack_required_arrival_consistency():
    # slack must equal required - arrival (setup) within float tolerance
    for p in _paths(SETUP):
        assert p.slack is not None and p.arrival is not None and p.required is not None
        assert abs(p.slack - (p.required - p.arrival)) < 1e-6


def test_endpoints_and_clocks():
    p = _paths(SETUP)[0]  # worst path, the divider cone
    assert p.startpoint == "u_div/quotient_reg[18]"
    assert p.endpoint == "u_alu/result_reg[7]"
    assert p.launch_clock == "clk" and p.capture_clock == "clk"
    assert not p.cross_domain
    assert p.check_type == "setup"


def test_worst_path_is_deep_logic():
    worst = min(_paths(SETUP), key=lambda p: p.slack)
    assert abs(worst.slack - (-0.60)) < 1e-6
    assert worst.logic_depth == 20          # 20-level divider cone
    assert worst.category == "reg2reg"
    assert worst.net_frac < pt.NET_FRAC_HI   # logic-, not net-dominated


def test_net_dominated_path_features():
    # The reg2reg path ending at the regfile is the long-wire one.
    p = [p for p in _paths(SETUP)
         if p.endpoint == "u_regfile/regs_reg[27][9]"][0]
    assert p.net_frac >= pt.NET_FRAC_HI
    assert p.logic_depth == 5
    assert abs(p.slack - (-0.30)) < 1e-6


def test_period_and_implied_fmax():
    p = _paths(SETUP)[0]
    assert abs(p.period - 4.0) < 1e-6
    # implied fmax = 1000 / (period - slack)
    assert abs(p.implied_fmax_mhz - 1000.0 / (4.0 - p.slack)) < 1e-3


# --------------------------------------------------------------------------- #
# I/O and hold
# --------------------------------------------------------------------------- #
def test_input_port_detected_as_in2reg():
    p = [p for p in _paths(SETUP) if p.startpoint.startswith("imem_rdata")][0]
    assert p.start_is_port and not p.end_is_port
    assert p.category == "in2reg"


def test_hold_sample():
    paths = _paths(HOLD)
    assert len(paths) == 2
    viol = [p for p in paths if p.violated][0]
    assert viol.check_type == "hold"
    assert abs(viol.slack - (-0.05)) < 1e-6
    # hold slack == arrival - required
    assert abs(viol.slack - (viol.arrival - viol.required)) < 1e-6


def test_clean_signoff_is_met():
    paths = _paths(CLEAN)
    assert len(paths) == 2
    assert all(not p.violated for p in paths)
    worst = min(paths, key=lambda p: p.slack)
    assert abs(worst.slack - 6.52) < 1e-6          # matches real OpenLane run
    assert abs(worst.implied_fmax_mhz - 74.18) < 0.1


# --------------------------------------------------------------------------- #
# Classification -> fix suggestion
# --------------------------------------------------------------------------- #
def _fix_for(paths, endpoint):
    p = [p for p in paths if p.endpoint == endpoint][0]
    return p, pt.suggest_fix(p)


def test_fix_restructure_for_deep_logic():
    p, f = _fix_for(_paths(SETUP), "u_alu/result_reg[7]")
    assert f.primary == pt.FIX_RESTRUCTURE
    assert not f.routing_candidate


def test_fix_net_place_flags_routing_candidate():
    p, f = _fix_for(_paths(SETUP), "u_regfile/regs_reg[27][9]")
    assert f.primary == pt.FIX_NET_PLACE
    assert f.routing_candidate is True          # the DeepDGR lever
    assert "DGR" in f.rationale or "router" in f.rationale


def test_fix_upsize_vt_for_cell_dominated():
    p, f = _fix_for(_paths(SETUP), "u_exmem/y_reg[12]")
    assert f.primary == pt.FIX_UPSIZE_VT


def test_fix_useful_skew_for_near_miss():
    p, f = _fix_for(_paths(SETUP), "u_if/pc_reg[5]")
    assert f.primary == pt.FIX_USEFUL_SKEW
    assert abs(p.slack) <= pt.MARGINAL_NS


def test_fix_io_budget_for_in2reg():
    p, f = _fix_for(_paths(SETUP), "u_idex/op_reg[4]")
    assert f.primary == pt.FIX_IO_BUDGET


def test_fix_hold_buffer_same_clock():
    p, f = _fix_for(_paths(HOLD), "u_alu/shadow_reg[2]")
    assert f.primary == pt.FIX_HOLD_BUFFER


# Cross-domain paths exercised with focused synthetic blocks (the real design is
# single-clock, so these don't belong in the committed .rpt fixtures).
CDC_SETUP = """
  Startpoint: u_cdc/src_reg[0]
              (rising edge-triggered flip-flop clocked by clk)
  Endpoint: u_cdc/dst_reg[0]
            (rising edge-triggered flip-flop clocked by clk_gpu)
  Path Group: clk_gpu
  Path Type: max

  Point                                          Incr      Path
  ----------------------------------------------------------------
  clock clk (rise edge)                          0.0000    0.0000
  u_cdc/src_reg[0]/CK (sky130_fd_sc_hd__dfrtp_1) 0.0000    0.0000 r
  u_cdc/src_reg[0]/Q (sky130_fd_sc_hd__dfrtp_1)  0.4000    0.4000 r
  u_cdc/dst_reg[0]/D (sky130_fd_sc_hd__dfxtp_1)  0.2000    0.6000 r
  data arrival time                                        0.6000

  clock clk_gpu (rise edge)                      0.5000    0.5000
  u_cdc/dst_reg[0]/CK (sky130_fd_sc_hd__dfxtp_1) 0.0000    0.5000 r
  library setup time                            -0.1000    0.4000
  data required time                                       0.4000
  ----------------------------------------------------------------
  data required time                                       0.4000
  data arrival time                                       -0.6000
  ----------------------------------------------------------------
  slack (VIOLATED)                                        -0.2000
"""

CDC_HOLD = CDC_SETUP.replace("Path Type: max", "Path Type: min").replace(
    "library setup time", "library hold time")


def test_cross_domain_setup_is_cdc_constraint():
    p = pt.parse_report(CDC_SETUP)[0]
    assert p.launch_clock == "clk" and p.capture_clock == "clk_gpu"
    assert p.cross_domain and p.domain == "clk->clk_gpu"
    assert pt.suggest_fix(p).primary == pt.FIX_CDC


def test_cross_domain_hold_is_cdc_not_buffer():
    p = pt.parse_report(CDC_HOLD)[0]
    assert p.check_type == "hold" and p.cross_domain
    assert pt.suggest_fix(p).primary == pt.FIX_HOLD_CDC


# --------------------------------------------------------------------------- #
# Aggregation + serialization
# --------------------------------------------------------------------------- #
def test_analyze_aggregations():
    a = pt.analyze(_paths(SETUP))
    assert len(a.violations) == 5
    assert abs(a.tns("setup") - (-1.29)) < 1e-6
    assert a.worst("setup").slack == -0.60
    hist = a.fix_histogram()
    # five distinct fix categories across five violating paths
    assert len(hist) == 5
    assert sum(int(d["paths"]) for d in hist.values()) == 5
    # exactly one routing-quality candidate (the net-dominated path)
    assert sum(int(d["routing"]) for d in hist.values()) == 1


def test_by_category_counts():
    a = pt.analyze(_paths(SETUP))
    cat = a.by_category()
    assert cat["reg2reg"]["viol"] == 4
    assert cat["in2reg"]["viol"] == 1


def test_json_roundtrip_is_valid():
    a = pt.analyze(_paths(SETUP))
    obj = json.loads(pt.to_json(a))
    assert obj["summary"]["violations"] == 5
    assert len(obj["paths"]) == 6
    # every violating path carries a fix block
    fixes = [p for p in obj["paths"] if p["violated"]]
    assert all("fix" in p for p in fixes)


def test_csv_has_row_per_path():
    a = pt.analyze(_paths(SETUP))
    csv_text = pt.to_csv(a)
    lines = [ln for ln in csv_text.splitlines() if ln.strip()]
    assert len(lines) == 1 + 6   # header + 6 paths
    assert "fix_primary" in lines[0]


def test_severity_buckets():
    paths = _paths(SETUP)
    worst = min(paths, key=lambda p: p.slack)
    assert pt.severity(worst) == "critical"     # -0.60
    nearmiss = [p for p in paths if abs((p.slack or 0) + 0.06) < 1e-6][0]
    assert pt.severity(nearmiss) == "low"       # -0.06


# --------------------------------------------------------------------------- #
# Robustness
# --------------------------------------------------------------------------- #
def test_empty_input():
    assert pt.parse_report("") == []
    a = pt.analyze([])
    assert a.violations == []
    # render must not crash on empty input
    assert isinstance(pt.render_text(a), str)


def test_cli_smoke(tmp_path, capsys):
    rc = pt.main([SETUP, "--quiet", "--json", "-"])
    out = capsys.readouterr().out
    assert rc == 0
    assert json.loads(out)["summary"]["violations"] == 5


def test_cli_fail_on_violation():
    assert pt.main([SETUP, "--quiet"]) == 0
    assert pt.main([SETUP, "--quiet", "--fail-on-violation"]) == 1
    assert pt.main([CLEAN, "--quiet", "--fail-on-violation"]) == 0
