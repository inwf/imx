import argparse
import json
from pathlib import Path
import platform
import shlex
import statistics
import sys

import psutil

from conftest import BINARY, ROOT, SessionEnvironment
from preview_client import PreviewClient


def measure():
    sessions = SessionEnvironment()
    try:
        session = sessions.spawn("colors", rows=60, cols=240)
        sessions.command(session, shlex.join([sys.executable, str(ROOT / "tests/select_output.py"), "--colors"]))
        backend = psutil.Process(psutil.Process(int(sessions.sessions()[0]["PID"])).ppid())
        with PreviewClient(sessions, "colors", rows=50, cols=238) as preview:
            initial = len(preview.frame())
            before = backend.cpu_times()
            total = 0
            for number in range(30):
                sessions.command(session, f"printf '\\033[HUPDATE_{number:04d}\\033[K'")
                total += len(preview.frame())
            after = backend.cpu_times()
        return {
            "initial_frame_bytes": initial,
            "update_bytes": total,
            "backend_cpu_seconds": after.user + after.system - before.user - before.system,
        }
    finally:
        sessions.cleanup()


parser = argparse.ArgumentParser()
parser.add_argument("--report", type=Path, default=ROOT / "work/benchmark-select.json")
arguments = parser.parse_args()
samples = [measure() for _ in range(3)]
report = {
    "kernel": platform.release(), "architecture": platform.machine(), "binary": str(BINARY),
    "columns": 238, "rows": 50, "updates": 30, "samples": samples,
    "median": {key: statistics.median(sample[key] for sample in samples) for key in samples[0]},
}
output = json.dumps(report, indent=2)
arguments.report.write_text(output + "\n")
print(output)
