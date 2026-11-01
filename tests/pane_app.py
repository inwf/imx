import json
import os
from pathlib import Path
import select
import sys
import tty


destination = Path(sys.argv[1])
mode = sys.argv[2]
tty.setraw(0)
os.write(1, b"\x1b[?1049h\x1b[44m\x1b[2J\x1b[H\x1b[1;33mPANE_APPLICATION\x1b[0m\x1b[?1000h\x1b[?1006h\x1b[?2004h")
if mode == "kitty":
    os.write(1, b"\x1b[>31u")
elif mode == "modify":
    os.write(1, b"\x1b[>4;2m")
size = os.get_terminal_size()
destination.with_suffix(".json").write_text(json.dumps({"pid": os.getpid(), "rows": size.lines, "cols": size.columns}))
with destination.open("wb", buffering=0) as output:
    while select.select([0], [], [], 60)[0]:
        data = os.read(0, 65536)
        if not data:
            break
        output.write(data)
