# Changelog

Notable changes to Manage User Data. Earlier versions are in the git history and the Godot Asset Library listing.

## [Unreleased]

## [2.11.0] (2026-11-22)

- **Clean on Play**: optionally deletes chosen `user://` items every time you press Play, so stale test data, caches or a save don't leak between runs. A checkbox and a comma-separated pattern field (default `test_runner/`) in the dialog, with a live count of what matches; off by default, stored per project in the editor's project metadata. Implemented with `EditorPlugin._build()`, which always returns true, so it never blocks a run.
- Patterns are relative to `user://`: an exact path, a folder with a trailing `/`, or a `*` / `?` glob in the last segment (`*.tmp`, `saves/*.bak`). No recursive `**`. Invalid patterns (absolute, drive letters, backslashes, `.`/`..`, wildcard folder names) are ignored and reported.
- `UserDataOps.clean_targets()`, `invalid_patterns()` and `clean_on_play()`: results pass `is_safe_target`, are de-duplicated and minimal, never glob into symlinked folders, and are deleted through `delete_paths`. Tested headless in `tests/test_clean_on_play.gd`.

## [2.10.0] (2026-11-22)

- **Preview pane**: selecting a row shows its contents beside the tree, so a save can be inspected without leaving the editor. JSON is pretty-printed (`.jsonl` shows its first 50 rows), invalid JSON shows the raw text with the error and line, binary files show a hex dump of the first 256 bytes, images show a thumbnail, folders show a file count and size. A **Copy** button copies the text. Read-only: it reads at most 64 KB, follows no symbolic links, and never changes the checkboxes.
- `UserDataOps.preview()` and `hex_dump()`, tested headless in `tests/test_preview.gd`. The dialog is wider by default to fit the pane.

## [2.9.0] (2026-11-22)

- **Restore Zip…**: picks a `.zip` (such as one from Zip Selected), shows how many files it will write and how many existing files it will overwrite, then extracts it into `user://` with entry names taken relative to `user://`. Entries that would land outside `user://` or on `user://` itself (`..`, `.`, empty or backslash segments, absolute and drive-letter names: "zip-slip") are skipped, and so is anything that would be written through a symbolic link inside `user://`.
- `UserDataOps.zip_listing()`, `restore_destination()` and `unzip_into_user()`, tested headless in `tests/test_restore_zip.gd` with crafted archives.

## [2.8.0] (2026-11-20)

- **Zip Selected…**: saves exactly what Delete would remove (checked and visible; folders whole only when fully selected) as one `.zip`, with paths relative to `user://`, to attach to a bug report or keep as a snapshot before deleting. Hidden files inside folders are included; symbolic links and anything outside `user://` are skipped, and the archive is never added to itself. Defaults to the desktop with a `<project>_user_data_<timestamp>.zip` name and reveals the file when done.
- `UserDataOps.zip_paths()`, `selected_paths()` and `default_zip_name()`, tested headless in `tests/test_zip.gd`.
- `format_file_size` now reports sizes of 1 GB and up in GB (`"2.00 GB"` instead of `"2048.00 MB"`), e.g. for large shader or asset caches.
- `is_safe_target` also refuses `.` and empty path segments and backslash `..` segments, so neither Delete nor Zip can be pointed at `user://` itself or outside it through an odd path.

## [2.7.0] (2026-11-19)

- New type filters: **Backups & temp** (`.bak`, `.tmp`, including `<save>.v<N>.bak` pre-migration copies), **Test runner data** (`user://test_runner/` and everything in it, empty folders included), and **Logs** (`.log`, `.jsonl`). Only visible items are deleted, so a filter narrows a delete too: "Test runner data → Delete Selected" removes `user://test_runner` and nothing else.
- Type labels and icons for `.bak` ("Backup"), `.tmp` ("Temp File"), `.jsonl` ("JSON Lines") and `.log` ("Log File").
- Filtering, type labels and size formatting moved into the editor-independent `user_data_ops.gd` (`filter_tree`, `matches_filters`, `matches_type`, `get_file_type_label`, `format_file_size`, `FILTER_*` constants); the plugin delegates to it. No behaviour change for the existing filters.
- Tests now call the plugin's real code. `test_format_file_size`, `test_file_type_label` and `test_filter_logic` used to test private copies of the functions, and `test_file_operations` tested Godot's own save/load APIs; they would have passed with the plugin broken. `test_filter_logic` now filters real `Tree`s and checks what a filtered delete plans to remove.
- README: the save-format tutorial ("Working with Save Files", "Handling Edge Cases") is replaced by a section on the files save libraries and test runners leave behind, pointing to `lrd_save` for writing saves. Repo links point at `lrd_user_data`; the CI snippet matches the real workflow. New `AGENTS.md` (and `CLAUDE.md`) for coding agents, and this changelog.

## [2.6.0]

- Deletion honours unchecked and filtered-out items (only checked and visible items are deleted; a partly selected folder is kept), refuses paths outside `user://`, removes symlinks without following them. Tests run headless on Godot 4.7.
