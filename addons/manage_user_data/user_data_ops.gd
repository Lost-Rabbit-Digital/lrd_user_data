@tool
extends RefCounted
## Selection-to-deletion planning and the actual file removal for the
## Manage User Data dialog. Kept free of editor APIs so it can be tested
## headless against real files (see tests/test_deletion_safety.gd).
##
## Safety rules:
## - Only items that are both checked AND visible (not hidden by a filter)
##   are ever deleted.
## - A folder is removed wholesale only when it and every descendant are
##   checked and visible. Otherwise only its selected children are removed and
##   the folder itself (with any unselected or filtered-out files) is kept.
## - Nothing outside user:// is touched, user:// itself is never removed, and
##   symbolic links are removed as links, never followed.

const COL_PATH := 1
const COL_CHECK := 2
const ROOT_PATH := "user://"

## Type filter IDs, as used by the dialog's "All Types" menu. Several active
## filters combine with OR.
const FILTER_FILES := 1
const FILTER_FOLDERS := 2
const FILTER_JSON := 3
const FILTER_CACHE := 4
## Backup and temp files left by crash-safe save code (lrd_save writes
## `<save>.bak`, `<save>.tmp` and `<save>.v<N>.bak`; many games use `.bak`).
const FILTER_BACKUPS := 5
## Everything under [constant TEST_ROOT], where tests and bots write instead of
## the real profile (lrd_run_log's LRDUserPaths), folders included.
const FILTER_TEST_DATA := 6
## Log files: Godot's `.log` and JSON Lines run logs (`.jsonl`, lrd_run_log).
const FILTER_LOGS := 7

## Menu label for each filter ID, in menu order.
const FILTER_LABELS := {
	FILTER_FILES: "Files Only",
	FILTER_FOLDERS: "Folders Only",
	FILTER_JSON: ".json",
	FILTER_CACHE: ".cache",
	FILTER_BACKUPS: "Backups & temp (.bak, .tmp)",
	FILTER_TEST_DATA: "Test runner data (test_runner/)",
	FILTER_LOGS: "Logs (.log, .jsonl)",
}

## Where test runners and bots write instead of the player's profile.
const TEST_ROOT := "user://test_runner"


## Returns the minimal list of paths to delete for the current tree state.
## No returned path is inside another returned path.
static func plan_deletion(root: TreeItem) -> Array[String]:
	var out: Array[String] = []
	_plan(root, out)
	return out


static func _plan(item: TreeItem, out: Array[String]) -> void:
	if item == null:
		return
	var path := _path_of(item)
	if path != "" and path != ROOT_PATH and is_fully_selected(item):
		out.append(path)
		return
	var child := item.get_first_child()
	while child != null:
		_plan(child, out)
		child = child.get_next()


## What the current selection covers (checked and visible, folders whole only
## when fully selected). The same set Delete removes and Zip archives.
static func selected_paths(root: TreeItem) -> Array[String]:
	return plan_deletion(root)


## True when [param item] and all of its descendants are checked and visible.
static func is_fully_selected(item: TreeItem) -> bool:
	if not item.visible or not item.is_checked(COL_CHECK):
		return false
	var child := item.get_first_child()
	while child != null:
		if not is_fully_selected(child):
			return false
		child = child.get_next()
	return true


static func _path_of(item: TreeItem) -> String:
	var meta: Variant = item.get_metadata(COL_PATH)
	return meta if meta is String else ""


## Rejects anything that is not strictly inside user://.
static func is_safe_target(path: String) -> bool:
	if not path.begins_with(ROOT_PATH) or path == ROOT_PATH or path.trim_suffix("/") == "user:":
		return false
	# Treat "\\" as a separator too (Windows resolves it), and reject empty,
	# "." and ".." segments: "user://.", "user:///" and "user://a\..\.."
	# would otherwise resolve to user:// itself or escape it.
	for part: String in path.trim_prefix(ROOT_PATH).replace("\\", "/").split("/"):
		if part == "" or part == "." or part == "..":
			return false
	return true


## {files, folders, bytes} for a plan, counting the files inside whole folders.
static func describe(paths: Array[String]) -> Dictionary:
	var files := 0
	var folders := 0
	var bytes := 0
	for path: String in paths:
		if _is_link(path):
			files += 1
		elif DirAccess.dir_exists_absolute(path):
			folders += 1
			bytes += calculate_folder_size(path)
		elif FileAccess.file_exists(path):
			files += 1
			bytes += _file_size(path)
	return {"files": files, "folders": folders, "bytes": bytes}


