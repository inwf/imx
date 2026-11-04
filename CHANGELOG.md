# Changelog

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
