extends SceneTree
## Zip Selected: UserDataOps.zip_paths against real files, read back with
## ZIPReader. The selection rules are the ones Delete uses.
## Run via: godot --headless --path . --script tests/test_zip.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")
const TEST_DIR := "user://test_zip"
const OUT_DIR := "user://test_zip_out"

var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	print("=== test_zip ===")
	for test: Callable in [
		test_files_and_folders_are_archived_relative_to_user,
		test_a_folder_brings_its_hidden_files,
		test_paths_outside_user_are_refused,
		test_nothing_to_zip_writes_nothing,
		test_the_zip_is_never_added_to_itself,
		test_the_zip_is_never_added_to_itself_on_a_case_insensitive_filesystem,
		test_a_failed_zip_leaves_no_archive,
		test_selected_paths_follow_the_delete_rules,
		test_default_name_is_safe,
	]:
		_reset()
		test.call()
	_rm(TEST_DIR)
	_rm(OUT_DIR)
	print("--- %d passed, %d failed ---" % [_pass_count, _fail_count])
	quit(0 if _fail_count == 0 else 1)


func _reset() -> void:
	_rm(TEST_DIR)
	_rm(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_DIR)


func _rm(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		Ops.delete_directory_contents(path)
		DirAccess.remove_absolute(path)


func _write(rel: String, text: String) -> String:
	var path := TEST_DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return path


func _entries(zip_path: String) -> Dictionary:
	var reader := ZIPReader.new()
	var out := {}
	if reader.open(zip_path) != OK:
		return out
	for name: String in reader.get_files():
		out[name] = reader.read_file(name).get_string_from_utf8()
	reader.close()
	return out


# -- Tests ---------------------------------------------------------------------


func test_files_and_folders_are_archived_relative_to_user() -> void:
	var save := _write("saves/slot_0/progress.json", "{\"coins\": 7}")
	_write("saves/slot_0/progress.json.bak", "{\"coins\": 6}")
	var settings := _write("settings.cfg", "[audio]")
	var zip := OUT_DIR.path_join("bug.zip")
	var paths: Array[String] = [TEST_DIR.path_join("saves"), settings]
	var result := Ops.zip_paths(paths, zip)
	_check(result.error == OK, "zip: OK")
	_check(result.files == 3, "zip: three files (got %d)" % result.files)
	var entries := _entries(zip)
	_check(entries.get("test_zip/saves/slot_0/progress.json") == "{\"coins\": 7}", "zip: save content and relative name")
	_check(entries.has("test_zip/saves/slot_0/progress.json.bak"), "zip: backup inside the folder included")
	_check(entries.has("test_zip/settings.cfg"), "zip: loose file included")
	_check(FileAccess.file_exists(save), "zip: sources are left in place")


func test_a_folder_brings_its_hidden_files() -> void:
	_write("cloud/.steam_meta", "x")
	var zip := OUT_DIR.path_join("hidden.zip")
	var paths: Array[String] = [TEST_DIR.path_join("cloud")]
	Ops.zip_paths(paths, zip)
	_check(_entries(zip).has("test_zip/cloud/.steam_meta"), "zip: dotfiles included")


func test_paths_outside_user_are_refused() -> void:
	var inside := _write("ok.txt", "ok")
	var zip := OUT_DIR.path_join("refuse.zip")
	var paths: Array[String] = ["res://project.godot", "user://", inside]
	var result := Ops.zip_paths(paths, zip)
	_check(result.files == 1, "refuse: only the user:// file added")
	_check(result.skipped.has("res://project.godot"), "refuse: res:// skipped")
	_check(result.skipped.has("user://"), "refuse: user:// root skipped")


func test_nothing_to_zip_writes_nothing() -> void:
	var zip := OUT_DIR.path_join("empty.zip")
	var paths: Array[String] = [TEST_DIR.path_join("ghost.txt")]
	var result := Ops.zip_paths(paths, zip)
	_check(result.error == ERR_DOES_NOT_EXIST, "empty: ERR_DOES_NOT_EXIST")
	_check(not FileAccess.file_exists(zip), "empty: no zip written")


func test_the_zip_is_never_added_to_itself() -> void:
	_write("a.txt", "a")
	var zip := TEST_DIR.path_join("snapshot.zip")
	_write("snapshot.zip", "stale")  # a previous snapshot at the same path
	var paths: Array[String] = [TEST_DIR]
	var result := Ops.zip_paths(paths, zip)
	_check(result.error == OK and result.files == 1, "self: only a.txt archived")
	_check(not _entries(zip).has("test_zip/snapshot.zip"), "self: zip not inside itself")


func test_the_zip_is_never_added_to_itself_on_a_case_insensitive_filesystem() -> void:
	_write("a.txt", "a")
	_write("snapshot.zip", "stale")
	var zip := TEST_DIR.path_join("Snapshot.zip")
	var paths: Array[String] = [TEST_DIR]
	Ops.case_insensitive_paths = 1
	var result := Ops.zip_paths(paths, zip)
	Ops.case_insensitive_paths = -1
	_check(result.error == OK and result.files == 1, "case: only a.txt archived (got %d)" % result.files)
	_check(result.skipped.has(TEST_DIR.path_join("snapshot.zip")), "case: the differently cased zip is skipped")
	_check(not _entries(zip).has("test_zip/snapshot.zip"), "case: no partial copy inside the zip")
	# Forced off, the two names are different files and both are archived.
	_rm(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_write("a.txt", "a")
	_write("snapshot.zip", "stale")
	Ops.case_insensitive_paths = 0
	result = Ops.zip_paths(paths, TEST_DIR.path_join("Snapshot.zip"))
	Ops.case_insensitive_paths = -1
	_check(result.files == 2, "case off: distinct names are both archived (got %d)" % result.files)


func test_a_failed_zip_leaves_no_archive() -> void:
	_write("a.txt", "a")
	_write("b.txt", "b")
	var zip := OUT_DIR.path_join("fail.zip")
	var calls := [0]
	Ops.zip_fault = func(_file: String) -> int:
		calls[0] += 1
		return ERR_FILE_CANT_WRITE if calls[0] == 2 else OK
	var paths: Array[String] = [TEST_DIR]
	var result := Ops.zip_paths(paths, zip)
	Ops.zip_fault = Callable()
	_check(result.error == ERR_FILE_CANT_WRITE, "fail: the error is returned")
	_check(not FileAccess.file_exists(zip), "fail: no partial archive is left")
	_check(FileAccess.file_exists(TEST_DIR.path_join("a.txt")) and FileAccess.file_exists(TEST_DIR.path_join("b.txt")), "fail: sources untouched")
	# A later zip without the fault works.
	result = Ops.zip_paths(paths, zip)
	_check(result.error == OK and FileAccess.file_exists(zip), "fail: the next attempt succeeds")


func test_selected_paths_follow_the_delete_rules() -> void:
	var tree := Tree.new()
	tree.set_columns(3)
	var root := tree.create_item()
	root.set_text(1, "Directory")
	root.set_metadata(Ops.COL_PATH, "user://")
	var folder := _row(tree, root, "user://saves", "Folder", true)
	_row(tree, folder, "user://saves/a.json", "File", true)
	_row(tree, folder, "user://saves/b.json", "File", false)
	var hidden := _row(tree, root, "user://hidden.log", "File", true)
	hidden.visible = false
	var picked := Ops.selected_paths(root)
	_check(picked == Ops.plan_deletion(root), "selection: same set as Delete")
	var expected: Array[String] = ["user://saves/a.json"]
	_check(picked == expected, "selection: partial folder gives its checked file only")
	tree.free()


func test_default_name_is_safe() -> void:
	var name := Ops.default_zip_name("My Game: Deluxe/Edition")
	_check(name.begins_with("My_Game_") and name.ends_with(".zip"), "name: readable (%s)" % name)
	_check(not name.contains(":") and not name.contains("/"), "name: no path characters")
	_check(Ops.default_zip_name("").begins_with("project_user_data_"), "name: fallback")


func _row(tree: Tree, parent: TreeItem, path: String, type: String, checked: bool) -> TreeItem:
	var item := tree.create_item(parent)
	item.set_text(0, path.get_file())
	item.set_text(1, type)
	item.set_metadata(Ops.COL_PATH, path)
	item.set_cell_mode(Ops.COL_CHECK, TreeItem.CELL_MODE_CHECK)
	item.set_checked(Ops.COL_CHECK, checked)
	return item


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)