## Deletes [param paths] (as produced by plan_deletion). Returns
## {"deleted": int, "failed": Array[String]}.
static func delete_paths(paths: Array[String]) -> Dictionary:
	var ordered: Array[String] = paths.duplicate()
	ordered.sort_custom(func(a: String, b: String) -> bool: return a.count("/") > b.count("/"))

	var deleted := 0
	var failed: Array[String] = []
	for path: String in ordered:
		if not is_safe_target(path):
			push_error("Manage User Data: Refusing to delete '%s' (outside user://)" % path)
			failed.append(path)
			continue
		var is_link := _is_link(path)
		var is_dir := not is_link and DirAccess.dir_exists_absolute(path)
		if not is_link and not is_dir and not FileAccess.file_exists(path):
			push_warning("Manage User Data: Path no longer exists, skipping: %s" % path)
			continue
		if is_dir and delete_directory_contents(path) > 0:
			failed.append(path)
			continue
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			push_error("Manage User Data: Failed to delete '%s' (error %d)" % [path, err])
			failed.append(path)
		else:
			deleted += 1
	return {"deleted": deleted, "failed": failed}


# -- Clean on Play -------------------------------------------------------------


## Parses one Clean on Play pattern. Returns {"valid": bool, "dir": String,
## "name": String, "folder_only": bool, "glob": bool}: [code]dir[/code] is the
## literal parent folder relative to user:// ("" for the top level) and
## [code]name[/code] the last segment (a glob when it has [code]*[/code] or
## [code]?[/code]). Blank, absolute, drive-letter, backslash, "." / ".." / empty
## segments and a wildcard outside the last segment are invalid.
static func _parse_clean_pattern(pattern: String) -> Dictionary:
	var bad := {"valid": false, "dir": "", "name": "", "folder_only": false, "glob": false}
	var text := pattern.strip_edges()
	if text == "" or text.begins_with("/") or text.contains("\\") or text.contains(":"):
		return bad
	var folder_only := text.ends_with("/")
	if folder_only:
		text = text.trim_suffix("/")
	var parts := text.split("/")
	for i: int in parts.size():
		var part: String = parts[i]
		if part == "" or part == "." or part == "..":
			return bad
		if i < parts.size() - 1 and (part.contains("*") or part.contains("?")):
			return bad
	var name: String = parts[parts.size() - 1]
	# A top-level name made only of wildcards ("*", "*?") would empty user://
	# on every Play: refuse it rather than trust a stray keystroke.
	if parts.size() == 1 and name.replace("*", "").replace("?", "") == "":
		return bad
	var dir_parts := PackedStringArray()
	for i: int in parts.size() - 1:
		dir_parts.append(parts[i])
	return {
		"valid": true,
		"dir": "/".join(dir_parts),
		"name": name,
		"folder_only": folder_only,
		"glob": name.contains("*") or name.contains("?"),
	}


