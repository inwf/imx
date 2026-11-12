import os
from pathlib import Path
import select
import sys
import termios
import time
import tty


directory = Path(sys.argv[1])
reading = sys.argv[2] == "read"
queries = 131072
previous = termios.tcgetattr(0)
tty.setraw(0)
(directory / "pid").write_text(str(os.getpid()))
(directory / "ready").touch()
deadline = time.monotonic() + 20
while not (directory / "start").exists():
    if time.monotonic() >= deadline:
        raise TimeoutError("终端查询测试未启动")
    time.sleep(0.01)


def write_all(data):
    while data:
        data = data[os.write(1, data):]


if reading:
    write_all(b"\x1b[2J\x1b[H")
    # 每批收到完整应答后继续查询，限制同时等待的应答数量。
    for offset in range(0, queries, 2048):
        count = min(2048, queries - offset)
        write_all(b"\x1b[6n" * count)
        expected = b"\x1b[1;1R" * count
        received = bytearray()
        while len(received) < len(expected):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([0], [], [], remaining)[0]:
                raise TimeoutError("终端查询应答未完整收到")
            data = os.read(0, 65536)
            if not data:
                raise EOFError("终端连接已关闭")
            received.extend(data)
        assert received == expected
    termios.tcsetattr(0, termios.TCSANOW, previous)
    (directory / "done").write_text(str(queries))
else:
    write_all(b"\x1b[2J\x1b[H" + b"\x1b[6n" * queries)
    raise AssertionError("未读取应答的程序完成了超出队列容量的查询")
