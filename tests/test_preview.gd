extends SceneTree
## Preview pane: UserDataOps.preview against real files. Read-only.
## Run via: godot --headless --path . --script tests/test_preview.gd

const Ops := preload("res://addons/manage_user_data/user_data_ops.gd")
const TEST_DIR := "user://test_preview"

var _pass_count := 0
var _fail_count := 0


func _initialize() -> void:
	print("=== test_preview ===")
	for test: Callable in [
		test_json_is_pretty_printed,
		test_invalid_json_shows_raw_text_and_the_error_line,
		test_text_is_cut_at_max_bytes,
		test_a_cut_inside_a_multibyte_character_is_still_text,
		test_binary_gets_a_hex_dump,
		test_invalid_utf8_is_binary,
		test_paths_outside_user_are_refused,
		test_folder_summary_counts_files_and_size,
		test_missing_file,
		test_jsonl_shows_the_first_lines,
		test_jsonl_with_a_bad_line_names_its_line,
		test_images_are_left_to_the_ui,
		test_preview_never_changes_the_file,
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


func _write(rel: String, data: PackedByteArray) -> String:
	var path := TEST_DIR.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(data)
	file.close()
	return path


func _write_text(rel: String, text: String) -> String:
	return _write(rel, text.to_utf8_buffer())


func _check(ok: bool, label: String) -> void:
	if ok:
		_pass_count += 1
	else:
		_fail_count += 1
		print("FAIL: %s" % label)


func test_json_is_pretty_printed() -> void:
	var r := Ops.preview(_write_text("save.json", '{"a":1,"b":[true]}'))
	_check(r.kind == "json", "json kind")
	_check(r.text == '{\n  "a": 1.0,\n  "b": [\n    true\n  ]\n}\n'.strip_edges(), "json pretty-printed with two spaces")
	_check(r.error == "" and not r.truncated, "json no error, not truncated")


func test_invalid_json_shows_raw_text_and_the_error_line() -> void:
	var raw := '{\n  "a": 1,\n  "b": \n'
	var r := Ops.preview(_write_text("bad.json", raw))
	_check(r.kind == "text" and r.text == raw, "invalid json shows raw text")
	_check(r.error.begins_with("invalid JSON: ") and r.error.contains("at line "), "invalid json error format: " + r.error)


func test_text_is_cut_at_max_bytes() -> void:
	var r := Ops.preview(_write_text("long.txt", "x".repeat(1000)), 100)
	_check(r.truncated and r.text.length() == 100, "text cut at max_bytes")
	_check(r.bytes == 1000, "bytes reports the full size")
	var whole := Ops.preview(_write_text("short.txt", "hello"), 100)
	_check(not whole.truncated and whole.kind == "text" and whole.text == "hello", "short text whole")


func test_a_cut_inside_a_multibyte_character_is_still_text() -> void:
	# "é" is 2 bytes; a 3-byte window ends in the middle of the second one.
	var r := Ops.preview(_write_text("utf.txt", "ééé"), 3)
	_check(r.kind == "text" and r.text == "é" and r.truncated, "partial character trimmed, not binary")


func test_binary_gets_a_hex_dump() -> void:
	var data := PackedByteArray()
	for i in 40:
		data.append(i)
	data[5] = 0x41
	var r := Ops.preview(_write("blob.bin", data))
	_check(r.kind == "binary", "NUL bytes are binary")
	var lines: PackedStringArray = r.text.split("\n")
	_check(lines.size() == 3, "40 bytes make 3 lines")
	_check(lines[0].begins_with("00000000  00 01 02 03 04 41 06 07"), "first line has offset and hex")
	_check(lines[0].ends_with("|.....A..........|"), "ascii column")
	_check(lines[1].begins_with("00000010  "), "second line offset")
	var big := PackedByteArray()
	big.resize(1000)
	_check(Ops.preview(_write("big.bin", big)).text.split("\n").size() == 16, "dump stops at 256 bytes")


func test_invalid_utf8_is_binary() -> void:
	var r := Ops.preview(_write("bad.dat", PackedByteArray([0x68, 0xFF, 0xFE, 0x69])))
	_check(r.kind == "binary", "invalid UTF-8 is binary")


func test_paths_outside_user_are_refused() -> void:
	for p: String in ["res://project.godot", "/etc/passwd", "user://", "user://../x", "user://a/../../x"]:
		_check(Ops.preview(p).kind == "refused", "refused: " + p)


func test_folder_summary_counts_files_and_size() -> void:
	_write_text("dir/a.txt", "abc")
	_write_text("dir/sub/.hidden", "de")
	var r := Ops.preview(TEST_DIR.path_join("dir"))
	_check(r.kind == "folder" and r.bytes == 5, "folder kind and size")
	_check(r.text.begins_with("2 file(s), "), "folder file count includes hidden: " + r.text)


func test_missing_file() -> void:
	var r := Ops.preview(TEST_DIR.path_join("nope.json"))
	_check(r.kind == "missing" and r.text == "" and r.bytes == 0, "missing file")


func test_jsonl_shows_the_first_lines() -> void:
	var rows := ""
	for i in 80:
		rows += '{"n":%d}\n' % i
	var r := Ops.preview(_write_text("runs.jsonl", rows))
	_check(r.kind == "json" and r.truncated, "jsonl is json and flagged truncated past 50 rows")
	_check(r.text.contains('"n": 0') and r.text.contains('"n": 49') and not r.text.contains('"n": 50'), "first 50 rows only")
	var small := Ops.preview(_write_text("two.jsonl", '{"a":1}\n{"a":2}\n'))
	_check(not small.truncated and small.text.contains('"a": 2'), "short jsonl not truncated")


func test_jsonl_with_a_bad_line_names_its_line() -> void:
	var r := Ops.preview(_write_text("mixed.jsonl", '{"a":1}\n{oops\n{"a":3}\n'))
	_check(r.kind == "text" and r.error.ends_with("at line 2"), "bad line number: " + r.error)
	_check(r.text.contains("{oops"), "raw line kept")


func test_images_are_left_to_the_ui() -> void:
	var r := Ops.preview(_write("pic.png", PackedByteArray([0x89, 0x50, 0x4E, 0x47])))
	_check(r.kind == "image" and r.text == "" and r.bytes == 4, "image kind, no text")


func test_preview_never_changes_the_file() -> void:
	var path := _write_text("keep.json", '{"a":1}')
	Ops.preview(path)
	_check(FileAccess.get_file_as_string(path) == '{"a":1}', "file content untouched")
