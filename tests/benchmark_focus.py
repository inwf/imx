import argparse
import json
from pathlib import Path
import platform
import statistics

import psutil

from conftest import BINARY, ROOT, SessionEnvironment
from test_panes import PaneTerminal


def measure():
    sessions = SessionEnvironment()
    try:
        terminal = PaneTerminal(sessions)
        terminal.screen.resize(lines=60, columns=240)
        terminal.child.setwinsize(60, 240)
        terminal.split()
        terminal.visible("2: shell")
        for number in (1, 2):
            terminal.focus(number)
            terminal.child.sendline("printf '%080d\\n' {1..80}")
            terminal.visible("0000000080")
        frontend = psutil.Process(terminal.child.pid)
        before = frontend.cpu_times()
        offset = len(terminal.capture.getvalue())
        for iteration in range(200):
            terminal.focus(iteration % 2 + 1)
        after = frontend.cpu_times()
        return {
            "client_cpu_seconds": after.user + after.system - before.user - before.system,
            "terminal_output_bytes": len(terminal.capture.getvalue()[offset:].encode()),
        }
    finally:
        sessions.cleanup()


parser = argparse.ArgumentParser()
parser.add_argument("--report", type=Path, default=ROOT / "work/benchmark-focus.json")
arguments = parser.parse_args()
samples = [measure() for _ in range(3)]
report = {
    "kernel": platform.release(), "architecture": platform.machine(), "binary": str(BINARY),
    "columns": 240, "rows": 60, "panes": 2, "focus_changes": 200,
    "samples": samples,
    "median": {key: statistics.median(sample[key] for sample in samples) for key in samples[0]},
}
output = json.dumps(report, indent=2)
arguments.report.write_text(output + "\n")
print(output)
