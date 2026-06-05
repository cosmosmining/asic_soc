#!/usr/bin/env python3
"""Generate representative PrimeTime-style report_timing fixtures.

These are SYNTHETIC inputs whose only purpose is to exercise pt_report_parser
across every fix category (net-dominated, logic-dominated, cell-dominated,
near-miss, I/O, hold, cross-domain) with arithmetically self-consistent path
arithmetic (every cumulative Path column is the running sum of Incr, and
slack == required - arrival). They mimic the exact layout PrimeTime / OpenSTA
emit so the parser is tested against the real grammar, not a toy.

The real, *measured* signoff numbers for this design live in
gds_flow/reports/ (a genuine OpenLane/OpenROAD run); clean_signoff.rpt below
mirrors that result (worst setup slack +6.52 ns @ 20 ns) so the "TIMING MET /
implied fmax" path of the tool is demonstrated on real numbers.

Run:  python3 tools/pd/samples/_gen_samples.py
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

HD = "sky130_fd_sc_hd__"
HERE = os.path.dirname(os.path.abspath(__file__))


@dataclass
class Gate:
    inst: str
    cell: str
    in_pin: str
    net_incr: float
    out_pin: str
    cell_incr: float
    edge: str = "r"


def _row(point: str, incr: float, path: float, edge: str = "") -> str:
    return "  {:<60}{:>9.4f}{:>11.4f} {}".format(point, incr, path, edge).rstrip()


def _flat(point: str, path: float) -> str:
    return "  {:<60}{:>9}{:>11.4f}".format(point, "", path)


def setup_path(start_reg: str, start_cell: str, gates: List[Gate],
               end_reg: str, end_cell: str, final_net: float,
               period: float, setup: float, uncertainty: float,
               group: str = "clk", launch_clk: str = "clk",
               capture_clk: Optional[str] = None,
               start_port: bool = False, in_ext_delay: float = 0.0,
               end_port: bool = False, out_ext_delay: float = 0.0) -> str:
    capture_clk = capture_clk or launch_clk
    L: List[str] = []
    # ---- header ----
    if start_port:
        L.append("  Startpoint: {}".format(start_reg))
        L.append("              (input port clocked by {})".format(launch_clk))
    else:
        L.append("  Startpoint: {}".format(start_reg))
        L.append("              (rising edge-triggered flip-flop clocked by {})"
                 .format(launch_clk))
    if end_port:
        L.append("  Endpoint: {}".format(end_reg))
        L.append("            (output port clocked by {})".format(capture_clk))
    else:
        L.append("  Endpoint: {}".format(end_reg))
        L.append("            (rising edge-triggered flip-flop clocked by {})"
                 .format(capture_clk))
    L.append("  Path Group: {}".format(group))
    L.append("  Path Type: max")
    L.append("")
    L.append("  {:<60}{:>9}{:>11} ".format("Point", "Incr", "Path"))
    L.append("  " + "-" * 80)

    p = 0.0
    L.append(_row("clock {} (rise edge)".format(launch_clk), 0.0, p))
    L.append(_row("clock network delay (ideal)", 0.0, p))
    if start_port:
        p += in_ext_delay
        L.append(_row("input external delay", in_ext_delay, p, "r"))
        L.append(_row("{} (in)".format(start_reg), 0.0, p, "r"))
    else:
        L.append(_row("{}/CK ({}{})".format(start_reg, HD, start_cell), 0.0, p, "r"))
        q_incr = 0.40  # launch flop clk->Q (a cell delay)
        p += q_incr
        L.append(_row("{}/Q ({}{})".format(start_reg, HD, start_cell), q_incr, p, "r"))

    edge = "r"
    for g in gates:
        p += g.net_incr
        L.append(_row("{}/{} ({}{})".format(g.inst, g.in_pin, HD, g.cell),
                      g.net_incr, p, g.edge))
        p += g.cell_incr
        edge = "f" if g.edge == "r" else "r"
        L.append(_row("{}/{} ({}{})".format(g.inst, g.out_pin, HD, g.cell),
                      g.cell_incr, p, edge))
    # final net into capture D (or output port)
    p += final_net
    if end_port:
        L.append(_row("{} (out)".format(end_reg), final_net, p, edge))
    else:
        L.append(_row("{}/D ({}{})".format(end_reg, HD, end_cell), final_net, p, edge))
    arrival = p
    L.append(_flat("data arrival time", arrival))
    L.append("")

    # ---- required ----
    r = period
    L.append(_row("clock {} (rise edge)".format(capture_clk), period, r))
    L.append(_row("clock network delay (ideal)", 0.0, r))
    if end_port:
        r -= uncertainty
        L.append(_row("clock uncertainty", -uncertainty, r))
        r -= out_ext_delay
        L.append(_row("output external delay", -out_ext_delay, r))
    else:
        L.append(_row("{}/CK ({}{})".format(end_reg, HD, end_cell), 0.0, r, "r"))
        r -= uncertainty
        L.append(_row("clock uncertainty", -uncertainty, r))
        r -= setup
        L.append(_row("library setup time", -setup, r))
    required = r
    L.append(_flat("data required time", required))
    L.append("  " + "-" * 80)
    L.append(_flat("data required time", required))
    L.append(_flat("data arrival time", -arrival))
    L.append("  " + "-" * 80)
    slack = required - arrival
    state = "VIOLATED" if slack < 0 else "MET"
    L.append(_flat("slack ({})".format(state), slack))
    L.append("")
    return "\n".join(L)


def hold_path(start_reg: str, start_cell: str, gates: List[Gate],
              end_reg: str, end_cell: str, final_net: float, hold: float,
              launch_clk: str = "clk", capture_clk: Optional[str] = None,
              group: str = "clk") -> str:
    capture_clk = capture_clk or launch_clk
    L: List[str] = []
    L.append("  Startpoint: {}".format(start_reg))
    L.append("              (rising edge-triggered flip-flop clocked by {})"
             .format(launch_clk))
    L.append("  Endpoint: {}".format(end_reg))
    L.append("            (rising edge-triggered flip-flop clocked by {})"
             .format(capture_clk))
    L.append("  Path Group: {}".format(group))
    L.append("  Path Type: min")
    L.append("")
    L.append("  {:<60}{:>9}{:>11} ".format("Point", "Incr", "Path"))
    L.append("  " + "-" * 80)
    p = 0.0
    L.append(_row("clock {} (rise edge)".format(launch_clk), 0.0, p))
    L.append(_row("clock network delay (ideal)", 0.0, p))
    L.append(_row("{}/CK ({}{})".format(start_reg, HD, start_cell), 0.0, p, "r"))
    q_incr = 0.20
    p += q_incr
    L.append(_row("{}/Q ({}{})".format(start_reg, HD, start_cell), q_incr, p, "r"))
    edge = "r"
    for g in gates:
        p += g.net_incr
        L.append(_row("{}/{} ({}{})".format(g.inst, g.in_pin, HD, g.cell),
                      g.net_incr, p, g.edge))
        p += g.cell_incr
        edge = "f" if g.edge == "r" else "r"
        L.append(_row("{}/{} ({}{})".format(g.inst, g.out_pin, HD, g.cell),
                      g.cell_incr, p, edge))
    p += final_net
    L.append(_row("{}/D ({}{})".format(end_reg, HD, end_cell), final_net, p, edge))
    arrival = p
    L.append(_flat("data arrival time", arrival))
    L.append("")
    r = 0.0
    L.append(_row("clock {} (rise edge)".format(capture_clk), 0.0, r))
    L.append(_row("clock network delay (ideal)", 0.0, r))
    L.append(_row("{}/CK ({}{})".format(end_reg, HD, end_cell), 0.0, r, "r"))
    r += hold
    L.append(_row("library hold time", hold, r))
    required = r
    L.append(_flat("data required time", required))
    L.append("  " + "-" * 80)
    L.append(_flat("data required time", required))
    L.append(_flat("data arrival time", arrival))
    L.append("  " + "-" * 80)
    slack = arrival - required
    state = "VIOLATED" if slack < 0 else "MET"
    L.append(_flat("slack ({})".format(state), slack))
    L.append("")
    return "\n".join(L)


def header(report: str, delay_type: str, corner: str) -> str:
    return "\n".join([
        "*" * 72,
        "Report : timing",
        "        -path_type full_clock_expanded",
        "        -delay_type {}".format(delay_type),
        "        -max_paths 200",
        "        -sort_by slack",
        "Design : riscv_pipeline",
        "Version: T-2022.03-SP5",
        "*" * 72,
        "",
        "Operating Conditions: {c}   Library: {h}{c}".format(c=corner, h=HD),
        "",
    ])


def chain(prefix: str, n: int, net: float, cell: float, cell_type: str,
          in_pin: str = "A", out_pin: str = "Y") -> List[Gate]:
    return [Gate("{}_{:04d}".format(prefix, i), cell_type, in_pin, net,
                 out_pin, cell, "r") for i in range(n)]


def write(name: str, text: str) -> None:
    path = os.path.join(HERE, name)
    with open(path, "w") as fh:
        fh.write(text)
    print("wrote", os.path.relpath(path))


# --------------------------------------------------------------------------- #
def gen_setup() -> str:
    P, SU, UN = 4.0, 0.15, 0.05  # 250 MHz stress target, slow corner
    out = [header("riscv_pipeline setup", "max", "ss_100C_1v60")]

    # B: logic-dominated divider cone (worst), depth 20, low net%
    gB = chain("u_div/_dz", 20, 0.045, 0.150, "xnor2_1", "A", "Y")
    out.append(setup_path("u_div/quotient_reg[18]", "dfrtp_1", gB,
                          "u_alu/result_reg[7]", "dfxtp_1", 0.10, P, SU, UN))

    # A: net-dominated reg2reg (routing candidate), depth 5, high net%
    gA = [
        Gate("u_div/_n0820_", "mux2_1", "A", 0.35, "X", 0.15),
        Gate("u_dpath/_n0433_", "nand2_1", "B", 0.42, "Y", 0.12),
        Gate("u_xbar/_n0145_", "o21ai_0", "A1", 0.55, "Y", 0.14),
        Gate("u_xbar/_n0162_", "and2_0", "A", 0.48, "X", 0.13),
        Gate("u_regfile/_n0233_", "mux2_1", "A", 0.50, "X", 0.12),
    ]
    out.append(setup_path("u_div/quotient_reg[18]", "dfrtp_1", gA,
                          "u_regfile/regs_reg[27][9]", "dfxtp_1", 0.74, P, SU, UN))

    # E: in2reg I/O path, violated by input-delay budget
    gE = [
        Gate("u_ctrl/_n012_", "nand2_1", "A", 0.30, "Y", 0.16),
        Gate("u_ctrl/_n031_", "o21ai_0", "A1", 0.30, "Y", 0.16),
        Gate("u_dec/_n077_", "and2_0", "A", 0.30, "X", 0.16),
        Gate("u_dec/_n091_", "mux2_1", "A", 0.30, "X", 0.16),
        Gate("u_dec/_n104_", "nand2_1", "A", 0.30, "Y", 0.16),
    ]
    out.append(setup_path("imem_rdata[17]", "", gE,
                          "u_idex/op_reg[4]", "dfxtp_1", 0.45, P, SU, UN,
                          group="in2reg", start_port=True, in_ext_delay=1.20))

    # C: cell-dominated moderate reg2reg -> upsize+VT
    gC = chain("u_alu/_cm", 10, 0.10, 0.24, "o21a_1", "A1", "X")
    out.append(setup_path("u_idex/a_reg[12]", "dfrtp_1", gC,
                          "u_exmem/y_reg[12]", "dfxtp_1", 0.18, P, SU, UN))

    # D: near-miss reg2reg -> useful skew
    gD = chain("u_pc/_pm", 8, 0.13, 0.28, "a21oi_1", "A1", "Y")
    out.append(setup_path("u_pc/pc_reg[5]", "dfrtp_1", gD,
                          "u_if/pc_reg[5]", "dfxtp_1", 0.18, P, SU, UN))

    # F: clean reg2reg -> MET (so "clean" count > 0)
    gF = chain("u_fwd/_fm", 4, 0.10, 0.20, "mux2_1", "A", "X")
    out.append(setup_path("u_idex/rs1_reg[3]", "dfrtp_1", gF,
                          "u_exmem/fwd_reg[3]", "dfxtp_1", 0.15, P, SU, UN))

    return "\n".join(out) + "\n"


def gen_hold() -> str:
    out = [header("riscv_pipeline hold", "min", "ff_n40C_1v95")]
    # G: same-clock hold violation -> hold buffer
    out.append(hold_path("u_alu/shamt_reg[2]", "dfrtp_1", [],
                         "u_alu/shadow_reg[2]", "dfxtp_1", 0.10, hold=0.35))
    # H: clean hold -> MET
    gH = [Gate("u_wb/_h0_", "buf_1", "A", 0.12, "X", 0.10),
          Gate("u_wb/_h1_", "buf_1", "A", 0.12, "X", 0.10)]
    out.append(hold_path("u_wb/data_reg[0]", "dfrtp_1", gH,
                         "u_wb/sync_reg[0]", "dfxtp_1", 0.10, hold=0.30))
    return "\n".join(out) + "\n"


def gen_clean() -> str:
    # Mirrors the real OpenLane signoff: 20 ns clock, worst setup slack +6.52 ns.
    P, SU, UN = 20.0, 0.15, 0.0
    out = [header("riscv_pipeline signoff", "max", "tt_025C_1v80")]
    # critical divider path, depth 12, arrival 13.33 -> slack +6.52
    g = chain("u_div/_cp", 12, 0.45, 0.55, "xnor2_1", "A", "Y")
    out.append(setup_path("u_div/quotient_reg[31]", "dfrtp_1", g,
                          "u_alu/result_reg[31]", "dfxtp_1", 0.93, P, SU, UN))
    # a relaxed control path, big positive slack
    g2 = chain("u_ctrl/_s", 3, 0.10, 0.20, "and2_0", "A", "X")
    out.append(setup_path("u_idex/ctrl_reg[1]", "dfrtp_1", g2,
                          "u_exmem/ctrl_reg[1]", "dfxtp_1", 0.12, P, SU, UN))
    return "\n".join(out) + "\n"


def main() -> None:
    write("setup_ss_corner.rpt", gen_setup())
    write("hold_ff_corner.rpt", gen_hold())
    write("clean_signoff.rpt", gen_clean())


if __name__ == "__main__":
    main()
