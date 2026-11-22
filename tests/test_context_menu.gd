extends SceneTree
## Right-click context menu: UserDataOps.context_actions, only_this,
## set_subtree_checked, absolute_path, and the single-item delete path.
## Run via: godot --headless --path . --script tests/test_context_menu.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")
const TEST_DIR := "user://test_context_menu"

var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	print("=== test_context_menu ===")
	for test: Callable in [
		test_root_row_gets_only_copy_and_show,
		test_file_row_actions,
		test_folder_row_actions,
		test_unsafe_path_cannot_be_deleted,
		test_absolute_path_matches_globalize_path,
		test_set_subtree_checked,
		test_only_this_on_a_file,
		test_only_this_on_a_folder,
		test_delete_this_removes_only_that_item,
		test_delete_this_refuses_unsafe_paths,
	]:
		_reset()
		test.call()
	_rm(TEST_DIR)
	print("--- %d passed, %d failed ---" % [_pass_count, _fail_count])
	quit(0 if _fail_count == 0 else 1)


func _reset() -> void:
	_rm(TEST_DIR)
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


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: ", label)
	else:
		_fail_count += 1
		print("  FAIL: ", label)


## user:// root, then folder "saves" (a.json, b.json) and file "c.json".
func _build_tree() -> Dictionary:
	var tree := Tree.new()
	tree.columns = 3
	var root := tree.create_item()
	root.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
	root.set_checked(2, true)
	var items := {"root": root, "tree": tree}
	for spec: Array in [["saves", "Folder", root], ["c.json", "File", root]]:
		var item := tree.create_item(spec[2])
		item.set_text(1, spec[1])
		item.set_metadata(1, TEST_DIR.path_join(spec[0]))
		item.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
		item.set_checked(2, true)
		items[spec[0]] = item
	for name: String in ["a.json", "b.json"]:
		var item := tree.create_item(items["saves"])
		item.set_text(1, "File")
		item.set_metadata(1, TEST_DIR.path_join("saves").path_join(name))
		item.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
		item.set_checked(2, true)
		items[name] = item
	return items


func test_root_row_gets_only_copy_and_show() -> void:
	var actions := Ops.context_actions("user://", true)
	_check(actions == PackedStringArray([Ops.ACTION_COPY_PATH, Ops.ACTION_COPY_ABSOLUTE, Ops.ACTION_SHOW]), "root row: copy and show only")


func test_file_row_actions() -> void:
	var actions := Ops.context_actions("user://a.json", false)
	_check(actions.has(Ops.ACTION_ONLY_THIS) and actions.has(Ops.ACTION_DELETE), "file row: only this and delete")
	_check(not actions.has(Ops.ACTION_CHECK_FOLDER) and not actions.has(Ops.ACTION_UNCHECK_FOLDER), "file row: no folder actions")


func test_folder_row_actions() -> void:
	var actions := Ops.context_actions("user://saves", true)
	_check(
		actions.has(Ops.ACTION_CHECK_FOLDER) and actions.has(Ops.ACTION_UNCHECK_FOLDER) and actions.has(Ops.ACTION_DELETE),
		"folder row: check/uncheck folder and delete"
	)


func test_unsafe_path_cannot_be_deleted() -> void:
	for bad: String in ["user://..", "user://a/../..", "res://x.gd", "/etc/passwd", "user://."]:
		_check(not Ops.context_actions(bad, false).has(Ops.ACTION_DELETE), "no delete action for '%s'" % bad)


func test_absolute_path_matches_globalize_path() -> void:
	_check(Ops.absolute_path("user://a/b.json") == ProjectSettings.globalize_path("user://a/b.json"), "absolute_path matches globalize_path")


func test_set_subtree_checked() -> void:
	var items := _build_tree()
	Ops.set_subtree_checked(items["saves"], false)
	_check(
		not items["saves"].is_checked(2) and not items["a.json"].is_checked(2) and not items["b.json"].is_checked(2),
		"folder and descendants unchecked"
	)
	_check(items["c.json"].is_checked(2) and items["root"].is_checked(2), "siblings and root untouched")
	Ops.set_subtree_checked(items["saves"], true)
	_check(items["a.json"].is_checked(2) and items["saves"].is_checked(2), "folder and descendants checked again")
	items["tree"].free()


func test_only_this_on_a_file() -> void:
	var items := _build_tree()
	Ops.only_this(items["root"], items["a.json"])
	var plan := Ops.plan_deletion(items["root"])
	_check(plan == [TEST_DIR.path_join("saves/a.json")], "only_this on a file plans just that file")
	_check(not items["saves"].is_checked(2) and not items["root"].is_checked(2), "ancestors stay unchecked")
	items["tree"].free()


func test_only_this_on_a_folder() -> void:
	var items := _build_tree()
	Ops.only_this(items["root"], items["saves"])
	var plan := Ops.plan_deletion(items["root"])
	_check(plan == [TEST_DIR.path_join("saves")], "only_this on a folder plans just that folder")
	_check(not items["c.json"].is_checked(2), "other rows unchecked")
	items["tree"].free()


func test_delete_this_removes_only_that_item() -> void:
	var target := _write("saves/a.json", "{}")
	var sibling := _write("saves/b.json", "{}")
	var other := _write("c.json", "{}")
	var paths: Array[String] = [target]
	var result := Ops.delete_paths(paths)
	_check(result.deleted == 1 and result.failed.is_empty(), "delete_paths reports one deletion")
	_check(not FileAccess.file_exists(target), "the item is gone")
	_check(FileAccess.file_exists(sibling) and FileAccess.file_exists(other), "siblings survive")
	var folder: Array[String] = [TEST_DIR.path_join("saves")]
	Ops.delete_paths(folder)
	_check(not DirAccess.dir_exists_absolute(TEST_DIR.path_join("saves")) and FileAccess.file_exists(other), "a folder goes whole, nothing else")


func test_delete_this_refuses_unsafe_paths() -> void:
	var keep := _write("keep.json", "{}")
	var paths: Array[String] = ["user://", TEST_DIR.path_join("../..")]
	var result := Ops.delete_paths(paths)
	_check(result.deleted == 0 and result.failed.size() == 2, "root and escaping paths are refused")
	_check(FileAccess.file_exists(keep), "files are untouched")
