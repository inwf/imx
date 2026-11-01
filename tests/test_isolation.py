from concurrent.futures import ThreadPoolExecutor
import time

import pexpect
import psutil


def backends(environment):
    return {row["NAME"]: psutil.Process(psutil.Process(int(row["PID"])).ppid())
            for row in environment.sessions()}


def test_distinct_sessions_have_independent_single_thread_backends(sessions):
    def create(index):
        child = sessions.spawn(f"independent-{index}")
        child.send("\x1b\\")
        child.expect(pexpect.EOF)

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(create, range(8)))
    processes = backends(sessions)
    assert len({process.pid for process in processes.values()}) == 8
    assert all(process.num_threads() == 1 for process in processes.values())
    assert all(row["STATUS"] == "running" for row in sessions.sessions())
    assert not (sessions.runtime / "server.sock").exists()


def test_paused_backends_do_not_delay_healthy_sessions(sessions):
    clients = {name: sessions.spawn(name) for name in ["healthy", "paused-a", "paused-b", "paused-c"]}
    processes = backends(sessions)
    paused = [process for name, process in processes.items() if name.startswith("paused-")]
    for process in paused:
        process.suspend()
    try:
        sessions.wait(lambda: all(process.status() == psutil.STATUS_STOPPED for process in paused))
        started = time.monotonic()
        rows = {row["NAME"]: row for row in sessions.sessions()}
        assert time.monotonic() - started < 1.8
        assert rows["healthy"]["STATUS"] == "running"
        assert all(rows[name]["STATUS"] == "unresponsive" for name in clients if name != "healthy")
        started = time.monotonic()
        names = sessions.run("__complete", "sessions", "").stdout.splitlines()
        assert time.monotonic() - started < 0.8
        assert names == sorted(clients)

        blocked = sessions.spawn("paused-a", initialize=False)
        sessions.wait(lambda: psutil.Process(blocked.pid).net_connections(kind="unix"))
        started = time.monotonic()
        fresh = sessions.spawn("fresh")
        assert "FRESH_READY" in sessions.command(fresh, "printf 'FRESH_READY\\n'")
        assert "HEALTHY_READY" in sessions.command(clients["healthy"], "printf 'HEALTHY_READY\\n'")
        assert time.monotonic() - started < 1.5
        blocked.expect(pexpect.EOF)
        assert "BackendTimeout" in blocked.before
        blocked.close()
        assert blocked.exitstatus == 1
        started = time.monotonic()
        result = sessions.run("cat", "paused-b", check=False)
        assert result.returncode == 1 and "BackendTimeout" in result.stderr
        assert time.monotonic() - started < 3
    finally:
        for process in paused:
            process.resume()
    assert "RESUMED" in sessions.command(clients["paused-a"], "printf 'RESUMED\\n'")


def test_backend_crash_preserves_other_session_program_and_history(sessions):
    lost = sessions.spawn("lost")
    healthy = sessions.spawn("healthy")
    sessions.command(healthy, "export ISOLATED_VALUE=retained; printf 'ISOLATED_HISTORY\\n'; sleep 600 & printf '%s' \"$!\" > job.pid")
    job = psutil.Process(int((sessions.path / "job.pid").read_text()))
    processes = backends(sessions)
    processes["lost"].kill()
    sessions.wait(lambda: not processes["lost"].is_running())
    lost.expect(pexpect.EOF)
    assert "retained" in sessions.command(healthy, "printf '%s\\n' \"$ISOLATED_VALUE\"")
    assert job.is_running()
    assert "ISOLATED_HISTORY" in sessions.run("cat", "healthy").stdout
    assert sessions.run("__complete", "sessions", "").stdout == "healthy\n"
    assert [row["NAME"] for row in sessions.sessions()] == ["healthy"]
    healthy.send("\x1b\\")
    healthy.expect(pexpect.EOF)
    attached = sessions.spawn("healthy", initialize=False)
    attached.expect_exact("IMX_PROMPT> ")
    assert "retained" in sessions.command(attached, "printf '%s\\n' \"$ISOLATED_VALUE\"")
    sessions.spawn("lost")
    assert backends(sessions)["lost"].pid != processes["lost"].pid
    assert backends(sessions)["healthy"].pid == processes["healthy"].pid


def test_continuous_output_keeps_other_session_responsive(sessions):
    noisy = sessions.spawn("noisy")
    healthy = sessions.spawn("healthy")
    processes = backends(sessions)
    baseline = processes["noisy"].memory_full_info().pss
    initial_cpu = processes["noisy"].cpu_times().user
    noisy.sendline("yes CONTINUOUS_OUTPUT")
    noisy.send("\x1b\\")
    noisy.expect(pexpect.EOF)
    sessions.wait(lambda: processes["noisy"].cpu_times().user - initial_cpu >= 0.1)
    latencies = []
    for index in range(20):
        started = time.monotonic()
        assert f"RESPONSE_{index}" in sessions.command(healthy, f"printf 'RESPONSE_{index}\\n'")
        latencies.append(time.monotonic() - started)
    assert max(latencies) < 0.8
    assert processes["noisy"].memory_full_info().pss - baseline < 16 * 1024 * 1024
    sessions.run("kill", "noisy")
    assert "AFTER_OUTPUT" in sessions.command(healthy, "printf 'AFTER_OUTPUT\\n'")
