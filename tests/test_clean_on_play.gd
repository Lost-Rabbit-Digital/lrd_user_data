extends SceneTree
## Clean on Play: UserDataOps.clean_targets / invalid_patterns / clean_on_play
## against real files. Patterns are relative to user://.
## Run via: godot --headless --path . --script tests/test_clean_on_play.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")
const REL := "test_clean_play"
const TEST_DIR := "user://test_clean_play"

var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	print("=== test_clean_on_play ===")
	for test: Callable in [
		test_exact_file_is_matched,
		test_folder_with_trailing_slash_is_removed_whole,
		test_glob_in_a_subfolder,
		test_glob_does_not_recurse,
		test_trailing_slash_glob_matches_folders_only,
		test_invalid_patterns_are_ignored_and_reported,
		test_patterns_outside_user_never_match,
		test_symlinked_folder_is_not_globbed_into,
		test_minimal_set_drops_paths_inside_a_match,
		test_duplicates_collapse,
		test_minimal_set_holds_when_a_sibling_name_sorts_between,
		test_missing_paths_match_nothing,
		test_clean_on_play_deletes_exactly_the_matches,
		test_a_top_level_match_everything_pattern_is_refused,
	]:
		_reset()
		test.call()
	_rm(TEST_DIR)
	_rm("user://test_clean_play_outside.txt")
	print("--- %d passed, %d failed ---" % [_pass_count, _fail_count])
	quit(0 if _fail_count == 0 else 1)


func _reset() -> void:
	_rm(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_DIR)


