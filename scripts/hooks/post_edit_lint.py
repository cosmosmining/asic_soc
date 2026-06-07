#!/usr/bin/env python3
"""PostToolUse hook: lint RTL right after it is edited.

Implements the cheap inner tier of the flow's tiered checking -- after any
Edit/Write to an RTL file, run the (sub-second, license-free) Verilator lint and,
only if it fails, feed the errors straight back to the agent as context so the
break is seen and fixed immediately. Silent on success; never blocks.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    fp = (data.get("tool_input") or {}).get("file_path", "")
    if not re.search(r"rtl/.*\.svh?$", fp):
        return 0  # only RTL edits matter to this hook

    try:
        res = subprocess.run(
            ["make", "lint"], cwd=str(ROOT),
            capture_output=True, text=True, timeout=120,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return 0  # toolchain not present / too slow -- don't get in the way

    if res.returncode != 0:
        tail = (res.stdout + res.stderr).strip().splitlines()[-25:]
        msg = ("Verilator lint FAILED after editing %s. Fix before continuing "
               "(0 warnings is the gate):\n%s" % (fp, "\n".join(tail)))
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": msg,
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
