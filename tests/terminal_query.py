import json
import os
from pathlib import Path
import select
import sys
import termios
import time
import tty


time.sleep(0.3)
previous = termios.tcgetattr(0)
tty.setraw(0)
os.write(1, b"\x1b[2J\x1b[H\x1b[6n")
ready, _, _ = select.select([0], [], [], 5)
if not ready:
    raise TimeoutError("终端没有回复光标位置查询")
response = os.read(0, 128)
termios.tcsetattr(0, termios.TCSANOW, previous)
Path(sys.argv[1]).write_text(json.dumps({"response": response.hex()}))