## The patterns [method clean_targets] ignores (blank entries are skipped
## without being reported).
static func invalid_patterns(patterns: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for pattern: String in patterns:
		if pattern.strip_edges() != "" and not _parse_clean_pattern(pattern).valid:
			out.append(pattern)
	return out


## True when [param rel_dir] (relative to user://) exists and no folder on the
## way to it is a symbolic link.
static func _clean_dir_is_plain(rel_dir: String) -> bool:
	var current := ROOT_PATH
	if rel_dir != "":
		for part: String in rel_dir.split("/"):
			var next := current.path_join(part)
			if _is_link(next) or not DirAccess.dir_exists_absolute(next):
				return false
			current = next
	return true


## Existing user:// paths that [param patterns] select for Clean on Play,
## de-duplicated and minimal (nothing inside another returned path), each
## passing [method is_safe_target]. Patterns are relative to user://:
## an exact path ("test_runner", "saves/slot_0/progress.json"), a folder with a
## trailing "/" ("test_runner/": folders only), or a glob in the last segment
## only ("*.tmp", "saves/*.bak"; [code]*[/code] and [code]?[/code], matched with
## [method String.match] against the names in that one folder). There is no
## recursive "**". Invalid patterns ([method invalid_patterns]) match nothing;
## folders are never globbed into through a symbolic link.
static func clean_targets(patterns: PackedStringArray) -> Array[String]:
	var found := {}
	for pattern: String in patterns:
		var parsed := _parse_clean_pattern(pattern)
		if not parsed.valid or not _clean_dir_is_plain(parsed.dir):
			continue
		var base := ROOT_PATH if parsed.dir == "" else ROOT_PATH.path_join(parsed.dir)
		var names: Array[String] = []
		if parsed.glob:
			var dir := DirAccess.open(base)
			if dir == null:
				continue
			dir.include_hidden = true
			dir.list_dir_begin()
			var entry := dir.get_next()
			while entry != "":
				if entry != "." and entry != ".." and entry.match(parsed.name):
					names.append(entry)
				entry = dir.get_next()
			dir.list_dir_end()
		else:
			names.append(parsed.name)
		for entry_name: String in names:
			var full := base.path_join(entry_name)
			var exists := _is_link(full) or FileAccess.file_exists(full) or DirAccess.dir_exists_absolute(full)
			if not exists or not is_safe_target(full):
				continue
			if parsed.folder_only and not DirAccess.dir_exists_absolute(full):
				continue
			found[full] = true
	var sorted: Array[String] = []
	for path: String in found:
		sorted.append(path)
	sorted.sort()
	var minimal: Array[String] = []
	for path: String in sorted:
		if minimal.is_empty() or not path.begins_with(minimal[minimal.size() - 1] + "/"):
			minimal.append(path)
	return minimal


## Deletes what [method clean_targets] selects. Same result shape as
## [method delete_paths]: {"deleted": int, "failed": Array[String]}.
static func clean_on_play(patterns: PackedStringArray) -> Dictionary:
	return delete_paths(clean_targets(patterns))


## Recursively deletes everything inside [param path] (not the folder itself),
## removing symlinks without following them. Returns the number of failures.
static func delete_directory_contents(path: String) -> int:
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("Manage User Data: Cannot open directory for deletion: '%s'" % path)
		return 1
	var failures := 0
	dir.include_hidden = true
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path := path.path_join(file_name)
			if dir.current_is_dir() and not dir.is_link(file_name):
				failures += delete_directory_contents(full_path)
			var err := DirAccess.remove_absolute(full_path)
			if err != OK:
				failures += 1
				push_warning("Manage User Data: Could not remove '%s' (error %d)" % [full_path, err])
		file_name = dir.get_next()
	dir.list_dir_end()
	return failures


## Total byte size of all files under [param path], not following symlinks.
static func calculate_folder_size(path: String) -> int:
	var total := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	dir.include_hidden = true
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != ".." and not dir.is_link(file_name):
			var full_path := path.path_join(file_name)
			if dir.current_is_dir():
				total += calculate_folder_size(full_path)
			else:
				total += _file_size(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return total


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size := file.get_length()
	file.close()
	return size


static func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


# -- Display helpers -----------------------------------------------------------


## Human-readable size: "512 B", "1.50 KB", "2.00 MB", "1.25 GB".
static func format_file_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	elif bytes < 1024 * 1024:
		return "%.2f KB" % (bytes / 1024.0)
	elif bytes < 1024 * 1024 * 1024:
		return "%.2f MB" % (bytes / (1024.0 * 1024.0))
	else:
		return "%.2f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))


## Human-readable type label from a file's extension ("JSON Data", "Backup").
static func get_file_type_label(file_name: String) -> String:
	var ext := file_name.get_extension().to_lower()
	match ext:
		"json":
			return "JSON Data"
		"jsonl":
			return "JSON Lines"
		"log":
			return "Log File"
		"bak":
			return "Backup"
		"tmp":
			return "Temp File"
		"cfg":
			return "Config File"
		"ini":
			return "INI Config"
		"toml":
			return "TOML Config"
		"png":
			return "PNG Image"
		"jpg", "jpeg":
			return "JPEG Image"
		"webp":
			return "WebP Image"
		"bmp":
			return "BMP Image"
		"svg":
			return "SVG Image"
		"wav":
			return "WAV Audio"
		"ogg":
			return "OGG Audio"
		"mp3":
			return "MP3 Audio"
		"tscn":
			return "Packed Scene"
		"tres":
			return "Resource"
		"gd":
			return "GDScript"
		"cache":
			return "Cache File"
		"save":
			return "Save File"
		"dat":
			return "Data File"
		_:
			return ext.to_upper() + " File" if not ext.is_empty() else "File"


# -- Filtering -----------------------------------------------------------------


## True when [param path] is the test-runner folder or anything inside it.
static func is_test_data(path: String) -> bool:
	return path == TEST_ROOT or path.begins_with(TEST_ROOT + "/")


## True for a backup or temp file a save system leaves beside a save.
static func is_backup_or_temp(file_name: String) -> bool:
	var lower := file_name.to_lower()
	return lower.ends_with(".bak") or lower.ends_with(".tmp")


## Whether an item matches [param filter_types] (any of them; none = all).
static func matches_type(file_name: String, path: String, is_folder: bool, filter_types: Array[int]) -> bool:
	if filter_types.is_empty():
		return true
	var lower := file_name.to_lower()
	for ft: int in filter_types:
		match ft:
			FILTER_FILES:
				if not is_folder:
					return true
			FILTER_FOLDERS:
				if is_folder:
					return true
			FILTER_JSON:
				if not is_folder and lower.ends_with(".json"):
					return true
			FILTER_CACHE:
				if not is_folder and lower.ends_with(".cache"):
					return true
			FILTER_BACKUPS:
				if not is_folder and is_backup_or_temp(lower):
					return true
			FILTER_TEST_DATA:
				if is_test_data(path):
					return true
			FILTER_LOGS:
				if not is_folder and (lower.ends_with(".log") or lower.ends_with(".jsonl")):
					return true
	return false


## Whether an item matches both the search text (case-insensitive substring of
## its name) and the type filters.
static func matches_filters(
	file_name: String, path: String, is_folder: bool, search_term: String, filter_types: Array[int]
) -> bool:
	var matches_search := search_term.is_empty() or file_name.to_lower().contains(search_term.to_lower())
	return matches_search and matches_type(file_name, path, is_folder, filter_types)


## True for a tree row that is a folder (not a file or a link).
static func is_folder_item(item: TreeItem) -> bool:
	var type_text := item.get_text(1)
	return type_text.begins_with("Folder") or type_text == "Directory"


## Sets [code]visible[/code] on [param item] and its descendants for the search
## text and type filters. Returns true if the item or any descendant is shown.
##
## A folder is shown when it matches itself (only possible with a filter that
## matches folders: Folders Only or Test runner data) or when anything inside
## it is shown. Hidden rows are never deleted ([method plan_deletion]), so a
## filter narrows a delete as well as the view.
static func filter_tree(item: TreeItem, search_term: String, filter_types: Array[int]) -> bool:
	if item == null:
		return false
	var is_folder := is_folder_item(item)
	var any_child_visible := false
	var child := item.get_first_child()
	while child != null:
		if filter_tree(child, search_term, filter_types):
			any_child_visible = true
		child = child.get_next()
	var folder_can_match := (
		filter_types.is_empty() or filter_types.has(FILTER_FOLDERS) or filter_types.has(FILTER_TEST_DATA)
	)
	var self_matches := matches_filters(item.get_text(0), _path_of(item), is_folder, search_term, filter_types)
	var shown: bool
	if is_folder and not folder_can_match:
		shown = any_child_visible
	else:
		shown = self_matches or any_child_visible
	item.visible = shown
	return shown


# -- Sorting, state capture and change detection --------------------------------

## Sort keys for [method sort_children] (the dialog's Sort menu).
const SORT_NAME := 0
const SORT_SIZE := 1
const SORT_MODIFIED := 2

## Menu label for each sort key, in menu order.
const SORT_LABELS := {
	SORT_NAME: "Name",
	SORT_SIZE: "Size (largest first)",
	SORT_MODIFIED: "Modified (newest first)",
}

## [method listing_signature] stops after this many entries, so a huge profile
## costs a bounded amount of work every second. A change made only past the cap
## goes unnoticed until the next manual Refresh.
const SIGNATURE_ENTRY_CAP := 20000


## Reorders the children of [param parent], recursively, by [param key]
## ([constant SORT_NAME], [constant SORT_SIZE] or [constant SORT_MODIFIED]).
## Folders always come first; then by name (A to Z), size (largest first) or
## modified time (newest first). Ties fall back to the name, case-insensitive.
##
## Only the order changes: check state, visibility, collapsed state and
## metadata are never touched, so a sort can never change what Delete removes.
##
## A folder's size is [method calculate_folder_size]. A folder's modified time
## is the newest modified time of any file inside it (not following symlinks),
## or the folder's own time when it holds no files. Links count as size 0 and
## modified time 0 (their target is never read).
##
## [param cache] maps path to the computed value so repeated sorts do not hit
## the disk again. It is filled by this call. Use one cache per key, and
## discard it when the listing is rebuilt.
static func sort_children(parent: TreeItem, key: int, cache: Dictionary = {}) -> void:
	if parent == null:
		return
	var entries: Array = []
	var child := parent.get_first_child()
	while child != null:
		var path := _path_of(child)
		var value := 0
		if key != SORT_NAME:
			value = _sort_value(child, path, key, cache)
		entries.append({"item": child, "folder": is_folder_item(child), "name": child.get_text(0), "value": value})
		child = child.get_next()
	if entries.size() < 2:
		for entry: Dictionary in entries:
			sort_children(entry.item, key, cache)
		return
	entries.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if a.folder != b.folder:
				return a.folder
			if key != SORT_NAME and a.value != b.value:
				return a.value > b.value
			var an: String = a.name.to_lower()
			var bn: String = b.name.to_lower()
			if an != bn:
				return an < bn
			return a.name < b.name
	)
	# Place from the back: each item goes right before the one placed after it.
	var anchor: TreeItem = null
	for i in range(entries.size() - 1, -1, -1):
		var item: TreeItem = entries[i].item
		if anchor != null and item.get_next() != anchor:
			item.move_before(anchor)
		anchor = item
	for entry: Dictionary in entries:
		sort_children(entry.item, key, cache)


static func _sort_value(item: TreeItem, path: String, key: int, cache: Dictionary) -> int:
	if path != "" and cache.has(path):
		return cache[path]
	var value := 0
	if path != "" and item.get_text(1) != "Link" and not _is_link(path):
		if is_folder_item(item):
			value = calculate_folder_size(path) if key == SORT_SIZE else _newest_modified(path)
		elif key == SORT_SIZE:
			value = _file_size(path)
		else:
			value = FileAccess.get_modified_time(path)
	if path != "":
		cache[path] = value
	return value


## Newest modified time of any file under [param path] (links not followed),
## or the folder's own modified time when it holds no files.
static func _newest_modified(path: String) -> int:
	var newest := _newest_file_time(path)
	return newest if newest > 0 else FileAccess.get_modified_time(path)


static func _newest_file_time(path: String) -> int:
	var newest := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	dir.include_hidden = true
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != ".." and not dir.is_link(file_name):
			var full_path := path.path_join(file_name)
			if dir.current_is_dir():
				newest = maxi(newest, _newest_file_time(full_path))
			else:
				newest = maxi(newest, FileAccess.get_modified_time(full_path))
		file_name = dir.get_next()
	dir.list_dir_end()
	return newest


## Records each row's check state and collapsed state, by path, so a rebuilt
## tree can get them back ([method restore_state]). Returns
## [code]{path: {"checked": bool, "collapsed": bool}}[/code]. Rows without a
## path are skipped.
static func capture_state(root: TreeItem) -> Dictionary:
	var out := {}
	_capture(root, out)
	return out


static func _capture(item: TreeItem, out: Dictionary) -> void:
	if item == null:
		return
	var path := _path_of(item)
	if path != "":
		out[path] = {"checked": item.is_checked(COL_CHECK), "collapsed": item.is_collapsed()}
	var child := item.get_first_child()
	while child != null:
		_capture(child, out)
		child = child.get_next()


## Applies a [method capture_state] result to a freshly built tree. A row that
## is not in [param state] (a file that appeared since) takes the check state of
## its nearest folder that is: checked under a checked folder, as on first open,
## but unchecked inside a folder the user unchecked, so it can't be deleted
## without them having chosen it. State for paths that no longer exist is
## ignored. Visibility is not part of the state: re-apply the
## search and type filters afterwards so "only checked and visible rows are
## deleted" keeps holding.
static func restore_state(root: TreeItem, state: Dictionary, inherited_checked: bool = true) -> void:
	if root == null:
		return
	var path := _path_of(root)
	if path != "" and state.has(path):
		var saved: Dictionary = state[path]
		root.set_checked(COL_CHECK, bool(saved.get("checked", true)))
		if root.get_first_child() != null:
			root.set_collapsed(bool(saved.get("collapsed", false)))
	elif path != "" and path != ROOT_PATH:
		# A row that appeared since the capture takes its folder's check state:
		# a new file inside a folder the user unchecked must not become
		# deletable behind their back.
		root.set_checked(COL_CHECK, inherited_checked)
	var child := root.get_first_child()
	while child != null:
		restore_state(child, state, root.is_checked(COL_CHECK))
		child = child.get_next()


## Finds the row whose path is [param path], or null.
static func find_item_by_path(root: TreeItem, path: String) -> TreeItem:
	if root == null:
		return null
	if _path_of(root) == path:
		return root
	var child := root.get_first_child()
	while child != null:
		var found := find_item_by_path(child, path)
		if found != null:
			return found
		child = child.get_next()
	return null


## A number that changes when something under [param root_path] is added,
## removed, resized or modified: a hash over every entry's relative path, plus
## size and modified time for files. Hidden files are included and symlinked
## folders are listed but never entered. Order independent. Stops after
## [constant SIGNATURE_ENTRY_CAP] entries (see there). Read-only.
static func listing_signature(root_path: String = ROOT_PATH) -> int:
	var state := {"sum": 0, "count": 0}
	_sign(root_path, "", state)
	return int(state.sum) ^ (int(state.count) * 1000003)


static func _sign(base: String, rel: String, state: Dictionary) -> void:
	var path := base if rel == "" else base.path_join(rel)
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			if state.count >= SIGNATURE_ENTRY_CAP:
				break
			state.count += 1
			var child_rel := file_name if rel == "" else rel + "/" + file_name
			var full_path := base.path_join(child_rel)
			if dir.is_link(file_name):
				state.sum += hash("L|" + child_rel)
			elif dir.current_is_dir():
				state.sum += hash("D|" + child_rel)
				_sign(base, child_rel, state)
			else:
				state.sum += hash("F|%s|%d|%d" % [child_rel, _file_size(full_path), FileAccess.get_modified_time(full_path)])
		file_name = dir.get_next()
	dir.list_dir_end()


# -- Preview -------------------------------------------------------------------

const PREVIEW_IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "svg"]
const PREVIEW_JSONL_LINES := 50
const PREVIEW_HEX_BYTES := 256


