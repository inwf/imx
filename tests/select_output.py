import argparse
import itertools
import os
import sys
import time


parser = argparse.ArgumentParser()
parser.add_argument("--colors", action="store_true")
args = parser.parse_args()
size = os.get_terminal_size()
if args.colors:
    for row in range(size.lines - 1):
        cells = [f"\x1b[38;2;{column % 256};{row % 256};{(row + column) % 256}mX" for column in range(size.columns - 1)]
        sys.stdout.write("".join(cells) + "\r\n")
    sys.stdout.write("\x1b[0m\x1b[HCOLOR_GRID\n")
    sys.stdout.flush()
    sys.exit(0)

for number in itertools.count():
    row = chr(ord("A") + number % 26) * (size.columns - 1)
    content = f"\x1b[HFRAME_{number:08d}\r\n" + (row + "\r\n") * (size.lines - 2) + "\x1b[H"
    os.write(1, content.encode())
    time.sleep(0.005)
