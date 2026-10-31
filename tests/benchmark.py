import json
import platform
import statistics
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
    assert len(backend_ids) == count
    backends = [psutil.Process(pid) for pid in backend_ids]
    memory = [backend.memory_full_info() for backend in backends]
    before_cpu = [backend.cpu_times() for backend in backends]
    before_switches = [backend.num_ctx_switches() for backend in backends]
    time.sleep(5)
    after_cpu = [backend.cpu_times() for backend in backends]
    after_switches = [backend.num_ctx_switches() for backend in backends]
    measurement = {
        "sessions": count,
        "backend_processes": len(backends),
        "backend_threads": sum(backend.num_threads() for backend in backends),
        "backend_pss_bytes": sum(item.pss for item in memory),
        "backend_rss_bytes": sum(item.rss for item in memory),
        "frontend_pss_bytes": frontend_pss,
        "shell_pss_bytes": sum(psutil.Process(int(row["PID"])).memory_full_info().pss for row in rows),
        "idle_interval_seconds": 5,
        "idle_cpu_seconds": sum((after.user - before.user) + (after.system - before.system)
                                for before, after in zip(before_cpu, after_cpu)),
        "idle_voluntary_switches": sum(after.voluntary - before.voluntary
                                       for before, after in zip(before_switches, after_switches)),
        "idle_involuntary_switches": sum(after.involuntary - before.involuntary
                                         for before, after in zip(before_switches, after_switches)),
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


def measure_isolation():
    environment = SessionEnvironment()
    noisy = environment.spawn("noisy")
    healthy = environment.spawn("healthy")
    rows = {row["NAME"]: row for row in environment.sessions()}
    backend = psutil.Process(psutil.Process(int(rows["noisy"]["PID"])).ppid())
    before_cpu = backend.cpu_times().user
    noisy.sendline("yes CONTINUOUS_OUTPUT")
    noisy.sendcontrol("\\")
    noisy.expect(pexpect.EOF)
    environment.wait(lambda: backend.cpu_times().user - before_cpu >= 0.1)
    latencies = []
    for _ in range(100):
        started = time.monotonic()
        environment.command(healthy, "printf 'RESPONSIVE\\n'")
        latencies.append((time.monotonic() - started) * 1000)
    backend.suspend()
    try:
        started = time.monotonic()
        listing = environment.sessions()
        listing_ms = (time.monotonic() - started) * 1000
        assert next(row for row in listing if row["NAME"] == "noisy")["STATUS"] == "unresponsive"
        started = time.monotonic()
        assert environment.run("__complete", "sessions", "").stdout == "healthy\nnoisy\n"
        completion_ms = (time.monotonic() - started) * 1000
    finally:
        backend.resume()
        environment.cleanup()
    return {
        "healthy_command_samples_under_output": len(latencies),
        "healthy_command_median_ms": statistics.median(latencies),
        "healthy_command_max_ms": max(latencies),
        "listing_with_paused_backend_ms": listing_ms,
        "completion_with_paused_backend_ms": completion_ms,
    }


report = {
    "kernel": platform.release(),
    "architecture": platform.machine(),
    "binary_bytes": BINARY.stat().st_size,
    "sessions": [measure_sessions(count) for count in (1, 10, 100)],
    "output": measure_output(),
    "isolation": measure_isolation(),
}
destination = ROOT / "work/benchmark.json"
destination.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