## Read-only look at [param path] for the Preview pane. Reads at most
## [param max_bytes] of a file and never writes anything.
##
## Returns {"kind", "text", "truncated", "bytes", "error"}. [code]kind[/code] is
## "json" (parsed and pretty-printed; .jsonl shows its first lines), "text",
## "binary" (NUL bytes or invalid UTF-8; [code]text[/code] is a hex dump of the
## first 256 bytes), "image" (the UI loads it; [code]text[/code] is empty),
## "folder" (a file count and size summary), "missing", or "refused" (outside
## user://, or a symbolic link). Invalid JSON shows the raw text with
## [code]error[/code] "invalid JSON: <message> at line N". [code]bytes[/code] is
## the size on disk.
static func preview(path: String, max_bytes: int = 65536) -> Dictionary:
	var out := {"kind": "missing", "text": "", "truncated": false, "bytes": 0, "error": ""}
	if not is_safe_target(path):
		out.kind = "refused"
		out.error = "not inside user://"
		return out
	if _is_link(path):
		out.kind = "refused"
		out.error = "symbolic link (not followed)"
		return out
	if DirAccess.dir_exists_absolute(path):
		var counts := _count_files(path)
		var bytes := calculate_folder_size(path)
		out.kind = "folder"
		out.bytes = bytes
		out.text = "%d file(s), %s" % [counts, format_file_size(bytes)]
		return out
	if not FileAccess.file_exists(path):
		return out
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		out.kind = "refused"
		out.error = "cannot open (error %d)" % FileAccess.get_open_error()
		return out
	var length := file.get_length()
	out.bytes = length
	var ext := path.get_extension().to_lower()
	if PREVIEW_IMAGE_EXTENSIONS.has(ext):
		file.close()
		out.kind = "image"
		return out
	var window := maxi(max_bytes, 0)
	var buf := file.get_buffer(mini(length, window))
	file.close()
	out.truncated = length > buf.size()
	if out.truncated:
		# A cut inside a multi-byte character is not invalid UTF-8.
		buf = _trim_partial_utf8(buf)
	if buf.has(0) or not _is_valid_utf8(buf):
		out.kind = "binary"
		out.text = hex_dump(buf, PREVIEW_HEX_BYTES)
		return out
	var text := buf.get_string_from_utf8()
	out.kind = "text"
	out.text = text
	if ext == "json":
		var json := JSON.new()
		if json.parse(text) == OK:
			out.kind = "json"
			out.text = JSON.stringify(json.data, "  ")
		elif not out.truncated:
			out.error = "invalid JSON: %s at line %d" % [json.get_error_message(), json.get_error_line()]
	elif ext == "jsonl":
		_preview_jsonl(text, out)
	return out


