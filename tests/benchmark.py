import json
import platform
import time

import pexpect
import psutil

from conftest import BINARY, ROOT, SessionEnvironment


def measure_sessions(count):
    environment = SessionEnvironment()
    frontend_pss = None
    for index in range(count):
        child = environment.spawn(f"session-{index}")
        if frontend_pss is None:
            frontend_pss = psutil.Process(child.pid).memory_full_info().pss
        child.sendcontrol("\\")
        child.expect(pexpect.EOF)
    rows = environment.sessions()
    backend_ids = {psutil.Process(int(row["PID"])).ppid() for row in rows}
    assert len(backend_ids) == 1
    backend = psutil.Process(backend_ids.pop())
    memory = backend.memory_full_info()
    before_cpu = backend.cpu_times()
    before_switches = backend.num_ctx_switches()
    time.sleep(5)
    after_cpu = backend.cpu_times()
    after_switches = backend.num_ctx_switches()
    measurement = {
        "sessions": count,
        "backend_processes": 1,
        "backend_threads": backend.num_threads(),
        "backend_pss_bytes": memory.pss,
        "backend_rss_bytes": memory.rss,
        "frontend_pss_bytes": frontend_pss,
        "shell_pss_bytes": sum(psutil.Process(int(row["PID"])).memory_full_info().pss for row in rows),
        "idle_interval_seconds": 5,
        "idle_cpu_seconds": (after_cpu.user - before_cpu.user) + (after_cpu.system - before_cpu.system),
        "idle_voluntary_switches": after_switches.voluntary - before_switches.voluntary,
        "idle_involuntary_switches": after_switches.involuntary - before_switches.involuntary,
    }
    environment.cleanup()
    return measurement


def measure_output():
    environment = SessionEnvironment()
    child = environment.spawn()
    backend = psutil.Process(psutil.Process(int(environment.sessions()[0]["PID"])).ppid())
    before_cpu = backend.cpu_times()
    started = time.monotonic()
    done_path = environment.path / "output.done"
    child.sendline(f"seq 1 500000; printf DONE > '{done_path}'")
    child.sendcontrol("\\")
    child.expect(pexpect.EOF)
    environment.wait(done_path.exists, timeout=30)
    def completed_history():
        text = environment.run("cat", "dev").stdout
        return text if "500000\n" in text else None

    history = environment.wait(completed_history)
    elapsed = time.monotonic() - started
    after_cpu = backend.cpu_times()
    measurement = {
        "output_lines": 500000,
        "pty_output_bytes": sum(len(str(index)) + 2 for index in range(1, 500001)),
        "elapsed_seconds": elapsed,
        "backend_cpu_seconds": (after_cpu.user - before_cpu.user) + (after_cpu.system - before_cpu.system),
        "backend_pss_bytes_after_output": backend.memory_full_info().pss,
        "retained_text_bytes": len(history.encode()),
        "retained_text_lines": len(history.splitlines()),
    }
    environment.cleanup()
    return measurement


report = {
    "kernel": platform.release(),
    "architecture": platform.machine(),
    "binary_bytes": BINARY.stat().st_size,
    "sessions": [measure_sessions(count) for count in (1, 10, 100)],
    "output": measure_output(),
}
destination = ROOT / "work/benchmark.json"
destination.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
