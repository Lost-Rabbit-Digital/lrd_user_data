# AGENTS.md: lrd_user_data (Manage User Data)

Guide for coding agents (Claude Code reads it through `CLAUDE.md`). The user-facing docs are [`README.md`](README.md).

## What this repo is

**Manage User Data**, a Godot **editor** plugin, published on the Godot Asset Library (asset 4811). It adds a toolbar
button that opens a dialog listing `user://` as a tree with checkboxes, search, type filters, sizes, Copy Logs, **Zip Selected…**, **Restore Zip…**, a read-only **Preview** pane and
**Delete Selected**. Nothing in it runs in an exported game.

| Path | What it is |
| --- | --- |
| `addons/manage_user_data/plugin.gd` | The `EditorPlugin`: builds the dialog in code, populates the tree, wires buttons, help window, Copy Logs |
| `addons/manage_user_data/user_data_ops.gd` | **All decision logic, editor-free**: deletion planning and removal, zipping and restoring, path safety, filters, labels, sizes. Loaded with `preload`, no `class_name` |
| `addons/manage_user_data/plugin.cfg` | Name, version, `min_godot_version="4.3"` |
| `tests/test_*.gd` | `extends SceneTree` suites that print `N passed, M failed` and exit non-zero on failure |
| `tests/run_all.sh` | Parse-checks every addon script, then runs each suite |
| `main.tscn`, `main.gd`, root `project.godot` | A throwaway host project for developing the plugin |

## Commands

```bash
godot --headless --editor --quit; godot --headless --import    # once, after cloning (CI does the same)
GODOT_BIN=/path/to/godot-4.7 bash tests/run_all.sh             # all checks; must end "0 failure(s)"
godot --headless --path . --script res://tests/test_filter_logic.gd   # one suite
```

## Rules

1. **Deletion safety is the product.** Only rows that are checked **and** visible are deleted; a folder goes whole only when it and every descendant are checked and visible; nothing outside `user://`; `user://` itself never; symlinks removed, never followed. These live in `user_data_ops.gd` and are pinned by `tests/test_deletion_safety.gd` and `tests/test_filter_logic.gd`. **Clean on Play** deletes automatically on every Play, so it must stay pattern-exact (no recursive globs, no wildcard folder names, nothing guessed) and every target must pass `is_safe_target` and go through `delete_paths`; it is pinned by `tests/test_clean_on_play.gd`. **Zip Selected** uses the same selection (`selected_paths`) and must stay read-only on the sources (`tests/test_zip.gd`). **Preview** is read-only: `UserDataOps.preview` only reads (at most `max_bytes`), refuses non-`user://` paths and symlinks (`tests/test_preview.gd`). **Restore Zip** must write nothing outside `user://`: every entry goes through `restore_destination` (`tests/test_restore_zip.gd` feeds it hostile archives). Any change near them needs a test that builds real files or a real `Tree`.
2. **Logic goes in `user_data_ops.gd`, UI in `plugin.gd`.** If you can test it headless, it belongs in ops. Tests call ops directly. Never copy a function into a test to test it.
3. **Godot 4.3 compatibility for the addon.** The plugin ships to projects on 4.3+, so no typed dictionaries or other 4.4+ syntax in `addons/`. Tests and the dev project target 4.7.
4. **No `class_name` in the addon.** It installs into other people's projects; a global class name could collide. Use `preload`.
5. **Inspect, don't prescribe.** How a game writes saves is lrd_save's concern, and test-run redirection is lrd_run_log's (see below). This plugin may *recognise* their files (`.bak`, `.tmp`, `.v<N>.bak`, `test_runner/`, `.jsonl`) but must not depend on either.
6. Filters: add a `FILTER_*` constant and a `FILTER_LABELS` entry in ops (the menu is built from it), a `match` arm in `matches_type`, and tests in `test_filter_logic.gd`. If the filter should match folders by itself, add it to `folder_can_match` in `filter_tree`.

## Releasing

Bump `version` in `addons/manage_user_data/plugin.cfg` **and** `config/version` in `project.godot`, update the version
in the README header, and add a `CHANGELOG.md` entry. The Asset Library listing is updated by hand by the maintainers.

## Where things live (the LRD add-on family)

Each concern has exactly one home. Before adding something, check it doesn't belong next door.

| Repo | Owns | Add-on folder / class prefix |
| --- | --- | --- |
| [lrd_platform](https://github.com/Lost-Rabbit-Digital/lrd_platform) | The runtime layer a player touches: audio bus names, the cross-promo panel, category logging (`LRDLog`), player settings (`LRDSettings`), crash-reporting policy (`LRDSentry`), Steam init and achievements (`LRDSteam`), input device detection and glyphs (`LRDInputDevice`) | `addons/lrd_platform/`, `LRDAudioBuses`, `LRDLog`, `LRDSettings`, `LRDSentry`, `LRDSteam`, `LRDInputDevice`, `LRDStudioPortfolio`, `LRDCrossPromoPanel` |
| [lrd_save](https://github.com/Lost-Rabbit-Digital/lrd_save) | Save data on disk: atomic JSON writes with a backup, save slots, versioned saves with migrations | `addons/lrd_save/`, `LRDSaveFile`, `LRDSaveSlots`, `LRDSaveSchema` |
| [lrd_run_log](https://github.com/Lost-Rabbit-Digital/lrd_run_log) | Playtest telemetry: one JSONL row per run, report helpers, build stamp, driver (human/bot) detection, and the test-run `user://` redirect | `addons/lrd_run_log/`, `LRDRunLog`, `LRDRunReport`, `LRDBuildStamp`, `LRDRunArgs`, `LRDUserPaths` |
| [lrd_user_data](https://github.com/Lost-Rabbit-Digital/lrd_user_data) | An **editor-only** plugin to browse and selectively delete `user://`. Ships on the Godot Asset Library, so it must work in any project | `addons/manage_user_data/` |

Elsewhere: `lrd_shared` (analytics and consent, developer console, MCP bridge, capture tool, localization and store scripts), `lrd_steam_net` (co-op networking), `lrd-ci` (the shared CI workflow).

Dependencies only point one way and are all optional, found at runtime by name, so each add-on works alone:

- `lrd_save` → `LRDUserPaths` (lrd_run_log), by class name: tests and bots save under `user://test_runner/`.
- `lrd_run_log` → the `LRDAnalytics` autoload (lrd_shared), by node name, only when `analytics_event` is set.
- `lrd_user_data` knows the file conventions of the other two (`.bak`, `.tmp`, `.v<N>.bak`, `test_runner/`, `.jsonl`) but calls neither.
- `lrd_platform` depends on none of them.

Never vendor one family add-on inside another's `addons/`: the LRD Addon Manager would index it from two repos.