## First [constant PREVIEW_JSONL_LINES] rows of a JSON Lines file, each
## pretty-printed. A truncated read drops its last (possibly cut) line.
static func _preview_jsonl(text: String, out: Dictionary) -> void:
	var lines := text.split("\n")
	if out.truncated:
		lines.remove_at(lines.size() - 1)
	var parts: Array[String] = []
	var all_valid := true
	var shown := 0
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line == "":
			continue
		if shown >= PREVIEW_JSONL_LINES:
			out.truncated = true
			break
		shown += 1
		var json := JSON.new()
		if json.parse(line) == OK:
			parts.append(JSON.stringify(json.data, "  "))
		else:
			all_valid = false
			parts.append(line)
			if out.error == "":
				out.error = "invalid JSON: %s at line %d" % [json.get_error_message(), i + 1]
	if shown == 0:
		return
	out.text = "\n\n".join(parts)
	out.kind = "json" if all_valid else "text"


## "00000000  48 65 6c 6c ...  |Hello...|" lines of 16 bytes for the first
## [param limit] bytes of [param buf].
static func hex_dump(buf: PackedByteArray, limit: int = 256) -> String:
	var lines: Array[String] = []
	var count := mini(buf.size(), limit)
	for offset in range(0, count, 16):
		var hex := ""
		var ascii := ""
		for i in 16:
			if offset + i < count:
				var b := buf[offset + i]
				hex += "%02x " % b
				ascii += char(b) if b >= 32 and b < 127 else "."
			else:
				hex += "   "
		lines.append("%08x  %s |%s|" % [offset, hex, ascii])
	return "\n".join(lines)


