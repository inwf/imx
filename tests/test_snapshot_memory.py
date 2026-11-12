import socket
import struct
import time

import pexpect
import psutil
import pytest


def snapshot_cycles(sessions, operation, cycles, sample_every=25):
    child = sessions.spawn()
    lines = 10000 if operation == "disconnect" else 2000
    text = "HISTORY-%05d" + ("░" * 50 if operation == "disconnect" else "")
    if operation == "disconnect":
        child.sendline(f"touch history-waiting; while [[ ! -f start-history ]]; do sleep 0.01; done; printf '{text}\\n' {{1..{lines}}}")
        sessions.wait((sessions.path / "history-waiting").exists)
    else:
        sessions.command(child, f"printf '{text}\\n' {{1..{lines}}}")
    backend = psutil.Process(psutil.Process(int(sessions.sessions()[0]["PID"])).ppid())
    child.send("\x1b\\")
    child.expect(pexpect.EOF)
    child.close()
    if operation == "disconnect":
        (sessions.path / "start-history").touch()

        def history_complete():
            output = sessions.run("cat", "dev").stdout
            return f"HISTORY-{lines:05d}" in output and output.endswith("IMX_PROMPT>\n")

        sessions.wait(history_complete)
    expected = sessions.run("cat", "dev").stdout
    assert f"HISTORY-{lines:05d}" in expected
    if operation == "disconnect":
        assert len(expected.encode()) > 256 * 1024
    samples = []
    for cycle in range(cycles + 1):
        if cycle % sample_every == 0 or cycle == cycles:
            assert sessions.run("cat", "dev").stdout == expected
            sessions.wait(lambda: backend.num_fds() == 10)
            samples.append({"cycle": cycle, "rss": backend.memory_info().rss,
                            "fds": backend.num_fds(), "cpu": sum(backend.cpu_times()[:2]),
                            "time": time.monotonic(), "history_bytes": len(expected.encode())})
        if cycle == cycles:
            break
        if operation == "cat":
            assert sessions.run("cat", "dev").stdout == expected
        elif operation == "attach":
            child = sessions.spawn(initialize=False)
            child.expect_exact("IMX_PROMPT> ")
            child.send("\x1b\\")
            child.expect(pexpect.EOF)
            child.close()
        else:
            assert operation == "disconnect"
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                connection.connect(str(sessions.runtime / "session-dev.sock"))
                connection.sendall(struct.pack("<IHH", 3, 3, 1) + b"dev")
                assert connection.recv(8, socket.MSG_WAITALL) == struct.pack("<IHH", 0, 9, 1)
    return samples


@pytest.mark.parametrize("operation", ["cat", "attach", "disconnect"])
def test_snapshot_memory_stabilizes(sessions, operation):
    samples = snapshot_cycles(sessions, operation, 250)
    warmed = [sample["rss"] for sample in samples if sample["cycle"] >= 50]
    # 固定历史内容，允许预热后的页分配波动，避免随请求次数持续保留内存。
    assert max(warmed) - min(warmed) <= 1024 * 1024, samples
