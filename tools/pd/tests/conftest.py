"""Make the pd toolkit importable regardless of the interpreter pytest runs
under (these tools are intentionally stdlib-only, so no install step)."""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

SAMPLES = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "samples"))