static func _count_files(path: String) -> int:
	var total := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	dir.include_hidden = true
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != ".." and not dir.is_link(file_name):
			if dir.current_is_dir():
				total += _count_files(path.path_join(file_name))
			else:
				total += 1
		file_name = dir.get_next()
	dir.list_dir_end()
	return total


## Drops a trailing incomplete UTF-8 sequence (at most 3 bytes).
static func _trim_partial_utf8(buf: PackedByteArray) -> PackedByteArray:
	var n := buf.size()
	for back in range(1, mini(4, n + 1)):
		var b := buf[n - back]
		if b & 0xC0 == 0x80:
			continue  # continuation byte, keep looking for its lead byte
		var need := 1
		if b >= 0xF0:
			need = 4
		elif b >= 0xE0:
			need = 3
		elif b >= 0xC0:
			need = 2
		if need > back:
			return buf.slice(0, n - back)
		break
	return buf


static func _is_valid_utf8(buf: PackedByteArray) -> bool:
	var i := 0
	var n := buf.size()
	while i < n:
		var b := buf[i]
		var extra := 0
		if b < 0x80:
			i += 1
			continue
		elif b >= 0xC2 and b <= 0xDF:
			extra = 1
		elif b >= 0xE0 and b <= 0xEF:
			extra = 2
		elif b >= 0xF0 and b <= 0xF4:
			extra = 3
		else:
			return false
		if i + extra > n - 1:
			return false
		for k in range(1, extra + 1):
			if buf[i + k] & 0xC0 != 0x80:
				return false
		i += extra + 1
	return true