func _rm(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		Ops.delete_directory_contents(path)
		DirAccess.remove_absolute(path)
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _write(rel: String) -> String:
	var path := TEST_DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("x")
	file.close()
	return path


func _p(patterns: Array) -> PackedStringArray:
	return PackedStringArray(patterns)


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("PASS: ", label)
	else:
		_fail_count += 1
		print("FAIL: ", label)


func test_exact_file_is_matched() -> void:
	var f := _write("saves/slot_0/progress.json")
	_write("saves/slot_0/other.json")
	var got := Ops.clean_targets(_p([REL + "/saves/slot_0/progress.json"]))
	_check(got == [f], "an exact relative path selects that one file")


func test_folder_with_trailing_slash_is_removed_whole() -> void:
	_write("runner/a.txt")
	_write("runner/deep/b.txt")
	var got := Ops.clean_targets(_p([REL + "/runner/"]))
	_check(got == [TEST_DIR + "/runner"], "a folder with a trailing slash is selected whole")
	var result := Ops.clean_on_play(_p([REL + "/runner/"]))
	_check(not DirAccess.dir_exists_absolute(TEST_DIR + "/runner") and result.deleted == 1, "and removed with everything in it")


func test_glob_in_a_subfolder() -> void:
	var a := _write("saves/a.bak")
	var b := _write("saves/b.bak")
	_write("saves/keep.json")
	var got := Ops.clean_targets(_p([REL + "/saves/*.bak"]))
	got.sort()
	_check(got == [a, b], "saves/*.bak selects only the .bak files in that folder")


func test_glob_does_not_recurse() -> void:
	var top := _write("top.tmp")
	_write("nested/deep.tmp")
	var got := Ops.clean_targets(_p([REL + "/*.tmp"]))
	_check(got == [top], "a glob matches only names in its own folder")
	_check(Ops.clean_targets(_p([REL + "/**/*.tmp"])).is_empty(), "** is not supported and matches nothing")


func test_trailing_slash_glob_matches_folders_only() -> void:
	_write("slot_1/x.txt")
	_write("slot_1.txt")
	var got := Ops.clean_targets(_p([REL + "/slot_*/"]))
	_check(got == [TEST_DIR + "/slot_1"], "a glob with a trailing slash skips files")


func test_invalid_patterns_are_ignored_and_reported() -> void:
	_write("a.tmp")
	var patterns := _p(["", "   ", "..", ".", REL + "/../x", "a\\b", "/etc", "C:/x", REL + "/*/a.tmp", REL + "//a.tmp", REL + "/*.tmp"])
	var got := Ops.clean_targets(patterns)
	_check(got == [TEST_DIR + "/a.tmp"], "only the valid pattern selects anything")
	var invalid := Ops.invalid_patterns(patterns)
	_check(not invalid.has("") and not invalid.has("   "), "blank entries are skipped, not reported")
	_check(invalid.size() == 8, "every other bad pattern is reported (got %d)" % invalid.size())
	_check(Ops.invalid_patterns(_p(["test_runner/", "*.tmp", "a/b.json"])).is_empty(), "good patterns are not reported")


func test_patterns_outside_user_never_match() -> void:
	var outside := "user://test_clean_play_outside.txt"
	var file := FileAccess.open(outside, FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var got := Ops.clean_targets(_p([REL + "/../test_clean_play_outside.txt", "../x", "/etc", "C:/x", "user://test_clean_play_outside.txt"]))
	_check(got.is_empty(), "../x, /etc, C:/x and user:// paths never match")
	_check(FileAccess.file_exists(outside), "the file next to the test folder is untouched")


func test_symlinked_folder_is_not_globbed_into() -> void:
	var outside_dir := "user://test_clean_play_linktarget"
	DirAccess.make_dir_recursive_absolute(outside_dir)
	var file := FileAccess.open(outside_dir + "/victim.tmp", FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var err := DirAccess.open(TEST_DIR).create_link(ProjectSettings.globalize_path(outside_dir), "link")
	if err != OK:
		print("SKIP: symlinks unsupported here (error %d)" % err)
		_check(true, "symlink test skipped")
		_check(true, "symlink test skipped")
		_rm(outside_dir)
		return
	_check(Ops.clean_targets(_p([REL + "/link/*.tmp"])).is_empty(), "a glob does not look inside a symlinked folder")
	_check(Ops.clean_targets(_p([REL + "/link/victim.tmp"])).is_empty(), "an exact path through a symlinked folder is not selected either")
	Ops.clean_on_play(_p([REL + "/link"]))
	_check(FileAccess.file_exists(outside_dir + "/victim.tmp"), "removing the link itself leaves the target's files")
	_rm(outside_dir)


func test_minimal_set_drops_paths_inside_a_match() -> void:
	_write("runner/a.tmp")
	_write("runner/b.log")
	var got := Ops.clean_targets(_p([REL + "/runner/a.tmp", REL + "/runner/", REL + "/runner/*.log"]))
	_check(got == [TEST_DIR + "/runner"], "a folder and files inside it give just the folder")


func test_minimal_set_holds_when_a_sibling_name_sorts_between() -> void:
	# "a-b" sorts between "a" and "a/c" as a string, which hid "a/c" inside "a".
	_write("a/c")
	_write("a-b")
	var got := Ops.clean_targets(_p([REL + "/a", REL + "/a-b", REL + "/a/c"]))
	_check(got == [TEST_DIR + "/a", TEST_DIR + "/a-b"], "nothing returned is inside another returned path (got %s)" % str(got))


func test_duplicates_collapse() -> void:
	_write("a.tmp")
	var got := Ops.clean_targets(_p([REL + "/a.tmp", REL + "/*.tmp", REL + "/a.tmp"]))
	_check(got.size() == 1, "the same path from several patterns is returned once")


func test_missing_paths_match_nothing() -> void:
	_check(Ops.clean_targets(_p([REL + "/nope", REL + "/nope/*.tmp", REL + "/nope/"])).is_empty(), "paths that do not exist match nothing")
	_check(not Ops.clean_targets(_p([REL + "/*"])).has("user://"), "a folder glob never selects user:// itself")


func test_clean_on_play_deletes_exactly_the_matches() -> void:
	_write("gone/a.txt")
	_write("saves/x.bak")
	_write("saves/keep.json")
	_write("keep/b.txt")
	var result := Ops.clean_on_play(_p([REL + "/gone/", REL + "/saves/*.bak"]))
	_check(result.deleted == 2 and result.failed.is_empty(), "two items deleted, none failed")
	_check(not DirAccess.dir_exists_absolute(TEST_DIR + "/gone") and not FileAccess.file_exists(TEST_DIR + "/saves/x.bak"), "the matches are gone")
	_check(FileAccess.file_exists(TEST_DIR + "/saves/keep.json") and FileAccess.file_exists(TEST_DIR + "/keep/b.txt"), "everything else survives")


func test_a_top_level_match_everything_pattern_is_refused() -> void:
	_write("a.tmp")
	for pattern: String in ["*", "*/", "**", "?*", "*?"]:
		_check(Ops.clean_targets(_p([pattern])).is_empty(), "'%s' selects nothing" % pattern)
		_check(Ops.invalid_patterns(_p([pattern])) == _p([pattern]), "'%s' is reported" % pattern)
	_check(Ops.invalid_patterns(_p(["*.tmp", "test_*/"])).is_empty(), "globs with a fixed part stay valid")
