extends SceneTree
## Sort and Auto-refresh: UserDataOps.sort_children, listing_signature,
## capture_state / restore_state, against real files and a real Tree.
## Run via: godot --headless --path . --script tests/test_sort_refresh.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")
const TEST_DIR := "user://test_sort_refresh"
const OUTSIDE_DIR := "user://test_sort_refresh_outside"

var _pass_count := 0
var _fail_count := 0
var _tree: Tree


func _initialize() -> void:
	print("=== test_sort_refresh ===")
	_reset()
	_make_files()
	test_sort_by_name_puts_folders_first_then_names()
	test_sort_by_size_is_largest_first_with_name_ties()
	test_sort_by_modified_is_newest_first()
	test_sort_is_recursive_and_cache_is_filled()
	test_sort_leaves_checks_visibility_and_metadata_alone()
	test_signature_is_stable_then_sees_add_resize_and_remove()
	test_signature_does_not_follow_a_symlinked_folder()
	test_capture_and_restore_keep_unchecked_and_collapsed()
	test_restore_leaves_new_items_checked_and_ignores_gone_ones()
	_rm(TEST_DIR)
	_rm(OUTSIDE_DIR)
	if _tree:
		_tree.free()
	print("--- %d passed, %d failed ---" % [_pass_count, _fail_count])
	quit(0 if _fail_count == 0 else 1)


# -- Fixtures --------------------------------------------------------------------


func _reset() -> void:
	_rm(TEST_DIR)
	_rm(OUTSIDE_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_DIR)