# -- Zip -----------------------------------------------------------------------


## Archives [param paths] (as [method selected_paths] returns them) into a zip
## at [param zip_path], for a bug report or a snapshot before deleting. Entries
## are named relative to user:// (`saves/slot_0/progress.json`), folders are
## added with everything inside them, hidden files included, and symbolic links
## are skipped, never followed. Paths outside user:// are refused, and the zip
## itself is never added to itself.
##
## Returns {"error": Error, "files": int, "skipped": Array[String]}. With no
## file to add, nothing is written and error is ERR_DOES_NOT_EXIST.
static func zip_paths(paths: Array[String], zip_path: String) -> Dictionary:
	var entries: Array[String] = []
	var skipped: Array[String] = []
	var own_zip := ProjectSettings.globalize_path(zip_path).simplify_path()
	for path: String in paths:
		if not is_safe_target(path):
			skipped.append(path)
		elif _is_link(path):
			skipped.append(path)
		elif DirAccess.dir_exists_absolute(path):
			_collect_files(path, entries)
		elif FileAccess.file_exists(path):
			entries.append(path)
		else:
			skipped.append(path)
	var files: Array[String] = []
	for entry: String in entries:
		if ProjectSettings.globalize_path(entry).simplify_path() == own_zip:
			skipped.append(entry)
		elif not files.has(entry):
			files.append(entry)
	if files.is_empty():
		return {"error": ERR_DOES_NOT_EXIST, "files": 0, "skipped": skipped}
	var dir := zip_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var zip := ZIPPacker.new()
	var err := zip.open(zip_path)
	if err != OK:
		return {"error": err, "files": 0, "skipped": skipped}
	var added := 0
	for file: String in files:
		var bytes := FileAccess.get_file_as_bytes(file)
		if bytes.is_empty() and FileAccess.get_open_error() != OK:
			skipped.append(file)
			continue
		err = zip.start_file(file.trim_prefix(ROOT_PATH))
		if err == OK:
			err = zip.write_file(bytes)
			zip.close_file()
		if err != OK:
			zip.close()
			return {"error": err, "files": added, "skipped": skipped}
		added += 1
	zip.close()
	return {"error": OK, "files": added, "skipped": skipped}


