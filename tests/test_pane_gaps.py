import pytest

from test_panes import PaneTerminal
from test_pane_resize import drag, origin


def configure(sessions, horizontal, vertical, mouse=False):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text(f"[panes]\nhorizontal_gap = {horizontal}\nvertical_gap = {vertical}\nmouse = {str(mouse).lower()}\n")


def test_gaps_preserve_nested_layout_focus_and_terminal_sizes(sessions):
    configure(sessions, 4, 2)
    terminal = PaneTerminal(sessions)
    terminal.split()
    terminal.visible("1: shell")
    terminal.split("down")
    terminal.visible("2: shell")
    assert origin(terminal, 1) == (52, 0)
    assert origin(terminal, 2) == (52, 16)
    assert all(not row[48:52].strip() for row in terminal.screen.display)
    assert all(not row[52:].strip() for row in terminal.screen.display[14:16])
    terminal.command("stty size", "nested-size", "12 46\n")
    for direction, number in [("D", 0), ("C", 1), ("B", 2)]:
        terminal.child.send(f"\x1b[1;3{direction}")
        terminal.focused(number)

    terminal.screen.resize(lines=60, columns=200)
    terminal.child.setwinsize(60, 200)
    terminal.wait(lambda: origin(terminal, 2) == (102, 31))
    terminal.command("stty size", "expanded-size", "27 96\n")
    assert all(not row[98:102].strip() for row in terminal.screen.display)
    assert all(not row[102:].strip() for row in terminal.screen.display[29:31])

    terminal.screen.resize(lines=6, columns=15)
    terminal.child.setwinsize(6, 15)
    terminal.wait(lambda: origin(terminal, 2) == (3, 1))
    terminal.command("stty size", "minimum-size", "3 10\n")
    terminal.screen.resize(lines=30, columns=100)
    terminal.child.setwinsize(30, 100)
    terminal.wait(lambda: origin(terminal, 2) == (52, 16))
    terminal.child.send("\x1bw")
    terminal.wait(lambda: origin(terminal, 2) is None)
    terminal.command("stty size", "remaining-size", "28 46\n")
    terminal.child.send("\x1bw")
    terminal.wait(lambda: origin(terminal, 1) is None)
    terminal.command("stty size", "full-size", "28 98\n")


@pytest.mark.parametrize("direction", ["right", "down"])
@pytest.mark.parametrize("position", range(6))
def test_gap_and_borders_drag_without_jumping(sessions, direction, position):
    configure(sessions, 4, 4, mouse=True)
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("1: shell")
    horizontal = direction == "right"
    start = (48 + position, 8) if horizontal else (25, 13 + position)
    end = (start[0] + 10, 8) if horizontal else (25, start[1] + 3)
    terminal.click(*start)
    terminal.command("stty size", "before-drag", "28 46\n" if horizontal else "11 98\n")
    assert origin(terminal, 1) == ((52, 0) if horizontal else (0, 17))
    drag(terminal, start, end)
    terminal.wait(lambda: origin(terminal, 1) == ((62, 0) if horizontal else (0, 20)))
    terminal.focused(1)
    terminal.command("stty size", "after-drag", "28 36\n" if horizontal else "8 98\n")
    if horizontal:
        terminal.click(70, 3)
    else:
        terminal.click(25, 23)
    terminal.focused(1)
    terminal.focus(0)
    terminal.command("stty size", "first-size", "28 56\n" if horizontal else "14 98\n")
    if horizontal:
        assert all(not row[58:62].strip() for row in terminal.screen.display)
    else:
        assert all(not row.strip() for row in terminal.screen.display[16:20])

    terminal.screen.resize(lines=60, columns=200)
    terminal.child.setwinsize(60, 200)
    terminal.wait(lambda: origin(terminal, 1) == ((122, 0) if horizontal else (0, 38)))


@pytest.mark.parametrize("direction, gap", [("right", 77), ("down", 21), ("right", 255), ("down", 255)])
def test_gap_rejects_split_without_enough_space(sessions, direction, gap):
    configure(sessions, gap if direction == "right" else 0, gap if direction == "down" else 0)
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("Not enough space to split this pane.")
    terminal.command("printf ready", "still-responsive", "ready")
    assert origin(terminal, 1) is None
    assert [row["NAME"] for row in sessions.sessions()] == ["dev"]


@pytest.mark.parametrize("direction, gap", [("right", 76), ("down", 20)])
def test_gap_allows_exact_minimum_pane_space(sessions, direction, gap):
    configure(sessions, gap if direction == "right" else 0, gap if direction == "down" else 0)
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.focused(1)
    terminal.command("stty size", "minimum-size", "28 10\n" if direction == "right" else "3 98\n")
    terminal.focus(0)
    terminal.command("stty size", "first-minimum", "28 10\n" if direction == "right" else "3 98\n")


@pytest.mark.parametrize("direction", ["right", "down"])
@pytest.mark.parametrize("gap", [1, 3])
def test_odd_gap_preserves_remaining_terminal_cells(sessions, direction, gap):
    configure(sessions, gap, gap)
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("1: shell")
    available = (100 if direction == "right" else 30) - gap
    first = available // 2
    second = available - first
    assert origin(terminal, 1) == ((first + gap, 0) if direction == "right" else (0, first + gap))
    terminal.command("stty size", "second-size", f"28 {second - 2}\n" if direction == "right" else f"{second - 2} 98\n")
    terminal.focus(0)
    terminal.command("stty size", "first-size", f"28 {first - 2}\n" if direction == "right" else f"{first - 2} 98\n")


@pytest.mark.parametrize("direction", ["right", "down"])
def test_gap_drag_preserves_nested_minimums(sessions, direction):
    configure(sessions, 2, 2, mouse=True)
    terminal = PaneTerminal(sessions)
    terminal.split(direction)
    terminal.visible("1: shell")
    terminal.split(direction)
    terminal.visible("2: shell")
    horizontal = direction == "right"
    start = (51, 8) if horizontal else (25, 16)
    end = (100, 8) if horizontal else (25, 30)
    drag(terminal, start, end)
    terminal.wait(lambda: origin(terminal, 1) == ((74, 0) if horizontal else (0, 18)))
    terminal.command("stty size", "third-minimum", "28 10\n" if horizontal else "3 98\n")
    terminal.focus(1)
    terminal.command("stty size", "second-minimum", "28 10\n" if horizontal else "3 98\n")
    terminal.focus(0)
    terminal.command("stty size", "first-expanded", "28 70\n" if horizontal else "14 98\n")


@pytest.mark.parametrize("key", ["horizontal_gap", "vertical_gap"])
@pytest.mark.parametrize("value", ["-1", "256", "1.5", "true", "'2'", "[]", "{}"])
def test_invalid_gap_reports_configuration_field(sessions, key, value):
    path = sessions.home / ".config/imx/config.toml"
    path.parent.mkdir(parents=True)
    path.write_text(f"[panes]\n{key} = {value}\n")
    try:
        result = sessions.run("list", check=False)
        assert result.returncode != 0
        assert f"panes.{key}: expected an integer from 0 to 255" in result.stderr
    finally:
        path.unlink()
