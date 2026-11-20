extends SceneTree
## The plugin's real file operations (addons/manage_user_data/user_data_ops.gd)
## against real files under user://test_manage_user_data/: folder sizes,
## emptying a folder, deleting paths.
##
## How a game should write and read its saves (atomic writes, backups,
## versioned migrations) is lrd_save's job and is tested there; these suites
## only test what this plugin does to files.
## Run via: godot --headless --path . --script tests/test_file_operations.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")
const TEST_DIR := "user://test_manage_user_data"

var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	print("=== test_file_operations ===")
	for test: Callable in [
		test_calculate_folder_size,
		test_calculate_folder_size_empty,
		test_calculate_folder_size_nested,
		test_calculate_folder_size_counts_hidden_files,
		test_calculate_folder_size_of_a_missing_folder_is_zero,
		test_delete_directory_contents_keeps_the_folder,
		test_delete_directory_contents_of_a_missing_folder_reports_a_failure,
		test_delete_paths_removes_a_single_file,
		test_delete_paths_skips_a_path_that_is_already_gone,
		test_delete_paths_removes_nested_paths_deepest_first,
		test_describe_counts_files_inside_whole_folders,
	]:
		_setup()
		test.call()
	_teardown()
	_print_summary()
	quit(0 if _fail_count == 0 else 1)


# -- Fixtures ------------------------------------------------------------------


func _setup() -> void:
	_teardown()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)


func _teardown() -> void:
	if DirAccess.dir_exists_absolute(TEST_DIR):
		Ops.delete_directory_contents(TEST_DIR)
		DirAccess.remove_absolute(TEST_DIR)


func _write(rel: String, text: String) -> String:
	var path := TEST_DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	return path


# -- Folder size ---------------------------------------------------------------


func test_calculate_folder_size() -> void:
	_write("size/a.txt", "hello")
	_write("size/b.txt", "world!")
	_assert_eq_int(Ops.calculate_folder_size(TEST_DIR.path_join("size")), 11, "folder size: 5+6=11 bytes")


func test_calculate_folder_size_empty() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR.path_join("empty"))
	_assert_eq_int(Ops.calculate_folder_size(TEST_DIR.path_join("empty")), 0, "folder size empty: 0 bytes")


func test_calculate_folder_size_nested() -> void:
	_write("nested/root.txt", "abc")
	_write("nested/child/deep.txt", "defgh")
	_assert_eq_int(Ops.calculate_folder_size(TEST_DIR.path_join("nested")), 8, "folder size nested: 3+5=8 bytes")


func test_calculate_folder_size_counts_hidden_files() -> void:
	_write("hidden/.steam_cloud", "1234")
	_assert_eq_int(Ops.calculate_folder_size(TEST_DIR.path_join("hidden")), 4, "folder size: dotfiles count")


func test_calculate_folder_size_of_a_missing_folder_is_zero() -> void:
	_assert_eq_int(Ops.calculate_folder_size(TEST_DIR.path_join("nope")), 0, "folder size: missing folder is 0")


# -- Emptying a folder ---------------------------------------------------------


func test_delete_directory_contents_keeps_the_folder() -> void:
	_write("logs/godot.log", "x")
	_write("logs/old/godot_2026.log", "y")
	_write("logs/.hidden", "z")
	var failures := Ops.delete_directory_contents(TEST_DIR.path_join("logs"))
	_assert_eq_int(failures, 0, "empty folder: no failures")
	_assert_true(DirAccess.dir_exists_absolute(TEST_DIR.path_join("logs")), "empty folder: the folder stays")
	_assert_eq_int(DirAccess.get_files_at(TEST_DIR.path_join("logs")).size(), 0, "empty folder: files gone")
	_assert_eq_int(DirAccess.get_directories_at(TEST_DIR.path_join("logs")).size(), 0, "empty folder: subfolders gone")


func test_delete_directory_contents_of_a_missing_folder_reports_a_failure() -> void:
	_assert_eq_int(Ops.delete_directory_contents(TEST_DIR.path_join("ghost")), 1, "empty missing folder: one failure")


# -- Deleting paths ------------------------------------------------------------


func test_delete_paths_removes_a_single_file() -> void:
	var path := _write("to_delete.txt", "delete me")
	var result: Dictionary = Ops.delete_paths([path] as Array[String])
	_assert_eq_int(int(result["deleted"]), 1, "delete file: one deleted")
	_assert_true(not FileAccess.file_exists(path), "delete file: gone")


func test_delete_paths_skips_a_path_that_is_already_gone() -> void:
	var result: Dictionary = Ops.delete_paths([TEST_DIR.path_join("ghost.txt")] as Array[String])
	_assert_eq_int(int(result["deleted"]), 0, "delete gone: nothing deleted")
	_assert_eq_int((result["failed"] as Array).size(), 0, "delete gone: not a failure")


func test_delete_paths_removes_nested_paths_deepest_first() -> void:
	var deep := _write("a/b/c.txt", "c")
	var folder := TEST_DIR.path_join("a")
	var result: Dictionary = Ops.delete_paths([folder, deep] as Array[String])
	_assert_eq_int((result["failed"] as Array).size(), 0, "delete nested: no failures")
	_assert_true(not DirAccess.dir_exists_absolute(folder), "delete nested: folder gone")


func test_describe_counts_files_inside_whole_folders() -> void:
	_write("d/one.json", "12")
	_write("d/two.json", "345")
	var single := _write("solo.cfg", "6789")
	var stats: Dictionary = Ops.describe([TEST_DIR.path_join("d"), single] as Array[String])
	_assert_eq_int(int(stats["folders"]), 1, "describe: one folder")
	_assert_eq_int(int(stats["files"]), 1, "describe: one loose file")
	_assert_eq_int(int(stats["bytes"]), 9, "describe: 2+3+4 bytes")


# -- Assertions ----------------------------------------------------------------


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)


func _assert_eq_int(actual: int, expected: int, label: String) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected %d, got %d" % [label, expected, actual])


func _print_summary() -> void:
	print("--- %d passed, %d failed ---" % [_pass_count, _fail_count])