## A default archive name: `<project>_user_data_<YYYY-MM-DD_HH-MM-SS>.zip`.
static func default_zip_name(project_name: String) -> String:
	var safe := project_name.validate_filename().replace(" ", "_")
	if safe == "":
		safe = "project"
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	return "%s_user_data_%s.zip" % [safe, stamp]


static func _collect_files(path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != ".." and not dir.is_link(file_name):
			var full_path := path.path_join(file_name)
			if dir.current_is_dir():
				_collect_files(full_path, out)
			else:
				out.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()


# -- Restore from zip ----------------------------------------------------------


## What restoring [param zip_path] into user:// would do, without writing:
## {"error": Error, "entries": Array[String] (destination paths),
##  "existing": Array[String] (those that would be overwritten),
##  "unsafe": Array[String] (entry names that would be skipped)}.
static func zip_listing(zip_path: String) -> Dictionary:
	var entries: Array[String] = []
	var existing: Array[String] = []
	var unsafe: Array[String] = []
	var reader := ZIPReader.new()
	var err := reader.open(zip_path)
	if err != OK:
		return {"error": err, "entries": entries, "existing": existing, "unsafe": unsafe}
	for name: String in reader.get_files():
		if name.ends_with("/"):
			continue  # A folder entry: folders are made as files need them.
		var dest := restore_destination(name)
		if dest == "":
			unsafe.append(name)
			continue
		entries.append(dest)
		if FileAccess.file_exists(dest):
			existing.append(dest)
	reader.close()
	return {"error": OK, "entries": entries, "existing": existing, "unsafe": unsafe}


## The user:// path a zip entry restores to, or "" when the entry must be
## refused: anything that would land outside user:// or on user:// itself
## ("..", ".", empty or backslash segments, absolute or drive-letter names),
## or that would write through a symbolic link inside user://.
static func restore_destination(entry_name: String) -> String:
	if entry_name.begins_with("/") or entry_name.contains(":") or entry_name.contains("\\"):
		return ""
	var dest := ROOT_PATH + entry_name
	if not is_safe_target(dest):
		return ""
	var walk := ROOT_PATH
	for part: String in entry_name.split("/"):
		walk = walk.path_join(part) if walk != ROOT_PATH else ROOT_PATH + part
		if _is_link(walk):
			return ""
	return dest


## Extracts [param zip_path] (e.g. from Zip Selected) into user://, entry names
## taken as paths relative to user://. Existing files are overwritten; unsafe
## entries (see [method restore_destination]) are skipped and nothing outside
## user:// is ever written. Returns {"error": Error, "files": int,
## "skipped": Array[String]}.
static func unzip_into_user(zip_path: String) -> Dictionary:
	var skipped: Array[String] = []
	var reader := ZIPReader.new()
	var err := reader.open(zip_path)
	if err != OK:
		return {"error": err, "files": 0, "skipped": skipped}
	var written := 0
	for name: String in reader.get_files():
		if name.ends_with("/"):
			continue
		var dest := restore_destination(name)
		if dest == "":
			skipped.append(name)
			continue
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var file := FileAccess.open(dest, FileAccess.WRITE)
		if file == null:
			skipped.append(name)
			continue
		file.store_buffer(reader.read_file(name))
		file.close()
		written += 1
	reader.close()
	return {"error": OK, "files": written, "skipped": skipped}
