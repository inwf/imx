import argparse
import json
from pathlib import Path
import platform
import shlex
import statistics
import sys
import time

import psutil

from conftest import BINARY, ROOT, SessionEnvironment
from test_panes import PaneTerminal


def produce(gate):
    print("\x1b[2J\x1b[HRENDER_READY", flush=True)
    while not gate.exists():
        time.sleep(0.002)
    for number in range(2000):
        print(f"\x1b[Hframe {number:06d}", end="", flush=True)
        time.sleep(0.001)
    print("\x1b[HRENDER_COMPLETE", flush=True)


def measure(count):
    sessions = SessionEnvironment()
    try:
        terminal = PaneTerminal(sessions)
        terminal.screen.resize(lines=60, columns=240)
        terminal.child.setwinsize(60, 240)
        terminal.split()
        terminal.visible("1: shell")
        sources = [0, 1, 0, 1, 2, 3]
        for number, source in zip(range(2, count), sources):
            terminal.focus(source)
            terminal.split("down")
            terminal.visible(f"{number}: shell")
        terminal.focus(0)
        gate = sessions.path / "render-gate"
        terminal.child.sendline(shlex.join([sys.executable, str(Path(__file__).resolve()), "--producer", str(gate)]))
        terminal.visible("RENDER_READY")
        frontend = psutil.Process(terminal.child.pid)
        clients = [frontend] + [process for process in frontend.children(recursive=True)
                                if process.exe() == str(BINARY) and process.name() != "imx-server"]
        before = [process.cpu_times() for process in clients]
        offset = len(terminal.capture.getvalue())
        started = time.monotonic()
        gate.touch()
        terminal.visible("RENDER_COMPLETE")
        elapsed = time.monotonic() - started
        after = [process.cpu_times() for process in clients]
        return {
            "elapsed_seconds": elapsed,
            "client_cpu_seconds": sum((end.user - begin.user) + (end.system - begin.system)
                                      for begin, end in zip(before, after)),
            "client_pss_bytes": sum(process.memory_full_info().pss for process in clients),
            "terminal_output_bytes": len(terminal.capture.getvalue()[offset:].encode()),
        }
    finally:
        sessions.cleanup()


parser = argparse.ArgumentParser()
parser.add_argument("--producer", type=Path)
parser.add_argument("--report", type=Path, default=ROOT / "work/benchmark-panes.json")
arguments = parser.parse_args()
if arguments.producer is not None:
    produce(arguments.producer)
else:
    report = {"kernel": platform.release(), "architecture": platform.machine(), "binary": str(BINARY),
              "binary_bytes": BINARY.stat().st_size, "columns": 240, "rows": 60,
              "updates": 2000, "interval_seconds": 0.001, "panes": []}
    for count in (2, 4, 8):
        samples = [measure(count) for _ in range(3)]
        report["panes"].append({"count": count, "samples": samples,
                                "median": {key: statistics.median(sample[key] for sample in samples)
                                           for key in samples[0]}})
    output = json.dumps(report, indent=2)
    if arguments.report is not None:
        arguments.report.write_text(output + "\n")
    print(output)
