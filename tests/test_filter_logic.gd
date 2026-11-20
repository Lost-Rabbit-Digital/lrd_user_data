extends SceneTree
## Filter and search rules of the Manage User Data dialog, run against the
## plugin's real code (addons/manage_user_data/user_data_ops.gd): the matching
## rules, then whole trees, then what a filtered delete would remove.
## Run via: godot --headless --path . --script tests/test_filter_logic.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")

var _pass_count := 0
var _fail_count := 0
var _tree: Tree


func _initialize() -> void:
	print("=== test_filter_logic ===")
	test_no_filters_matches_everything()
	test_search_term_matching()
	test_search_case_insensitive()
	test_filter_files_only()
	test_filter_folders_only()
	test_filter_json()
	test_filter_cache()
	test_filter_backups_and_temp()
	test_filter_test_runner_data()
	test_filter_logs()
	test_combined_filters()
	test_every_filter_has_a_menu_label()
	test_tree_folders_show_only_as_containers_for_file_filters()
	test_tree_search_keeps_matching_ancestors_visible()
	test_tree_test_data_filter_shows_the_whole_test_runner_folder()
	test_filtered_delete_removes_only_backups()
	test_filtered_delete_of_test_data_takes_the_folder_whole()
	if _tree:
		_tree.free()
	_print_summary()
	quit(0 if _fail_count == 0 else 1)


func item_matches(item_name: String, is_folder: bool, search_term: String, filter_types: Array[int]) -> bool:
	return Ops.matches_filters(item_name, "user://" + item_name, is_folder, search_term, filter_types)


func _f(ids: Array) -> Array[int]:
	var out: Array[int] = []
	for id: int in ids:
		out.append(id)
	return out


# -- Matching rules --------------------------------------------------------------


func test_no_filters_matches_everything() -> void:
	_assert_true(item_matches("save.json", false, "", _f([])), "no filter: file matches")
	_assert_true(item_matches("saves", true, "", _f([])), "no filter: folder matches")
	_assert_true(item_matches("data.cache", false, "", _f([])), "no filter: cache matches")


func test_search_term_matching() -> void:
	_assert_true(item_matches("player_save.json", false, "player", _f([])), "search: 'player' in name")
	_assert_true(not item_matches("enemy_data.json", false, "player", _f([])), "search: 'player' not in name")
	_assert_true(item_matches("my_folder", true, "folder", _f([])), "search: folder matches")


func test_search_case_insensitive() -> void:
	_assert_true(item_matches("PlayerSave.json", false, "playersave", _f([])), "case insensitive: mixed case")
	_assert_true(item_matches("DATA.JSON", false, "data", _f([])), "case insensitive: uppercase file")
	_assert_true(item_matches("data.json", false, "DATA", _f([])), "case insensitive: uppercase search")


func test_filter_files_only() -> void:
	_assert_true(item_matches("save.json", false, "", _f([Ops.FILTER_FILES])), "files only: file passes")
	_assert_true(not item_matches("saves", true, "", _f([Ops.FILTER_FILES])), "files only: folder excluded")


func test_filter_folders_only() -> void:
	_assert_true(item_matches("saves", true, "", _f([Ops.FILTER_FOLDERS])), "folders only: folder passes")
	_assert_true(not item_matches("save.json", false, "", _f([Ops.FILTER_FOLDERS])), "folders only: file excluded")


func test_filter_json() -> void:
	var filters := _f([Ops.FILTER_JSON])
	_assert_true(item_matches("data.json", false, "", filters), "json filter: .json passes")
	_assert_true(not item_matches("data.cache", false, "", filters), "json filter: .cache excluded")
	_assert_true(not item_matches("data.json.bak", false, "", filters), "json filter: .json.bak excluded")
	_assert_true(not item_matches("saves", true, "", filters), "json filter: folder excluded")


func test_filter_cache() -> void:
	_assert_true(item_matches("temp.cache", false, "", _f([Ops.FILTER_CACHE])), "cache filter: .cache passes")
	_assert_true(not item_matches("temp.json", false, "", _f([Ops.FILTER_CACHE])), "cache filter: .json excluded")


func test_filter_backups_and_temp() -> void:
	var filters := _f([Ops.FILTER_BACKUPS])
	_assert_true(item_matches("progress.json.bak", false, "", filters), "backups: .bak passes")
	_assert_true(item_matches("progress.json.v2.bak", false, "", filters), "backups: pre-migration copy passes")
	_assert_true(item_matches("progress.json.TMP", false, "", filters), "backups: .tmp passes, any case")
	_assert_true(not item_matches("progress.json", false, "", filters), "backups: the save itself excluded")
	_assert_true(not item_matches("old.bak", true, "", filters), "backups: a folder named .bak excluded")


func test_filter_test_runner_data() -> void:
	var filters := _f([Ops.FILTER_TEST_DATA])
	_assert_true(Ops.matches_type("test_runner", "user://test_runner", true, filters), "test data: the root")
	_assert_true(
		Ops.matches_type("p.json", "user://test_runner/saves/slot_0/p.json", false, filters), "test data: a file"
	)
	_assert_true(not Ops.matches_type("p.json", "user://saves/slot_0/p.json", false, filters), "test data: real save")
	_assert_true(
		not Ops.matches_type("test_runner_old", "user://test_runner_old", true, filters), "test data: prefix only"
	)


func test_filter_logs() -> void:
	var filters := _f([Ops.FILTER_LOGS])
	_assert_true(item_matches("godot.log", false, "", filters), "logs: .log passes")
	_assert_true(item_matches("shifts.jsonl", false, "", filters), "logs: run log .jsonl passes")
	_assert_true(not item_matches("shifts.json", false, "", filters), "logs: .json excluded")


