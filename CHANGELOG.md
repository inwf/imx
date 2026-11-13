# Changelog

## 0.18.0 — 2026-11-13

### Changed

- Attaching to a session immediately displays a highlighted pane border with its number and session name. Programs use the area inside the border, and resizing updates their terminal dimensions. Pane selection and copying are available immediately.
- Alt+D and Alt+Shift+D split the focused pane. Detaching a standalone session connection returns to the outer terminal while keeping the session running; detaching within a split layout returns that pane to its shell.
- Returning to the outer terminal preserves its existing contents and the session's final screen in history, and restores the terminal's display and input modes.

### Fixed

- Plain text input, including uppercase letters used by Vim, retains its original bytes when the application does not request all keys through the Kitty keyboard protocol.
- Terminal response queue overflow reports an error and closes the affected session or pane while keeping other sessions and panes usable.
- Temporary history and screen snapshot allocations return their pages to the operating system after transmission or disconnection, preventing retained memory after repeated requests.

### Build and release

- Compilation caches use GitHub's automatic eviction for unused or over-quota cache entries.

### Upgrade notes

- Start a new connection with the updated executable to use the bordered interface. Existing sessions keep their programs and history. The backend overflow and snapshot memory fixes apply to sessions started with the updated executable.

## 0.17.0 — 2026-11-11

### Added

- `imx select` shows each session shell's working directory beside its name. Directories are queried when the list opens or changes, and the selected directory refreshes when selection or preview content changes. Automatic directory and preview updates share a limit of 10 frames per second, and idle selectors stop querying.
- Session names and long paths are clipped within separate columns with an ellipsis, preserving complete Unicode characters. Control characters in paths are escaped, and terminals narrower than 20 columns hide the directory column.
- Directory queries run asynchronously. An unavailable or unresponsive session displays `Unavailable`, while keyboard and mouse navigation and cancellation remain available.

### Build and release

- Codeberg-hosted compiler dependencies use fixed-commit HTTPS source archives and retain their pinned Zig package hashes. Build preparation fetches and verifies both `arocc` versions used by the direct and Ghostty compiler dependencies.

### Upgrade notes

- Run `imx select` with the updated executable to use the directory column. Existing sessions keep their programs, history, terminal sizes, and connections.

## 0.16.0 — 2026-11-08

### Added

- `imx reload` reloads the current interface's shortcuts, mouse mode, focused border color, and pane gaps from a session or plain shell pane. It updates existing writable and read-only panes, preserves running programs, history, focus, zoom, and layout proportions, and validates the configuration before applying changes. New connections in that interface inherit the reloaded settings; other interfaces retain their settings.
- Alt+A selects all retained history and screen content in the focused pane after splitting, with mouse mode on or off and while zoomed. Configure it with `keybindings.select_all`; Alt+C copies the selection on request. Read-only connections select source content and retained history, including text outside the visible area, and omit the read-only footer when copying. Fullscreen applications select their active screen.

### Fixed

- Restoring session screens and history preserves soft-wrapped lines, so copying after reconnecting or through a read-only connection joins automatic wraps while retaining explicit line breaks, Unicode text, and indentation.

### Upgrade notes

- Start a new interface with the updated executable to use the new shortcuts and reload command. `imx reload` inside a session also requires an updated backend; existing sessions keep their original backend. A new interface connected to an older backend can reload its settings from a plain shell pane. Older clients or backends report an unsupported-reload error when applicable.
- The outer terminal must send Alt shortcuts to imx; in iTerm2, configure Option to send Esc+. Copying requires the terminal to support and allow OSC 52. Alt+A selects text, and Alt+C requests copying.

## 0.15.0 — 2026-11-07

### Added

