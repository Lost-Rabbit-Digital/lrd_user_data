# Manage User Data

<img src="plugin_icon.png" width="64" height="64" alt="Manage User Data icon">

A Godot 4 editor plugin for browsing and selectively deleting your project's `user://` directory without leaving the editor.

**Requires Godot 4.3+** · **MIT License** · **Version 2.11.0** ([changelog](CHANGELOG.md))

[![Godot Asset Library](https://img.shields.io/badge/Godot%20Asset%20Library-Manage%20User%20Data-478CBF?style=for-the-badge&logo=godotengine&logoColor=white)](https://godotengine.org/asset-library/asset/4811)
[![Discord](https://img.shields.io/badge/Discord-Join%20Server-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/Y7caBf7gBj)

<img src="screenshot_1.png" width="512" alt="Plugin screenshot">

---

## Table of Contents

- [Install](#install)
- [Usage](#usage)
- [Features](#features)
- [API Reference](#api-reference)
- [Save backups, test data and logs](#save-backups-test-data-and-logs)
- [Clean on Play](#clean-on-play)
- [Running Tests](#running-tests)
- [What's in user://](#whats-in-user)
- [Contributing](#contributing)
- [Credits](#credits)

---

## Install

### Asset Library (recommended)

1. Open your project → **AssetLib** → search **"Manage User Data"**
2. **Download** → **Install**
3. **Project → Project Settings → Plugins** → enable **Manage User Data**

### Manual

1. Copy `addons/manage_user_data/` into your project:
   ```
   your_project/
   └── addons/
       └── manage_user_data/
           ├── plugin.cfg
           └── plugin.gd
   ```
2. **Project → Project Settings → Plugins** → enable **Manage User Data**

---

## Usage

Click the **User Data** button in the editor toolbar to open the dialog.

<img src="screenshot_4.png" width="512" alt="Toolbar button">

| Action | How |
|---|---|
| Delete everything | Leave all items checked → **Delete Selected** |
| Delete specific files | Uncheck **Select All** → tick what you want → **Delete Selected** |
| Find a file | Type in the **Search** bar |
| Filter by type | Use the **All Types** dropdown: Files, Folders, `.json`, `.cache`, Backups & temp (`.bak`, `.tmp`), Test runner data (`user://test_runner/`), Logs (`.log`, `.jsonl`) |
| Clear filters | Click **×** next to the dropdown |
| Refresh the list | Click the **⟳** icon |
| Open in file manager | Click **Open Folder** |
| Copy engine logs | Click **Copy Logs** (de-duplicates automatically) |
| Inspect a file | Click a row: the **Preview** pane shows it (JSON pretty-printed, hex dump for binary, thumbnail for images). **Copy** copies the text; nothing is changed |
| Zip for a bug report | Click **Zip Selected…**: the checked, visible items as one `.zip`, paths relative to `user://` |
| Clean on every Play | Tick **Clean on Play** under the tree and list patterns (default `test_runner/`). Off by default; see [Clean on Play](#clean-on-play) |
| Load someone's zip | Click **Restore Zip…**: shows how many files it writes and overwrites, then extracts into `user://` |

<img src="screenshot_2.png" width="512" alt="File tree screenshot">

The status bar shows a live count and total size of exactly what will be deleted before you confirm. Deletion is permanent and cannot be undone.

**What gets deleted:** only items that are checked **and** visible. Anything hidden by the search box or type filter is never deleted, and unchecking a file inside a checked folder protects that file: the folder is then kept and only its other checked items are removed. A folder is removed wholesale only when it and everything under it is checked and visible. Nothing outside `user://` is touched, and symbolic links are removed as links without following them.

<img src="screenshot_5.png" width="512" height="256" alt="Status bar">

---

## Features

- **File Tree** — Full recursive view of `user://` with per-item checkboxes
- **Real-time Search** — Instantly filters the tree as you type; parent folders auto-expand
- **Type Filters** — Narrow to Files Only, Folders Only, `.json`, `.cache`, save backups and temp files, test-runner data, or logs. A filter narrows what **Delete** removes too
- **Bulk Selection** — Select All / Deselect All with indeterminate state support
- **File Sizes** — Inline sizes on every entry; status bar totals the selection
- **Open in OS** — Launch `user://` in your native file manager
- **Copy Logs** — One-click copy of de-duplicated `godot.log` to clipboard
- **Preview** — Click a file to read it beside the tree: pretty-printed JSON (first rows of `.jsonl`), text, hex dump for binary, image thumbnail, folder summary. Read-only, 64 KB cap
- **Restore Zip** — Extract such a zip back into `user://` after a confirmation listing what it overwrites; entries that would land outside `user://` (zip-slip) or go through a symlink are skipped
- **Zip Selected** — Save exactly what's selected (same rules as Delete) as a `.zip`, to attach to a bug report or keep before deleting
- **Clean on Play** — Optionally delete chosen `user://` items (paths, folders, `*` globs) automatically every time you press Play, so stale test data and caches don't leak between runs. Off by default
- **Refresh** — Rescan `user://` without reopening the plugin
- **Version Check** — Warns on Godot versions below 4.3
- **Error Resilience** — Gracefully handles unreadable files, locked directories, and permission errors

---

## API Reference

The plugin extends `EditorPlugin` and provides utility methods for managing `user://` contents. While primarily a UI tool, the following public methods are available.

### Core Methods

#### `show_confirmation_dialog() → void`
Opens the main plugin dialog. Scans `user://` and builds the file tree.

```gdscript
# Typically called via toolbar button, but can be invoked programmatically:
var plugin = EditorInterface.get_editor_plugin("Manage User Data")
plugin.show_confirmation_dialog()
```

#### `populate_tree(parent_item: TreeItem, path: String) → void`
Recursively scans a directory and populates the `Tree` control with items. Each item stores its full path in metadata slot 1.

- Handles unreadable directories with `push_warning()`
- Displays file sizes inline (or "unreadable" for locked files)
- Assigns icons based on file extension

#### `delete_selected_items() → Dictionary`
Deletes what the current selection covers (see *What gets deleted* above). Planning and removal live in `user_data_ops.gd` (`plan_deletion()`, `delete_paths()`), which is editor-independent and tested headless.

**Returns:** `{"deleted": int, "failed": Array[String]}`

```gdscript
var result = delete_selected_items()
print("Deleted %d items" % result.deleted)
if not result.failed.is_empty():
    push_warning("Failed to delete: %s" % str(result.failed))
```

#### `delete_directory_contents(path: String) → void`
Recursively deletes all files and subdirectories inside `path` without removing the directory itself. Logs warnings for items that fail to delete.

#### `calculate_folder_size(path: String) → int`
Returns the total byte size of all files under `path`, recursively. Skips unreadable files.

### Filter & Search Methods

#### `apply_filters() → void`
Applies the current search text and type filters to the tree. Matching parents auto-expand.

#### `filter_tree_item(item: TreeItem, search_term: String, filter_types: Array[int]) → bool`
Recursively filters tree items (delegates to `UserDataOps.filter_tree`). Returns `true` if the item or any descendant matches.

**Filter type IDs** (constants on `UserDataOps`; several active filters combine with OR):
| ID | Constant | Shows |
|----|----------|-------|
| 1 | `FILTER_FILES` | Files |
| 2 | `FILTER_FOLDERS` | Folders |
| 3 | `FILTER_JSON` | `.json` files |
| 4 | `FILTER_CACHE` | `.cache` files |
| 5 | `FILTER_BACKUPS` | `.bak` and `.tmp` files (including `<save>.v<N>.bak`) |
| 6 | `FILTER_TEST_DATA` | `user://test_runner` and everything in it, folders included |
| 7 | `FILTER_LOGS` | `.log` and `.jsonl` files |

A folder is shown as a container when something inside it matches; it matches by itself only under Folders or Test runner data.

### Utility Methods

#### `format_file_size(bytes: int) → String`
Formats byte counts for display (`UserDataOps.format_file_size`).

```gdscript
format_file_size(0)        # "0 B"
format_file_size(1024)     # "1.00 KB"
format_file_size(1572864)  # "1.50 MB"
```

#### `get_file_type_label(file_name: String) → String`
Returns a human-readable type label based on file extension (`UserDataOps.get_file_type_label`).

```gdscript
get_file_type_label("save.json")        # "JSON Data"
get_file_type_label("save.json.bak")    # "Backup"
get_file_type_label("runs.jsonl")       # "JSON Lines"
get_file_type_label("Makefile")         # "File"
```

#### `get_file_icon(file_name: String) → Texture2D`
Returns an appropriate editor theme icon for the file type.

**Supported extensions:** `.json`, `.jsonl`, `.log`, `.bak`, `.tmp`, `.cfg`, `.ini`, `.toml`, `.png`, `.jpg`, `.jpeg`, `.webp`, `.bmp`, `.svg`, `.wav`, `.ogg`, `.mp3`, `.tscn`, `.tres`, `.gd`, `.cache`, `.save`, `.dat`

### `UserDataOps` (editor-independent)

`addons/manage_user_data/user_data_ops.gd` holds every rule that decides what is shown and what is deleted. It uses no editor API, so it runs headless and the tests call it directly:

| Function | Does |
|---|---|
| `plan_deletion(root)` / `selected_paths(root)` | The minimal list of paths a delete would remove (and Zip archives): checked **and** visible only |
| `preview(path, max_bytes)` | Read-only look at a file for the Preview pane: `{kind, text, truncated, bytes, error}`; json / text / binary (hex dump) / image / folder / missing / refused; reads at most `max_bytes` |
| `zip_listing(zip)` / `unzip_into_user(zip)` / `restore_destination(entry)` | Preview and extract a zip into `user://`; hostile entry names and symlinked folders refused |
| `zip_paths(paths, zip_path)` | Archives them, names relative to `user://`, hidden files in, symlinks and outside paths skipped; `{error, files, skipped}` |
| `clean_targets(patterns)` / `invalid_patterns(patterns)` / `clean_on_play(patterns)` | Clean on Play: the existing, safe, minimal `user://` paths the patterns select; the patterns it ignores; and `delete_paths` over the matches |
| `delete_paths(paths)` | Removes them deepest first; refuses anything outside `user://` |
| `describe(paths)` | `{files, folders, bytes}` for the status bar |
| `filter_tree(root, search, filters)` | Sets row visibility for the search text and type filters |
| `matches_filters(name, path, is_folder, search, filters)` / `matches_type(...)` | One row's match |
| `is_safe_target(path)`, `is_test_data(path)`, `is_backup_or_temp(name)` | Path predicates |
| `calculate_folder_size(path)`, `delete_directory_contents(path)` | Folder helpers; never follow symlinks |
| `format_file_size(bytes)`, `get_file_type_label(name)` | Display helpers |

### UI Helper Methods

#### `propagate_check_state(item: TreeItem, checked: bool) → void`
Recursively applies a checked/unchecked state to all children of the given tree item.

#### `update_warning_label() → void`
Updates the status bar with the current selection count, size, and warning text.

---

## Save backups, test data and logs

This plugin inspects and clears what a game writes; it does not tell a game how to write it. For crash-safe saves (atomic writes, a `.bak` to fall back on, save slots, versioned migrations) use [**lrd_save**](https://github.com/Lost-Rabbit-Digital/lrd_save); for playtest logs and keeping tests out of the real profile use [**lrd_run_log**](https://github.com/Lost-Rabbit-Digital/lrd_run_log). The plugin knows their file conventions, and they are common in other games too:

| You see | Written by | Filter | Safe to delete? |
|---|---|---|---|
| `progress.json.bak` | lrd_save: the previous good save, loaded when the save is corrupt | Backups & temp | Only while the save itself is intact |
| `progress.json.tmp` | A save write that never finished | Backups & temp | Yes |
| `progress.json.v2.bak` | lrd_save: the save as it was before a version migration | Backups & temp | Yes, once the migration is trusted |
| `test_runner/…` | Tests and bots, redirected away from the real profile (lrd_run_log's `LRDUserPaths`) | Test runner data | Yes, always |
| `*.jsonl` | lrd_run_log playtest rows, one JSON object per line | Logs | Only after you've collected them |
| `logs/godot.log` | Godot's engine log | Logs | Yes |

Common clean-ups:

- **Reset test pollution:** Test runner data → leave all checked → **Delete Selected**. Removes `user://test_runner` whole and nothing else.
- **Test a corrupt-save fallback:** search the save's name, uncheck the `.bak`, delete the save, run the game: it should load the backup.
- **Send a repro to a teammate:** filter or search to the save, **Zip Selected…**, attach the zip. They load it with **Restore Zip…**.
- **Start a fresh playthrough but keep settings:** uncheck `settings.cfg` (or filter to `.json`) before deleting.

## Clean on Play

Tick **Clean on Play** (under the tree) and the plugin deletes the matching `user://` items every time you press **Play** in the editor, before the game starts. It is **off by default**, the patterns default to `test_runner/`, and both are remembered per project (editor project metadata, not `project.godot`). It never blocks the run, and prints `Manage User Data: cleaned N item(s) before play` to the Output. A label next to the field shows how many items match right now.

Patterns are comma-separated and relative to `user://`:

| Pattern | Matches |
|---|---|
| `test_runner` | That file or folder (a folder goes whole) |
| `saves/slot_0/progress.json` | One exact file |
| `test_runner/` | The folder `test_runner` only (a trailing `/` means folders only) |
| `*.tmp` | Names ending in `.tmp` directly in `user://` |
| `saves/*.bak`, `logs/*.log` | The same, inside that one folder |

Rules: `*` and `?` work in the **last segment only** and match names in that one folder (`String.match`); there is no recursive `**`, so `*.tmp` does not reach into subfolders. Patterns that are blank, absolute (`/etc`), drive-letter (`C:/x`), contain `\`, `.`, `..` or empty segments, or put a wildcard in a folder name are ignored and listed in the label. Nothing outside `user://` is ever touched, `user://` itself never, and a symlinked folder is not looked into (a link itself is removed as a link). Because this runs unattended on every Play, keep patterns narrow: the dialog's count is the preview.

## Running Tests

Every suite calls the plugin's real code in `user_data_ops.gd`; nothing is re-implemented in the tests.

### Prerequisites

- Godot 4.7 in your `PATH` (or set `GODOT_BIN` environment variable). The addon itself still runs on 4.3+.

### Run All Tests

```bash
bash tests/run_all.sh
```

### Run Individual Tests

```bash
godot --headless --path . --script tests/test_format_file_size.gd
godot --headless --path . --script tests/test_file_type_label.gd
godot --headless --path . --script tests/test_filter_logic.gd
godot --headless --path . --script tests/test_file_operations.gd
godot --headless --path . --script tests/test_deletion_safety.gd
godot --headless --path . --script tests/test_zip.gd
godot --headless --path . --script tests/test_clean_on_play.gd
godot --headless --path . --script tests/test_preview.gd
godot --headless --path . --script tests/test_restore_zip.gd
```

`run_all.sh` also parse-checks every addon script and fails a suite that exits without printing its summary. CI (`.github/workflows/tests.yml`) runs it on Godot 4.7.

### Test Coverage

| Test File | What It Covers |
|---|---|
| `test_format_file_size.gd` | Byte/KB/MB/GB formatting, boundary values |
| `test_file_type_label.gd` | Extension → label mapping (incl. `.bak`, `.tmp`, `.jsonl`, `.log`), case insensitivity, unknown extensions |
| `test_filter_logic.gd` | Search and every type filter, real `Tree` filtering (containers, ancestors, `test_runner/`), and what a filtered delete plans to remove |
| `test_deletion_safety.gd` | The plugin's real deletion code against real files: unchecked children survive, filtered-out items survive, whole-folder deletes, refusal outside `user://`, dotfiles, status-bar stats |
| `test_preview.gd` | Preview: JSON pretty-print, invalid JSON error line, cut at `max_bytes` (not inside a character), hex dump format, refused outside `user://`, folder summary, missing file, first `.jsonl` rows |
| `test_restore_zip.gd` | Restore Zip: round trip with Zip Selected, overwrite preview, hostile names (`..`, absolute, drive letter, backslash), nothing written outside `user://`, symlinked folders refused |
| `test_zip.gd` | Zip Selected: relative entry names, folders with hidden files, refused paths, empty selection, a zip never inside itself, same selection as Delete |
| `test_clean_on_play.gd` | Clean on Play: exact paths, trailing-slash folders, globs in a subfolder, no recursion, invalid patterns ignored and reported, nothing outside `user://`, symlinked folders not entered, minimal and de-duplicated results, exactly the matches deleted |
| `test_file_operations.gd` | Folder sizes (nested, hidden, missing), emptying a folder, deleting paths, status-bar stats |

### CI Integration

`.github/workflows/tests.yml` imports the project on Godot 4.7 and runs `tests/run_all.sh`. To run the same checks in your own fork's CI:

```yaml
- uses: chickensoft-games/setup-godot@v1
  with:
    version: 4.7.0
    use-dotnet: false
- run: godot --headless --editor --quit || true
- run: GODOT_BIN=godot bash tests/run_all.sh
```

---

## What's in user://

Godot writes to `user://` when your game uses paths like `"user://save.json"`. Common files to clean during development:

| Extension | Source |
|---|---|
| `.cfg` / `.json` | Save data, settings |
| `.log` / `.jsonl` | Engine/game logs, playtest run logs |
| `.bak` / `.tmp` | Save backups, unfinished writes |
| `.cache` | Engine/game caches |
| `.save` / `.dat` | Binary save files |

**On-disk location:**

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\Godot\app_userdata\<project>\` |
| macOS | `~/Library/Application Support/Godot/app_userdata/<project>/` |
| Linux | `~/.local/share/godot/app_userdata/<project>/` |

---

## Contributing

Contributions are welcome! Here's how to get started:

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Run the tests: `GODOT_BIN=/path/to/godot-4.7 bash tests/run_all.sh`
4. Submit a pull request

Coding agents: read [`AGENTS.md`](AGENTS.md) first (layout, commands, deletion-safety rules).

### Development Setup

```bash
git clone https://github.com/Lost-Rabbit-Digital/lrd_user_data.git
cd lrd_user_data
# Open in Godot 4.3+ and enable the plugin
```

### Reporting Issues

- [GitHub Issues](https://github.com/Lost-Rabbit-Digital/lrd_user_data/issues)
- [Discord Community](https://discord.gg/Y7caBf7gBj)

---

## Credits

<img src="screenshot_3.png" width="512" alt="Credits">

Made by [Lost Rabbit Digital](https://lostrabbit.digital/) · [Discord](https://discord.gg/Y7caBf7gBj)

MIT — see [LICENSE](LICENSE)
