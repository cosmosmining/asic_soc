#!/usr/bin/env python3
"""Build + run the SoC cocotb testbench with Icarus Verilog.

Assembles the firmware (if needed), elaborates tb_soc with the full SoC RTL, and
runs sim/cocotb/test_soc.py. Exits non-zero if any cocotb test fails, so it
plugs straight into `make` / CI.

    PROG=fw/hello_irq.hex python3 sim/cocotb/run_soc.py
"""
import os
import subprocess
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner, get_results

ROOT = Path(__file__).resolve().parents[2]

RTL = [
    "rtl/cpu_riscv/regfile.sv", "rtl/cpu_riscv/csr.sv", "rtl/cpu_riscv/alu.sv",
    "rtl/cpu_riscv/divider.sv", "rtl/cpu_riscv/mul_seq.sv", "rtl/cpu_riscv/riscv_pipeline.sv",
    "rtl/soc/soc_ram.sv", "rtl/soc/soc_ram_sync.sv", "rtl/soc/mtimer.sv",
    "rtl/soc/uart_tx.sv", "rtl/soc/gpio.sv",
    "rtl/soc/soc_top.sv", "sim/cocotb/tb_soc.sv",
]


def assemble_firmware(src="fw/hello_irq.s", out="fw/hello_irq.hex"):
    src_p, out_p = ROOT / src, ROOT / out
    if (not out_p.exists()) or out_p.stat().st_mtime < src_p.stat().st_mtime:
        subprocess.run([sys.executable, str(ROOT / "tools/scripts/rvasm.py"),
                        str(src_p), "-o", str(out_p)], check=True)
    return out_p


def run_config(prog, sync):
    """Build + run the SoC test with the async (sync=0) or synchronous (sync=1)
    RAM. The synchronous RAM exercises the CPU's imem/dmem memory-wait."""
    name = "sync" if sync else "async"
    build_dir = ROOT / f"build/cocotb_soc_{name}"
    runner = get_runner("icarus")
    runner.build(
        verilog_sources=[str(ROOT / s) for s in RTL],
        hdl_toplevel="tb_soc",
        includes=[str(ROOT / "rtl/common")],
        build_args=["-g2012"],
        parameters={"SYNC": sync},
        build_dir=str(build_dir),
        always=True,
    )
    results = runner.test(
        hdl_toplevel="tb_soc",
        test_module="test_soc",
        test_dir=str(ROOT / "sim/cocotb"),
        build_dir=str(build_dir),
        plusargs=[f"+PROG={prog}"],
        results_xml=f"results_{name}.xml",
    )
    total, failed = get_results(results)
    print(f"cocotb SoC [{name:>5} RAM]: {total - failed}/{total} tests passed")
    return failed


def main():
    prog = Path(os.environ.get("PROG", str(assemble_firmware()))).resolve()
    failed = 0
    for sync in (0, 1):           # async single-cycle RAM, then synchronous SRAM
        failed += run_config(prog, sync)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
