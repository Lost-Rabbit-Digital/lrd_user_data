extends SceneTree
## Restore Zip: UserDataOps.zip_listing / restore_destination / unzip_into_user.
## Round-trips a Zip Selected archive, and feeds hostile archives ("zip-slip")
## that try to write outside user://.
## Run via: godot --headless --path . --script tests/test_restore_zip.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")
const TEST_DIR := "user://test_restore"
const OUT_DIR := "user://test_restore_out"

var _pass_count := 0
var _fail_count := 0
var _outside := ""


func _initialize() -> void:
	print("=== test_restore_zip ===")
	_outside = ProjectSettings.globalize_path("user://").get_base_dir().path_join("test_restore_outside")
	for test: Callable in [
		test_a_zip_selected_archive_round_trips,
		test_listing_reports_what_would_be_overwritten,
		test_hostile_entry_names_are_refused,
		test_a_hostile_archive_writes_nothing_outside_user,
		test_a_symlinked_folder_is_not_written_through,
		test_a_missing_archive_is_an_error,
	]:
		_reset()
		test.call()
	_reset()
	DirAccess.remove_absolute(TEST_DIR)
	DirAccess.remove_absolute(OUT_DIR)
	print("--- %d passed, %d failed ---" % [_pass_count, _fail_count])
	quit(0 if _fail_count == 0 else 1)


func _reset() -> void:
	for dir: String in [TEST_DIR, OUT_DIR]:
		if DirAccess.dir_exists_absolute(dir):
			Ops.delete_directory_contents(dir)
	if DirAccess.dir_exists_absolute(_outside):
		for file: String in DirAccess.get_files_at(_outside):
			DirAccess.remove_absolute(_outside.path_join(file))
		DirAccess.remove_absolute(_outside)
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _zip(entries: Dictionary) -> String:
	var zip_path := OUT_DIR.path_join("crafted.zip")
	var packer := ZIPPacker.new()
	packer.open(zip_path)
	for name: String in entries:
		packer.start_file(name)
		packer.write_file(str(entries[name]).to_utf8_buffer())
		packer.close_file()
	packer.close()
	return zip_path


# -- Tests ---------------------------------------------------------------------


func test_a_zip_selected_archive_round_trips() -> void:
	_write(TEST_DIR.path_join("saves/slot_0/progress.json"), "{\"coins\": 7}")
	_write(TEST_DIR.path_join(".hidden"), "h")
	var zip := OUT_DIR.path_join("bug.zip")
	var paths: Array[String] = [TEST_DIR]
	Ops.zip_paths(paths, zip)
	Ops.delete_directory_contents(TEST_DIR)
	var result := Ops.unzip_into_user(zip)
	_check(result.error == OK and result.files == 2, "round trip: two files restored (%d)" % result.files)
	_check(
		FileAccess.get_file_as_string(TEST_DIR.path_join("saves/slot_0/progress.json")) == "{\"coins\": 7}",
		"round trip: content and folders restored"
	)
	_check(FileAccess.file_exists(TEST_DIR.path_join(".hidden")), "round trip: dotfile restored")


func test_listing_reports_what_would_be_overwritten() -> void:
	_write(TEST_DIR.path_join("a.json"), "old")
	var zip := _zip({"test_restore/a.json": "new", "test_restore/b.json": "b", "../evil.txt": "x"})
	var listing := Ops.zip_listing(zip)
	_check(listing.error == OK, "listing: OK")
	_check(listing.entries.size() == 2, "listing: two safe entries")
	_check(Array(listing.existing) == [TEST_DIR.path_join("a.json")], "listing: a.json would be overwritten")
	_check(Array(listing.unsafe) == ["../evil.txt"], "listing: traversal entry flagged")
	_check(FileAccess.get_file_as_string(TEST_DIR.path_join("a.json")) == "old", "listing: writes nothing")


func test_hostile_entry_names_are_refused() -> void:
	for name: String in [
		"../evil.txt",
		"a/../../evil.txt",
		"/etc/evil",
		"C:/evil.txt",
		"a\\..\\..\\evil.txt",
		"./x",
		"a//b",
		"",
	]:
		_check(Ops.restore_destination(name) == "", "refused: '%s'" % name)
	_check(Ops.restore_destination("saves/a.json") == "user://saves/a.json", "accepted: plain relative path")


func test_a_hostile_archive_writes_nothing_outside_user() -> void:
	var zip := _zip({"../test_restore_outside/evil.txt": "x", "test_restore/ok.txt": "ok"})
	var result := Ops.unzip_into_user(zip)
	_check(result.files == 1, "hostile: only the safe entry written")
	_check(result.skipped.size() == 1, "hostile: traversal entry skipped")
	_check(not FileAccess.file_exists(_outside.path_join("evil.txt")), "hostile: nothing written beside user://")
	_check(FileAccess.file_exists(TEST_DIR.path_join("ok.txt")), "hostile: safe entry restored")


func test_a_symlinked_folder_is_not_written_through() -> void:
	DirAccess.make_dir_recursive_absolute(_outside)
	var dir := DirAccess.open(TEST_DIR)
	if dir.create_link(_outside, "link") != OK:
		print("  SKIP: symbolic links unavailable here")
		return
	_check(Ops.restore_destination("test_restore/link/evil.txt") == "", "symlink: destination refused")
	var zip := _zip({"test_restore/link/evil.txt": "x"})
	Ops.unzip_into_user(zip)
	_check(not FileAccess.file_exists(_outside.path_join("evil.txt")), "symlink: target untouched")
	DirAccess.remove_absolute(TEST_DIR.path_join("link"))


func test_a_missing_archive_is_an_error() -> void:
	_check(Ops.unzip_into_user(OUT_DIR.path_join("nope.zip")).error != OK, "missing: error")
	_check(Ops.zip_listing(OUT_DIR.path_join("nope.zip")).error != OK, "missing: listing error")


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s" % label)