func test_combined_filters() -> void:
	var filters := _f([Ops.FILTER_JSON, Ops.FILTER_CACHE])
	_assert_true(item_matches("data.json", false, "", filters), "combined: .json passes")
	_assert_true(item_matches("temp.cache", false, "", filters), "combined: .cache passes")
	_assert_true(not item_matches("image.png", false, "", filters), "combined: .png excluded")
	var both := _f([Ops.FILTER_FILES, Ops.FILTER_FOLDERS])
	_assert_true(item_matches("file.txt", false, "", both), "combined: file passes both")
	_assert_true(item_matches("folder", true, "", both), "combined: folder passes both")
	_assert_true(not item_matches("save.json", false, "zzz", _f([Ops.FILTER_JSON])), "search and type must both match")


func test_every_filter_has_a_menu_label() -> void:
	for id: int in range(Ops.FILTER_FILES, Ops.FILTER_LOGS + 1):
		_assert_true(Ops.FILTER_LABELS.has(id), "menu label for filter %d" % id)


# -- Whole trees ---------------------------------------------------------------


## DIR/{settings.cfg, godot.log, saves/{slot_0/{p.json, p.json.bak, p.json.tmp}},
##      test_runner/{saves/slot_0/{p.json}, empty/}}
## The tree's own test_runner node stands in for user://test_runner.
func _build() -> TreeItem:
	if _tree:
		_tree.free()
	_tree = Tree.new()
	_tree.set_columns(3)
	var root := _item(null, "user://", "user://", "Directory")
	_item(root, "settings.cfg", "user://settings.cfg", "File")
	_item(root, "godot.log", "user://godot.log", "File")
	var saves := _item(root, "saves", "user://saves", "Folder")
	var slot := _item(saves, "slot_0", "user://saves/slot_0", "Folder")
	for name: String in ["p.json", "p.json.bak", "p.json.tmp"]:
		_item(slot, name, "user://saves/slot_0/" + name, "File")
	var test_root := _item(root, "test_runner", "user://test_runner", "Folder")
	var t_saves := _item(test_root, "saves", "user://test_runner/saves", "Folder")
	_item(t_saves, "p.json", "user://test_runner/saves/p.json", "File")
	_item(test_root, "empty", "user://test_runner/empty", "Folder")
	return root


func _item(parent: TreeItem, name: String, path: String, type: String) -> TreeItem:
	var item := _tree.create_item(parent)
	item.set_text(0, name)
	item.set_text(1, type)
	item.set_metadata(Ops.COL_PATH, path)
	item.set_cell_mode(Ops.COL_CHECK, TreeItem.CELL_MODE_CHECK)
	item.set_checked(Ops.COL_CHECK, true)
	return item


func _visible_paths(item: TreeItem, out: Array[String] = []) -> Array[String]:
	if item.visible:
		out.append(str(item.get_metadata(Ops.COL_PATH)))
	var child := item.get_first_child()
	while child != null:
		_visible_paths(child, out)
		child = child.get_next()
	return out


func test_tree_folders_show_only_as_containers_for_file_filters() -> void:
	var root := _build()
	Ops.filter_tree(root, "", _f([Ops.FILTER_JSON]))
	var shown := _visible_paths(root)
	_assert_true(shown.has("user://saves/slot_0/p.json"), "tree json: the save is shown")
	_assert_true(shown.has("user://saves/slot_0"), "tree json: its folder is shown as a container")
	_assert_true(not shown.has("user://test_runner/empty"), "tree json: an empty folder is hidden")
	_assert_true(not shown.has("user://godot.log"), "tree json: the log is hidden")


func test_tree_search_keeps_matching_ancestors_visible() -> void:
	var root := _build()
	Ops.filter_tree(root, "BAK", _f([]))
	var shown := _visible_paths(root)
	_assert_true(shown.has("user://saves/slot_0/p.json.bak"), "tree search: match shown")
	_assert_true(shown.has("user://saves"), "tree search: ancestors shown")
	_assert_true(not shown.has("user://saves/slot_0/p.json"), "tree search: sibling hidden")


func test_tree_test_data_filter_shows_the_whole_test_runner_folder() -> void:
	var root := _build()
	Ops.filter_tree(root, "", _f([Ops.FILTER_TEST_DATA]))
	var shown := _visible_paths(root)
	_assert_true(shown.has("user://test_runner/empty"), "tree test data: empty folders shown too")
	_assert_true(shown.has("user://test_runner/saves/p.json"), "tree test data: files shown")
	_assert_true(not shown.has("user://saves/slot_0/p.json"), "tree test data: real saves hidden")
	_assert_true(not shown.has("user://saves"), "tree test data: real save folder hidden")


# -- What a filtered delete removes ---------------------------------------------


func test_filtered_delete_removes_only_backups() -> void:
	var root := _build()
	Ops.filter_tree(root, "", _f([Ops.FILTER_BACKUPS]))
	var plan: Array[String] = Ops.plan_deletion(root)
	plan.sort()
	_assert_eq_str(
		", ".join(plan), "user://saves/slot_0/p.json.bak, user://saves/slot_0/p.json.tmp", "backup delete plan"
	)


func test_filtered_delete_of_test_data_takes_the_folder_whole() -> void:
	var root := _build()
	Ops.filter_tree(root, "", _f([Ops.FILTER_TEST_DATA]))
	var plan: Array[String] = Ops.plan_deletion(root)
	_assert_eq_str(", ".join(plan), "user://test_runner", "test data delete plan")


# -- Assertions ----------------------------------------------------------------


func _assert_true(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)


func _assert_eq_str(actual: String, expected: String, label: String) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected '%s', got '%s'" % [label, expected, actual])


func _print_summary() -> void:
	print("--- %d passed, %d failed ---" % [_pass_count, _fail_count])
