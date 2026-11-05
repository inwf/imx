# Changelog

## 0.14.0 — 2026-11-05

### Added

- `imx select` supports mouse navigation when `panes.mouse = true`: single-click a session to select and preview it, double-click to enter it, or use the wheel in the list to move the selection. Mouse selection also works inside sessions and split panes.

### Changed

- Temporarily zoomed panes use double-line borders while retaining the `[zoom]` title marker and configured focus color. Restoring the split layout returns the borders to single lines.

### Build and release

- GitHub Actions caches Zig, dependencies, and compilation results separately for x86_64 and ARM64. Main-branch builds refresh caches weekly and retain the latest two per architecture; Actions summaries show cache counts and storage usage.
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