func _rm(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		Ops.delete_directory_contents(path)
		DirAccess.remove_absolute(path)


func _write(rel: String, size: int) -> String:
	var path := TEST_DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("x".repeat(size))
	file.close()
	return path


## a_dir (old, 100 B), c_dir (old, 900 B), b_dir (new, 5 B), then files:
## a_old.txt 10 B and B_tie.txt 10 B (old), z_new.txt 50 B (new).
func _make_files() -> void:
	_write("a_dir/f.txt", 100)
	_write("c_dir/f.txt", 900)
	_write("a_old.txt", 10)
	_write("B_tie.txt", 10)
	OS.delay_msec(1100)
	_write("b_dir/f.txt", 5)
	_write("z_new.txt", 50)


func _build() -> TreeItem:
	if _tree:
		_tree.free()
	_tree = Tree.new()
	_tree.set_columns(3)
	var root := _item(null, "user://test_sort_refresh", TEST_DIR, "Directory")
	_populate(root, TEST_DIR)
	return root


func _populate(parent: TreeItem, path: String) -> void:
	var dir := DirAccess.open(path)
	dir.include_hidden = true
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path.path_join(name)
		if dir.current_is_dir():
			_populate(_item(parent, name, full, "Folder"), full)
		else:
			_item(parent, name, full, "File (1 B)")
		name = dir.get_next()
	dir.list_dir_end()


func _item(parent: TreeItem, name: String, path: String, type: String) -> TreeItem:
	var item := _tree.create_item(parent)
	item.set_text(0, name)
	item.set_text(1, type)
	item.set_metadata(Ops.COL_PATH, path)
	item.set_cell_mode(Ops.COL_CHECK, TreeItem.CELL_MODE_CHECK)
	item.set_checked(Ops.COL_CHECK, true)
	return item


func _names(parent: TreeItem) -> Array[String]:
	var out: Array[String] = []
	var child := parent.get_first_child()
	while child != null:
		out.append(child.get_text(0))
		child = child.get_next()
	return out


func _by_path(root: TreeItem, rel: String) -> TreeItem:
	return Ops.find_item_by_path(root, TEST_DIR.path_join(rel))


# -- Sort ------------------------------------------------------------------------


func test_sort_by_name_puts_folders_first_then_names() -> void:
	var root := _build()
	Ops.sort_children(root, Ops.SORT_NAME)
	_assert_eq(_names(root), ["a_dir", "b_dir", "c_dir", "a_old.txt", "B_tie.txt", "z_new.txt"], "name: folders first, case-insensitive")


func test_sort_by_size_is_largest_first_with_name_ties() -> void:
	var root := _build()
	Ops.sort_children(root, Ops.SORT_SIZE)
	_assert_eq(_names(root), ["c_dir", "a_dir", "b_dir", "z_new.txt", "a_old.txt", "B_tie.txt"], "size: folders first, largest first, equal sizes by name")


func test_sort_by_modified_is_newest_first() -> void:
	var root := _build()
	Ops.sort_children(root, Ops.SORT_MODIFIED)
	var names := _names(root)
	_assert_eq(names[0], "b_dir", "modified: the folder with the newest file is first folder")
	_assert_eq(names[3], "z_new.txt", "modified: the newest file is first file")
	_assert_true(names.slice(0, 3).has("a_dir") and names.slice(0, 3).has("c_dir"), "modified: folders still come before files")


func test_sort_is_recursive_and_cache_is_filled() -> void:
	var root := _build()
	_write("c_dir/small.txt", 1)
	_write("c_dir/big.txt", 400)
	root = _build()
	var cache := {}
	Ops.sort_children(root, Ops.SORT_SIZE, cache)
	_assert_eq(_names(_by_path(root, "c_dir")), ["f.txt", "big.txt", "small.txt"], "size: children of subfolders are sorted too")
	_assert_true(cache.has(TEST_DIR.path_join("c_dir")) and int(cache[TEST_DIR.path_join("c_dir")]) == 1301, "cache holds the folder size")
	DirAccess.remove_absolute(TEST_DIR.path_join("c_dir/small.txt"))
	DirAccess.remove_absolute(TEST_DIR.path_join("c_dir/big.txt"))


func test_sort_leaves_checks_visibility_and_metadata_alone() -> void:
	var root := _build()
	_by_path(root, "z_new.txt").set_checked(Ops.COL_CHECK, false)
	_by_path(root, "a_dir/f.txt").set_checked(Ops.COL_CHECK, false)
	_by_path(root, "B_tie.txt").visible = false
	_by_path(root, "b_dir").set_collapsed(true)
	var before := _snapshot(root)
	Ops.sort_children(root, Ops.SORT_SIZE)
	Ops.sort_children(root, Ops.SORT_MODIFIED)
	Ops.sort_children(root, Ops.SORT_NAME)
	_assert_eq(_snapshot(root), before, "sorting changes no check state, visibility, collapsed state or metadata")
	var planned := Ops.plan_deletion(root)
	_assert_true(not planned.has(TEST_DIR.path_join("B_tie.txt")) and not planned.has(TEST_DIR.path_join("z_new.txt")), "a hidden or unchecked row is still not planned for deletion after sorting")


## path -> [checked, visible, collapsed, text], independent of row order.
func _snapshot(item: TreeItem, out: Dictionary = {}) -> Dictionary:
	out[str(item.get_metadata(Ops.COL_PATH))] = [item.is_checked(Ops.COL_CHECK), item.visible, item.is_collapsed(), item.get_text(0)]
	var child := item.get_first_child()
	while child != null:
		_snapshot(child, out)
		child = child.get_next()
	return out


# -- listing_signature -----------------------------------------------------------


func test_signature_is_stable_then_sees_add_resize_and_remove() -> void:
	var first := Ops.listing_signature(TEST_DIR)
	_assert_true(first == Ops.listing_signature(TEST_DIR), "signature is stable when nothing changed")
	_write("new_file.txt", 3)
	var added := Ops.listing_signature(TEST_DIR)
	_assert_true(added != first, "signature changes when a file is added")
	_write("new_file.txt", 30)
	var resized := Ops.listing_signature(TEST_DIR)
	_assert_true(resized != added, "signature changes when a file is resized")
	DirAccess.remove_absolute(TEST_DIR.path_join("new_file.txt"))
	_assert_true(Ops.listing_signature(TEST_DIR) == first, "signature returns to the old value once the file is removed")
	DirAccess.make_dir_recursive_absolute(TEST_DIR.path_join("hidden_dir/.secret"))
	_assert_true(Ops.listing_signature(TEST_DIR) != first, "signature sees new folders and hidden entries")
	_rm(TEST_DIR.path_join("hidden_dir"))


func test_signature_does_not_follow_a_symlinked_folder() -> void:
	DirAccess.make_dir_recursive_absolute(OUTSIDE_DIR)
	var f := FileAccess.open(OUTSIDE_DIR.path_join("o.txt"), FileAccess.WRITE)
	f.store_string("o")
	f.close()
	var link := TEST_DIR.path_join("linked")
	var err := DirAccess.open(TEST_DIR).create_link(ProjectSettings.globalize_path(OUTSIDE_DIR), ProjectSettings.globalize_path(link))
	if err != OK:
		_assert_true(true, "symlinks unsupported here (error %d): skipped" % err)
		return
	var with_link := Ops.listing_signature(TEST_DIR)
	var g := FileAccess.open(OUTSIDE_DIR.path_join("added_later.txt"), FileAccess.WRITE)
	g.store_string("more")
	g.close()
	_assert_true(Ops.listing_signature(TEST_DIR) == with_link, "a change inside a symlinked folder's target does not change the signature")
	DirAccess.remove_absolute(link)
	_assert_true(Ops.listing_signature(TEST_DIR) != with_link, "removing the link itself does")


# -- capture_state / restore_state -----------------------------------------------


func test_capture_and_restore_keep_unchecked_and_collapsed() -> void:
	var root := _build()
	_by_path(root, "z_new.txt").set_checked(Ops.COL_CHECK, false)
	_by_path(root, "a_dir/f.txt").set_checked(Ops.COL_CHECK, false)
	_by_path(root, "c_dir").set_collapsed(true)
	var state := Ops.capture_state(root)
	_assert_true(state.has(TEST_DIR.path_join("c_dir")) and bool(state[TEST_DIR.path_join("c_dir")].collapsed), "capture records collapsed folders")
	var fresh := _build()
	Ops.restore_state(fresh, state)
	_assert_true(not _by_path(fresh, "z_new.txt").is_checked(Ops.COL_CHECK) and not _by_path(fresh, "a_dir/f.txt").is_checked(Ops.COL_CHECK), "restore keeps unchecked items unchecked")
	_assert_true(_by_path(fresh, "c_dir").is_collapsed() and not _by_path(fresh, "a_dir").is_collapsed(), "restore keeps collapsed folders collapsed and others expanded")
	_assert_true(_by_path(fresh, "a_old.txt").is_checked(Ops.COL_CHECK), "untouched items stay checked")


func test_restore_leaves_new_items_checked_and_ignores_gone_ones() -> void:
	var root := _build()
	_by_path(root, "a_old.txt").set_checked(Ops.COL_CHECK, false)
	_by_path(root, "B_tie.txt").set_checked(Ops.COL_CHECK, false)
	var state := Ops.capture_state(root)
	_write("brand_new.txt", 2)
	DirAccess.remove_absolute(TEST_DIR.path_join("B_tie.txt"))
	var fresh := _build()
	Ops.restore_state(fresh, state)
	_assert_true(_by_path(fresh, "brand_new.txt").is_checked(Ops.COL_CHECK), "a file that appeared after the capture is checked, like on first open")
	_assert_true(not _by_path(fresh, "a_old.txt").is_checked(Ops.COL_CHECK), "an unchecked file that still exists stays unchecked")
	_assert_true(_by_path(fresh, "B_tie.txt") == null, "state for a file that is gone is ignored")
	DirAccess.remove_absolute(TEST_DIR.path_join("brand_new.txt"))
	_write("B_tie.txt", 10)


# -- Assertions ------------------------------------------------------------------


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)


func _assert_eq(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])