- `imx select` supports mouse-wheel history browsing over the preview contents when `panes.mouse = true`. Each wheel event moves three lines; scrolling up pauses live following and returning to the bottom resumes it. Preview connections retain independent positions through new output and window resizing, and selecting another session opens its live preview.
- `imx read` accepts `q` and `Esc` to exit while keeping the session and its programs running. When started from a split pane's ordinary shell, exiting returns to that shell. The footer and command help show the exit keys.
- Alt+C copies selected text from the focused pane to the system clipboard through OSC 52 and keeps the selection highlighted. Configure the shortcut with `keybindings.copy_selection`. Copying preserves Unicode, indentation and explicit line breaks, joins soft-wrapped lines, and omits pane borders and text styling. Mouse selection alone leaves the clipboard unchanged.

### Upgrade notes

- Preview history scrolling requires a session backend started with this version. Existing sessions continue using their original backend; older backends show an unsupported-scrolling message while session selection and attachment remain available.
- Clipboard copying requires the outer terminal to support and allow OSC 52, including over SSH. Restart the interface to use the new copy shortcut or apply a custom binding. Terminal-owned shortcuts such as Command+C require a terminal mapping that sends a key sequence to imx.

## 0.14.0 — 2026-11-05

### Added

- `imx select` supports mouse navigation when `panes.mouse = true`: single-click a session to select and preview it, double-click to enter it, or use the wheel in the list to move the selection. Mouse selection also works inside sessions and split panes.

### Changed

- Temporarily zoomed panes use double-line borders while retaining the `[zoom]` title marker and configured focus color. Restoring the split layout returns the borders to single lines.

### Build and release

- GitHub Actions caches Zig, dependencies, and compilation results separately for x86_64 and ARM64. Main-branch builds refresh caches weekly.
- Version releases reuse successful main-branch build artifacts for the exact same commit. The release workflow waits for an ongoing main-branch check and verifies package versions and SHA256 checksums before publishing.

## 0.13.0 — 2026-11-04

### Added

- `imx read <name>` opens a read-only connection to an existing session. Inside a session, it switches the current connection to read-only viewing. Keyboard input, pasted text, and mouse events stay local; resizing the viewing window leaves the program's terminal size unchanged.
- Read-only connections support local history browsing with PageUp/PageDown, Up/Down, and Home; End follows live output, and Left/Right pan horizontally. Closing or detaching a read-only pane preserves the session and other connections.
- Bash, Zsh, and Fish provide command, help, and session-name completion for `imx read`.

### Fixed

- OSC 8 hyperlinks remain clickable in split panes, zoomed panes, retained history, and session previews. Links stay associated with their text through redraws, scrolling, and terminal resizing.

### Upgrade notes

- Read-only viewing requires a backend and pane interface that support it. Existing sessions continue running after an update; older backends and clients report an unsupported-feature error when a read-only connection is requested.

## 0.12.0 — 2026-11-04

### Added

- `imx rename <new-name>` renames the current session; `imx rename <old-name> <new-name>` renames a specified session. Programs, history, directories, creation times, terminal sizes, and connections are preserved. Pane titles and completion candidates update, and shell prompt integration refreshes the name at the next prompt.
- Alt+Z temporarily zooms the focused pane. Press it again to restore the layout and proportions. Other panes keep running, and resizing the terminal preserves zoom. Configure the shortcut with `keybindings.zoom_pane`.

### Changed

- Pane numbers start at 0. Alt+0 through Alt+9 select the corresponding pane, and numbered shortcuts use `keybindings.focus_0` through `focus_9`.
- The default focused pane border and title color is `#969CD5`. Newly generated configuration files include `panes.focused_border_color`.

### Upgrade notes

- For custom numbered shortcuts, change each old `focus_N` key to `focus_(N-1)` to keep targeting the same pane position. For example, rename `focus_1` to `focus_0` and `focus_10` to `focus_9`. `focus_10` is no longer accepted.
- Session renaming requires a backend started with this version. Existing older backends report `RenameUnsupportedByBackend`; sessions created with the updated program support the command.
- Existing configuration files retain their contents. An omitted `panes.focused_border_color` uses the new default; an explicitly configured color remains in effect.
