@tool
extends EditorPlugin

const UserDataOps := preload("res://addons/manage_user_data/user_data_ops.gd")

var button: Button
var confirmation_dialog: ConfirmationDialog
var help_dialog: AcceptDialog
var tree: Tree
var search_text: LineEdit
var filter_menu_button: MenuButton
var clear_filter_btn: Button
var warning_label: Label
var select_all_checkbox: CheckBox
var preview_header: Label
var preview_text: TextEdit
var preview_image: TextureRect
var preview_copy_btn: Button
var active_type_filters: Array[int] = []
var clean_matches_label: Label
var sort_option: OptionButton
var auto_refresh_check: CheckBox
var refresh_timer: Timer
var _last_signature := 0
var _sort_cache := {}
var _refreshing := false
var context_menu: PopupMenu
var _context_item_path := ""
var delete_one_dialog: ConfirmationDialog

const META_SECTION := "manage_user_data"
const DEFAULT_CLEAN_PATTERNS := "test_runner/"


func _enter_tree() -> void:
	var godot_version := Engine.get_version_info()
	if godot_version.major < 4 or (godot_version.major == 4 and godot_version.minor < 3):
		push_warning("Manage User Data: This plugin requires Godot 4.3+. You are running %s. Some features may not work." % godot_version.string)

	button = Button.new()
	button.icon = EditorInterface.get_base_control().get_theme_icon("Filesystem", "EditorIcons")
	button.tooltip_text = "Selectively delete user:// directory contents"
	button.pressed.connect(_on_button_pressed)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, button)


func _exit_tree() -> void:
	if button:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, button)
		button.queue_free()

	if help_dialog:
		help_dialog.queue_free()

	if confirmation_dialog:
		confirmation_dialog.queue_free()


## Called by the editor right before it runs the project. When Clean on Play is
## enabled, deletes the items its patterns select (user_data_ops.gd decides what
## that is). Always returns true: this never blocks a run.
func _build() -> bool:
	if _clean_enabled():
		var patterns := _clean_patterns()
		var result := UserDataOps.clean_on_play(patterns)
		print("Manage User Data: cleaned %d item(s) before play" % result.deleted)
		if not result.failed.is_empty():
			push_warning("Manage User Data: %d item(s) could not be cleaned before play." % result.failed.size())
		var invalid := UserDataOps.invalid_patterns(patterns)
		if not invalid.is_empty():
			push_warning("Manage User Data: ignored Clean on Play pattern(s): %s" % ", ".join(invalid))
	return true


func _clean_enabled() -> bool:
	var settings := EditorInterface.get_editor_settings()
	return bool(settings.get_project_metadata(META_SECTION, "clean_on_play_enabled", false))


func _clean_pattern_text() -> String:
	var settings := EditorInterface.get_editor_settings()
	return str(settings.get_project_metadata(META_SECTION, "clean_on_play_patterns", DEFAULT_CLEAN_PATTERNS))


func _clean_patterns() -> PackedStringArray:
	return _split_patterns(_clean_pattern_text())


func _split_patterns(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part: String in text.split(","):
		if part.strip_edges() != "":
			out.append(part.strip_edges())
	return out


func _sort_key() -> int:
	var settings := EditorInterface.get_editor_settings()
	var key := int(settings.get_project_metadata(META_SECTION, "sort", UserDataOps.SORT_NAME))
	return key if UserDataOps.SORT_LABELS.has(key) else UserDataOps.SORT_NAME


func _auto_refresh_enabled() -> bool:
	return bool(EditorInterface.get_editor_settings().get_project_metadata(META_SECTION, "auto_refresh", false))


func _on_sort_selected(index: int) -> void:
	var key := sort_option.get_item_id(index)
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, "sort", key)
	_sort_cache.clear()
	if tree != null and tree.get_root() != null:
		UserDataOps.sort_children(tree.get_root(), key, _sort_cache)


func _on_auto_refresh_toggled(pressed: bool) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, "auto_refresh", pressed)
	if refresh_timer == null:
		return
	if pressed:
		_last_signature = UserDataOps.listing_signature()
		refresh_timer.start()
	else:
		refresh_timer.stop()


## Timer tick (1 s, only while Auto-refresh is on and the dialog is open).
## Rebuilds the tree, keeping the user's state, only when user:// changed.
func _on_auto_refresh_tick() -> void:
	if tree == null or confirmation_dialog == null or not confirmation_dialog.visible or _refreshing:
		return
	var signature := UserDataOps.listing_signature()
	if signature == _last_signature:
		return
	_rebuild_tree(true)


func _build_clean_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var check := CheckBox.new()
	check.text = "Clean on Play"
	check.tooltip_text = "Delete the matching user:// items every time you press Play (off by default)"
	check.button_pressed = _clean_enabled()
	check.toggled.connect(_on_clean_enabled_toggled)
	row.add_child(check)

	var edit := LineEdit.new()
	edit.placeholder_text = "test_runner/, *.tmp"
	edit.text = _clean_pattern_text()
	edit.tooltip_text = "Comma-separated, relative to user://: a path, a folder with a trailing /, or a * glob in the last segment (no **)"
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_changed.connect(_on_clean_patterns_changed)
	row.add_child(edit)

	clean_matches_label = Label.new()
	row.add_child(clean_matches_label)
	_update_clean_matches()

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	margin.add_child(row)
	return margin


func _on_clean_enabled_toggled(pressed: bool) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, "clean_on_play_enabled", pressed)


func _on_clean_patterns_changed(text: String) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, "clean_on_play_patterns", text)
	_update_clean_matches()


func _update_clean_matches() -> void:
	if clean_matches_label == null:
		return
	var patterns := _clean_patterns()
	var count := UserDataOps.clean_targets(patterns).size()
	var text := "%d item(s) match now" % count
	var invalid := UserDataOps.invalid_patterns(patterns)
	if not invalid.is_empty():
		text += " (ignored: %s)" % ", ".join(invalid)
	clean_matches_label.text = text


func _on_button_pressed() -> void:
	show_confirmation_dialog()


## Opens the main user data management dialog.
func show_confirmation_dialog() -> void:
	active_type_filters.clear()
	var base := EditorInterface.get_base_control()

	var cfg := ConfigFile.new()
	var plugin_version := ""
	if cfg.load("res://addons/manage_user_data/plugin.cfg") == OK:
		plugin_version = cfg.get_value("plugin", "version", "")

	confirmation_dialog = ConfirmationDialog.new()
	confirmation_dialog.title = "Manage User Directory Contents" + (" v" + plugin_version if plugin_version else "")
	confirmation_dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_SCREEN_WITH_MOUSE_FOCUS
	confirmation_dialog.size = Vector2i(1040, 600)
	confirmation_dialog.min_size = Vector2i(540, 420)
	confirmation_dialog.wrap_controls = true
	confirmation_dialog.get_cancel_button().text = "Close"
	confirmation_dialog.get_ok_button().text = "Delete Selected"
	confirmation_dialog.get_ok_button().icon = base.get_theme_icon("Remove", "EditorIcons")
	var _delete_icon_color := base.get_theme_color("error_color", "Editor")
	confirmation_dialog.get_ok_button().add_theme_color_override("icon_normal_color", _delete_icon_color)
	confirmation_dialog.get_ok_button().add_theme_color_override("icon_hover_color", _delete_icon_color)
	confirmation_dialog.get_ok_button().add_theme_color_override("icon_pressed_color", _delete_icon_color)
	confirmation_dialog.get_ok_button().add_theme_color_override("icon_focus_color", _delete_icon_color)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 0)

	# === SEARCH ROW ===
	var search_hbox := HBoxContainer.new()
	search_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_hbox.add_theme_constant_override("separation", 4)

	# Styled panel: dark background + accent-colored border, search icon on right
	var search_panel := PanelContainer.new()
	search_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var search_panel_style := StyleBoxFlat.new()
	var accent_color := base.get_theme_color("accent_color", "Editor")
	search_panel_style.bg_color = Color(0.08, 0.08, 0.08, 1.0)
	search_panel_style.border_color = accent_color
	search_panel_style.set_border_width_all(2)
	search_panel_style.set_corner_radius_all(4)
	search_panel_style.content_margin_left = 8
	search_panel_style.content_margin_right = 6
	search_panel_style.content_margin_top = 2
	search_panel_style.content_margin_bottom = 2
	search_panel.add_theme_stylebox_override("panel", search_panel_style)

	var search_inner_hbox := HBoxContainer.new()
	search_inner_hbox.add_theme_constant_override("separation", 4)
	search_panel.add_child(search_inner_hbox)

	search_text = LineEdit.new()
	search_text.placeholder_text = "Filter Settings"
	search_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_text.clear_button_enabled = false
	search_text.text_changed.connect(_on_search_changed)
	var le_transparent_style := StyleBoxEmpty.new()
	search_text.add_theme_stylebox_override("normal", le_transparent_style)
	search_text.add_theme_stylebox_override("focus", le_transparent_style)
	search_text.add_theme_stylebox_override("read_only", le_transparent_style)
	search_inner_hbox.add_child(search_text)

	var search_icon := TextureRect.new()
	search_icon.texture = base.get_theme_icon("Search", "EditorIcons")
	search_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	search_icon.custom_minimum_size = Vector2(20, 20)
	search_icon.modulate = Color.WHITE
	search_inner_hbox.add_child(search_icon)

	search_hbox.add_child(search_panel)

	filter_menu_button = MenuButton.new()
	filter_menu_button.text = "All Types"
	filter_menu_button.flat = false
	filter_menu_button.tooltip_text = "Filter by file type"
	var popup := filter_menu_button.get_popup()
	popup.hide_on_checkable_item_selection = false
	var filter_icons := {
		UserDataOps.FILTER_FOLDERS: "Folder",
		UserDataOps.FILTER_BACKUPS: "History",
		UserDataOps.FILTER_TEST_DATA: "Debug",
		UserDataOps.FILTER_LOGS: "Script",
	}
	for filter_id: int in UserDataOps.FILTER_LABELS:
		popup.add_check_item(UserDataOps.FILTER_LABELS[filter_id], filter_id)
		var idx := popup.get_item_index(filter_id)
		popup.set_item_icon(idx, base.get_theme_icon(filter_icons.get(filter_id, "File"), "EditorIcons"))
		if filter_id == UserDataOps.FILTER_FOLDERS:
			popup.set_item_icon_modulate(idx, Color(1, 0.71, 0.26, 1))
	popup.id_pressed.connect(_on_filter_type_toggled)
	search_hbox.add_child(filter_menu_button)
	_apply_outline_to_button(filter_menu_button, base)

	clear_filter_btn = Button.new()
	clear_filter_btn.icon = base.get_theme_icon("Close", "EditorIcons")
	clear_filter_btn.tooltip_text = "Clear filters"
	clear_filter_btn.pressed.connect(_on_clear_filters)
	clear_filter_btn.visible = false
	search_hbox.add_child(clear_filter_btn)
	_apply_outline_to_button(clear_filter_btn, base)

	var refresh_btn := Button.new()
	refresh_btn.icon = base.get_theme_icon("Reload", "EditorIcons")
	refresh_btn.tooltip_text = "Refresh"
	refresh_btn.flat = false
	refresh_btn.pressed.connect(_on_refresh_tree)
	search_hbox.add_child(refresh_btn)

	var help_btn := Button.new()
	help_btn.text = "?"
	help_btn.tooltip_text = "Help"
	help_btn.flat = false
	help_btn.pressed.connect(_on_help_pressed)
	search_hbox.add_child(help_btn)

	var search_margin := MarginContainer.new()
	search_margin.add_theme_constant_override("margin_left", 4)
	search_margin.add_theme_constant_override("margin_right", 4)
	search_margin.add_theme_constant_override("margin_top", 6)
	search_margin.add_theme_constant_override("margin_bottom", 6)
	search_margin.add_child(search_hbox)
	vbox.add_child(search_margin)

	vbox.add_child(HSeparator.new())

	# === TOOLBAR ROW (Gmail-style action bar: select-all + actions) ===
	var toolbar_hbox := HBoxContainer.new()
	toolbar_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar_hbox.add_theme_constant_override("separation", 6)

	var open_dir_btn := Button.new()
	open_dir_btn.text = "Open Folder"
	open_dir_btn.icon = base.get_theme_icon("Folder", "EditorIcons")
	open_dir_btn.add_theme_color_override("icon_normal_color", Color.hex(0xE0A55CFF))
	open_dir_btn.add_theme_color_override("icon_hover_color", Color.hex(0xE0A55CFF))
	open_dir_btn.add_theme_color_override("icon_pressed_color", Color.hex(0xE0A55CFF))
	open_dir_btn.add_theme_color_override("icon_focus_color", Color.hex(0xE0A55CFF))
	open_dir_btn.tooltip_text = "Open user:// directory in file explorer"
	open_dir_btn.flat = false
	open_dir_btn.pressed.connect(func() -> void:
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path("user://"))
	)
	toolbar_hbox.add_child(open_dir_btn)

	var copy_logs_btn := Button.new()
	copy_logs_btn.text = "Copy Logs"
	copy_logs_btn.icon = base.get_theme_icon("ActionCopy", "EditorIcons")
	copy_logs_btn.add_theme_color_override("icon_normal_color", Color.hex(0xE0A55CFF))
	copy_logs_btn.add_theme_color_override("icon_hover_color", Color.hex(0xE0A55CFF))
	copy_logs_btn.add_theme_color_override("icon_pressed_color", Color.hex(0xE0A55CFF))
	copy_logs_btn.add_theme_color_override("icon_focus_color", Color.hex(0xE0A55CFF))
	copy_logs_btn.tooltip_text = "Copy de-duplicated engine logs and errors to clipboard"
	copy_logs_btn.flat = false
	copy_logs_btn.pressed.connect(_on_copy_logs_pressed.bind(copy_logs_btn))
	toolbar_hbox.add_child(copy_logs_btn)

	var zip_btn := Button.new()
	zip_btn.text = "Zip Selected…"
	zip_btn.icon = base.get_theme_icon("Save", "EditorIcons")
	for state: String in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		zip_btn.add_theme_color_override(state, Color.hex(0xE0A55CFF))
	zip_btn.tooltip_text = "Save the checked, visible items as a .zip (for a bug report, or a snapshot before deleting)"
	zip_btn.flat = false
	zip_btn.pressed.connect(_on_zip_pressed.bind(zip_btn))
	toolbar_hbox.add_child(zip_btn)

	var restore_btn := Button.new()
	restore_btn.text = "Restore Zip…"
	restore_btn.icon = base.get_theme_icon("Load", "EditorIcons")
	for state: String in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		restore_btn.add_theme_color_override(state, Color.hex(0xE0A55CFF))
	restore_btn.tooltip_text = "Extract a .zip (e.g. from Zip Selected) into user://, after showing what it will overwrite"
	restore_btn.flat = false
	restore_btn.pressed.connect(_on_restore_pressed.bind(restore_btn))
	toolbar_hbox.add_child(restore_btn)

	sort_option = OptionButton.new()
	sort_option.tooltip_text = "Sort the tree (folders first). Only the order changes, never what is checked or deleted"
	sort_option.fit_to_longest_item = false
	for sort_id: int in UserDataOps.SORT_LABELS:
		sort_option.add_item(UserDataOps.SORT_LABELS[sort_id], sort_id)
	sort_option.select(sort_option.get_item_index(_sort_key()))
	sort_option.item_selected.connect(_on_sort_selected)
	toolbar_hbox.add_child(sort_option)

	auto_refresh_check = CheckBox.new()
	auto_refresh_check.text = "Auto-refresh"
	auto_refresh_check.tooltip_text = "While this dialog is open, rescan user:// every second and update the tree when something changed. Keeps your checks, folders, search, filters, sort and selection; new files start checked"
	auto_refresh_check.button_pressed = _auto_refresh_enabled()
	auto_refresh_check.toggled.connect(_on_auto_refresh_toggled)
	toolbar_hbox.add_child(auto_refresh_check)

	var toolbar_spacer := Control.new()
	toolbar_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar_hbox.add_child(toolbar_spacer)

	var toolbar_sep_v := VSeparator.new()
	toolbar_hbox.add_child(toolbar_sep_v)

	select_all_checkbox = CheckBox.new()
	select_all_checkbox.text = "Select All"
	select_all_checkbox.tooltip_text = "Select or deselect all visible items"
	select_all_checkbox.button_pressed = true
	select_all_checkbox.toggled.connect(_on_select_all_checkbox_toggled)
	toolbar_hbox.add_child(select_all_checkbox)
	_apply_outline_to_button(select_all_checkbox, base)

	var toolbar_margin := MarginContainer.new()
	toolbar_margin.add_theme_constant_override("margin_left", 4)
	toolbar_margin.add_theme_constant_override("margin_right", 4)
	toolbar_margin.add_theme_constant_override("margin_top", 4)
	toolbar_margin.add_theme_constant_override("margin_bottom", 4)
	toolbar_margin.add_child(toolbar_hbox)
	vbox.add_child(toolbar_margin)

	vbox.add_child(HSeparator.new())

	# === FILE TREE ===
	tree = Tree.new()
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.custom_minimum_size = Vector2(0, 280)
	tree.hide_root = false
	tree.hide_folding = false
	tree.set_columns(3)
	tree.set_column_title(0, "Name")
	tree.set_column_title(1, "Type / Size")
	tree.set_column_title(2, "Select")
	tree.set_column_titles_visible(true)
	tree.set_column_expand(0, true)
	tree.set_column_expand(1, true)
	tree.set_column_expand(2, false)
	tree.set_column_custom_minimum_width(0, 200)
	tree.set_column_custom_minimum_width(1, 110)
	tree.set_column_custom_minimum_width(2, 60)
	tree.set_column_expand_ratio(0, 5)
	tree.set_column_expand_ratio(1, 1)

	var root := tree.create_item()
	root.set_text(0, "user://")
	root.set_icon(0, base.get_theme_icon("Folder", "EditorIcons"))
	root.set_icon_modulate(0, Color(1, 0.71, 0.26, 1))
	root.set_text(1, "Directory")
	root.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
	root.set_checked(2, true)
	root.set_editable(2, true)
	var root_tooltip := "user://\nType: Directory\nPath: %s" % ProjectSettings.globalize_path("user://")
	root.set_tooltip_text(0, root_tooltip)
	root.set_tooltip_text(1, root_tooltip)

	populate_tree(root, "user://")
	_sort_cache.clear()
	UserDataOps.sort_children(root, _sort_key(), _sort_cache)
	_last_signature = UserDataOps.listing_signature()

	tree.item_edited.connect(_on_tree_item_edited)
	tree.item_mouse_selected.connect(_on_tree_item_mouse_selected)
	tree.item_selected.connect(_on_tree_item_selected)
	tree.allow_rmb_select = true
	tree.size_flags_stretch_ratio = 1.6

	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(tree)
	split.add_child(_build_preview_panel())
	vbox.add_child(split)

	vbox.add_child(HSeparator.new())
	vbox.add_child(_build_clean_row())
	vbox.add_child(HSeparator.new())

	# === STATUS / WARNING BAR ===
	warning_label = Label.new()
	warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warning_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	warning_label.autowrap_mode = TextServer.AUTOWRAP_OFF

	var status_margin := MarginContainer.new()
	status_margin.add_theme_constant_override("margin_left", 6)
	status_margin.add_theme_constant_override("margin_right", 6)
	status_margin.add_theme_constant_override("margin_top", 4)
	status_margin.add_theme_constant_override("margin_bottom", 4)
	status_margin.add_child(warning_label)
	vbox.add_child(status_margin)

	update_warning_label()

	confirmation_dialog.add_child(vbox)
	refresh_timer = Timer.new()
	refresh_timer.wait_time = 1.0
	refresh_timer.one_shot = false
	refresh_timer.timeout.connect(_on_auto_refresh_tick)
	confirmation_dialog.add_child(refresh_timer)
	if auto_refresh_check.button_pressed:
		refresh_timer.autostart = true
	confirmation_dialog.confirmed.connect(_on_confirmed_delete)
	confirmation_dialog.canceled.connect(_on_dialog_closed)
	confirmation_dialog.close_requested.connect(_on_dialog_closed)

	EditorInterface.get_base_control().add_child(confirmation_dialog)
	confirmation_dialog.popup_centered()


## Recursively populates the tree with the contents of [param path].
## Handles unreadable directories and corrupted/locked files gracefully.
func populate_tree(parent_item: TreeItem, path: String) -> void:
	var base := EditorInterface.get_base_control()
	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("Manage User Data: Cannot open directory '%s' (error %d)" % [path, DirAccess.get_open_error()])
		return

	dir.include_hidden = true
	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue

		var full_path := path.path_join(file_name)
		var item := tree.create_item(parent_item)
		item.set_metadata(1, full_path)

		item.set_text(0, file_name)
		item.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
		item.set_checked(2, true)
		item.set_editable(2, true)

		if dir.current_is_dir() and dir.is_link(file_name):
			# Never descend into a symlinked folder: it may point outside user://.
			item.set_text(1, "Link")
			item.set_icon(0, base.get_theme_icon("FileBroken", "EditorIcons"))
			item.set_tooltip_text(0, "%s
Type: Symbolic link (removed as a link, target untouched)
Path: %s" % [file_name, full_path])
		elif dir.current_is_dir():
			item.set_text(1, "Folder")
			item.set_icon(0, base.get_theme_icon("Folder", "EditorIcons"))
			item.set_icon_modulate(0, Color(1, 0.71, 0.26, 1))
			item.set_collapsed(false)
			var folder_tooltip := "%s\nType: Folder\nPath: %s" % [file_name, full_path]
			item.set_tooltip_text(0, folder_tooltip)
			item.set_tooltip_text(1, folder_tooltip)
			populate_tree(item, full_path)
		else:
			item.set_icon(0, get_file_icon(file_name))
			var file := FileAccess.open(full_path, FileAccess.READ)
			if file:
				var file_size := file.get_length()
				file.close()
				item.set_text(1, "File (%s)" % format_file_size(file_size))
				var file_tooltip := "%s\nType: %s\nSize: %s\nPath: %s" % [file_name, get_file_type_label(file_name), format_file_size(file_size), full_path]
				item.set_tooltip_text(0, file_tooltip)
				item.set_tooltip_text(1, file_tooltip)
			else:
				var err_code := FileAccess.get_open_error()
				var size_label := "unreadable (error %d)" % err_code
				item.set_text(1, "File (%s)" % size_label)
				var file_tooltip := "%s\nType: %s\nSize: %s\nPath: %s" % [file_name, get_file_type_label(file_name), size_label, full_path]
				item.set_tooltip_text(0, file_tooltip)
				item.set_tooltip_text(1, file_tooltip)
				push_warning("Manage User Data: Cannot read file '%s' (error %d)" % [full_path, err_code])

		file_name = dir.get_next()

	dir.list_dir_end()


## Builds the read-only Preview pane shown beside the tree.
func _build_preview_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.0
	panel.custom_minimum_size = Vector2(240, 0)

	var head := HBoxContainer.new()
	preview_header = Label.new()
	preview_header.text = "Preview"
	preview_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_header.clip_text = true
	preview_header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(preview_header)
	preview_copy_btn = Button.new()
	preview_copy_btn.text = "Copy"
	preview_copy_btn.tooltip_text = "Copy the previewed text"
	preview_copy_btn.disabled = true
	preview_copy_btn.pressed.connect(_on_preview_copy_pressed)
	head.add_child(preview_copy_btn)
	panel.add_child(head)

	preview_text = TextEdit.new()
	preview_text.editable = false
	preview_text.context_menu_enabled = false
	preview_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_text.placeholder_text = "Select a file to preview it"
	var mono: Font = EditorInterface.get_base_control().get_theme_font("source", "EditorFonts")
	if mono != null:
		preview_text.add_theme_font_override("font", mono)
	panel.add_child(preview_text)

	preview_image = TextureRect.new()
	preview_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_image.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_image.visible = false
	panel.add_child(preview_image)
	return panel


## Shows the selected row in the Preview pane. Read-only: it never touches the
## checkboxes or the files. See [code]UserDataOps.preview()[/code].
func _on_tree_item_selected() -> void:
	var item := tree.get_selected()
	if item == null or preview_text == null:
		return
	var meta: Variant = item.get_metadata(1)
	if not meta is String or meta == "":
		_show_preview("user://", {"kind": "folder", "text": "", "truncated": false, "bytes": 0, "error": ""})
		return
	var path: String = meta
	var result := UserDataOps.preview(path)
	_show_preview(path, result)


func _show_preview(path: String, result: Dictionary) -> void:
	var kind: String = result.kind
	var header := "%s  (%s, %s)" % [path.get_file() if path != "user://" else path, kind, format_file_size(int(result.bytes))]
	if result.truncated:
		header += " [truncated]"
	if result.error != "":
		header += " - " + String(result.error)
	preview_header.text = header
	preview_header.tooltip_text = header
	preview_image.visible = false
	preview_image.texture = null
	preview_text.visible = true
	var text: String = result.text
	if kind == "image":
		var image := Image.load_from_file(path)
		if image != null and not image.is_empty():
			preview_image.texture = ImageTexture.create_from_image(image)
			preview_image.visible = true
			preview_text.visible = false
			text = ""
			preview_header.text = "%s  (image %dx%d, %s)" % [
				path.get_file(), image.get_width(), image.get_height(), format_file_size(int(result.bytes))
			]
		else:
			text = "(cannot decode this image)"
	elif kind == "missing":
		text = "(file no longer exists)"
	elif kind == "refused":
		text = "(not previewed)"
	preview_text.text = text
	preview_copy_btn.disabled = text == "" or preview_image.visible


func _on_preview_copy_pressed() -> void:
	DisplayServer.clipboard_set(preview_text.text)
	_show_copy_feedback(preview_copy_btn, "Copied")


## Handles checkbox edits and propagates the new state to all child items.
func _on_tree_item_edited() -> void:
	var edited_item := tree.get_edited()
	if edited_item == null:
		return
	propagate_check_state(edited_item, edited_item.is_checked(2))
	update_warning_label()


## Toggles expand/collapse when a folder item is clicked in the name or type column.
func _on_tree_item_mouse_selected(mouse_position: Vector2, mouse_button_index: int) -> void:
	var item := tree.get_item_at_position(mouse_position)
	if item == null:
		return
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		_show_context_menu(item, mouse_position)
		return
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	var item_type_text := item.get_text(1)
	var is_folder: bool = item_type_text.begins_with("Folder") or item_type_text == "Directory"
	if not is_folder:
		return
	if item.get_first_child() == null:
		return
	var col := tree.get_column_at_position(mouse_position)
	if col == 2:
		return
	item.set_collapsed(not item.is_collapsed())


## Path of a tree row; the root row (no metadata) is user://.
func _row_path(item: TreeItem) -> String:
	var meta: Variant = item.get_metadata(1)
	return meta if meta is String and meta != "" else UserDataOps.ROOT_PATH


const _CONTEXT_LABELS := {
	UserDataOps.ACTION_COPY_PATH: "Copy path",
	UserDataOps.ACTION_COPY_ABSOLUTE: "Copy absolute path",
	UserDataOps.ACTION_SHOW: "Show in file manager",
	UserDataOps.ACTION_ONLY_THIS: "Only this",
	UserDataOps.ACTION_CHECK_FOLDER: "Check all in this folder",
	UserDataOps.ACTION_UNCHECK_FOLDER: "Uncheck all in this folder",
	UserDataOps.ACTION_DELETE: "Delete this…",
}


## Right-click menu for a row. Which entries are enabled comes from
## UserDataOps.context_actions; this only maps ids to menu items.
func _show_context_menu(item: TreeItem, mouse_position: Vector2) -> void:
	if is_instance_valid(context_menu):
		context_menu.queue_free()
	_context_item_path = _row_path(item)
	var enabled := UserDataOps.context_actions(_context_item_path, UserDataOps.is_folder_item(item))
	context_menu = PopupMenu.new()
	var is_folder := UserDataOps.is_folder_item(item)
	for action: String in _CONTEXT_LABELS:
		if not is_folder and (action == UserDataOps.ACTION_CHECK_FOLDER or action == UserDataOps.ACTION_UNCHECK_FOLDER):
			continue
		if action == UserDataOps.ACTION_ONLY_THIS or action == UserDataOps.ACTION_DELETE:
			context_menu.add_separator()
		context_menu.add_item(_CONTEXT_LABELS[action])
		var last := context_menu.item_count - 1
		context_menu.set_item_metadata(last, action)
		context_menu.set_item_disabled(last, not enabled.has(action))
	context_menu.id_pressed.connect(_on_context_id_pressed.bind(item))
	context_menu.popup_hide.connect(context_menu.queue_free)
	confirmation_dialog.add_child(context_menu)
	context_menu.position = Vector2i(tree.get_screen_position() + mouse_position)
	context_menu.popup()


func _on_context_id_pressed(id: int, item: TreeItem) -> void:
	if not is_instance_valid(context_menu) or not is_instance_valid(item):
		return
	var index := context_menu.get_item_index(id)
	var action: String = context_menu.get_item_metadata(index)
	var path := _row_path(item)
	# Re-check against the ops rules at click time, not just when the menu opened.
	if not UserDataOps.context_actions(path, UserDataOps.is_folder_item(item)).has(action):
		return
	match action:
		UserDataOps.ACTION_COPY_PATH:
			DisplayServer.clipboard_set(path)
		UserDataOps.ACTION_COPY_ABSOLUTE:
			DisplayServer.clipboard_set(UserDataOps.absolute_path(path))
		UserDataOps.ACTION_SHOW:
			OS.shell_show_in_file_manager(UserDataOps.absolute_path(path))
		UserDataOps.ACTION_ONLY_THIS:
			UserDataOps.only_this(tree.get_root(), item)
			update_warning_label()
		UserDataOps.ACTION_CHECK_FOLDER:
			UserDataOps.set_subtree_checked(item, true)
			update_warning_label()
		UserDataOps.ACTION_UNCHECK_FOLDER:
			UserDataOps.set_subtree_checked(item, false)
			update_warning_label()
		UserDataOps.ACTION_DELETE:
			_confirm_delete_one(path)


## Names the path and what it holds, then deletes only that item through
## UserDataOps.delete_paths after the user confirms.
func _confirm_delete_one(path: String) -> void:
	if not UserDataOps.is_safe_target(path):
		return
	var info := UserDataOps.describe([path])
	var detail := "%d file(s), %d folder(s), %s" % [info.files, info.folders, format_file_size(int(info.bytes))]
	if is_instance_valid(delete_one_dialog):
		delete_one_dialog.queue_free()
	delete_one_dialog = ConfirmationDialog.new()
	delete_one_dialog.title = "Delete this item?"
	delete_one_dialog.ok_button_text = "Delete"
	delete_one_dialog.dialog_text = "Permanently delete %s ?\n\n%s\n\nThis cannot be undone." % [path, detail]
	delete_one_dialog.confirmed.connect(func() -> void:
		var typed: Array[String] = [path]
		var result := UserDataOps.delete_paths(typed)
		if not result.failed.is_empty():
			push_warning("Manage User Data: could not delete '%s'." % path)
		# Keep every other row's check state: re-checking everything here
		# would let the next Delete Selected remove rows the user unchecked.
		if tree != null:
			_rebuild_tree(true)
			_update_select_all_checkbox()
			update_warning_label()
	)
	delete_one_dialog.canceled.connect(delete_one_dialog.queue_free)
	delete_one_dialog.confirmed.connect(delete_one_dialog.queue_free)
	confirmation_dialog.add_child(delete_one_dialog)
	delete_one_dialog.popup_centered()


## Recursively applies [param checked] to all children of [param item].
func propagate_check_state(item: TreeItem, checked: bool) -> void:
	var child := item.get_first_child()
	while child != null:
		child.set_checked(2, checked)
		propagate_check_state(child, checked)
		child = child.get_next()


func _on_select_all_checkbox_toggled(checked: bool) -> void:
	var root := tree.get_root()
	if root:
		# Only visible rows: rows a search or filter hides keep their state.
		UserDataOps.set_visible_checked(root, checked)
		update_warning_label()


## Syncs the select-all checkbox visual state to reflect current tree selection.
func _update_select_all_checkbox() -> void:
	if select_all_checkbox == null or tree == null:
		return
	var root := tree.get_root()
	if root == null:
		return
	var counts := [0, 0]  # [total, checked]
	_count_tree_items(root, counts)
	select_all_checkbox.set_block_signals(true)
	if counts[1] == 0:
		select_all_checkbox.button_pressed = false
		if "indeterminate" in select_all_checkbox:
			select_all_checkbox.set("indeterminate", false)
	elif counts[1] == counts[0]:
		select_all_checkbox.button_pressed = true
		if "indeterminate" in select_all_checkbox:
			select_all_checkbox.set("indeterminate", false)
	else:
		select_all_checkbox.button_pressed = false
		if "indeterminate" in select_all_checkbox:
			select_all_checkbox.set("indeterminate", true)
	select_all_checkbox.set_block_signals(false)


## Counts total and checked tree items recursively into [param counts] ([total, checked]).
func _count_tree_items(item: TreeItem, counts: Array) -> void:
	if not item.visible:
		return
	counts[0] += 1
	if item.is_checked(2):
		counts[1] += 1
	var child := item.get_first_child()
	while child != null:
		_count_tree_items(child, counts)
		child = child.get_next()


## Clears and repopulates the tree to reflect the current state of user://.
## Everything is checked again (as on first open); the sort and the active
## search and filters are re-applied.
func _on_refresh_tree() -> void:
	if tree == null or _refreshing:
		return
	_refreshing = true

	var tween_out := create_tween()
	tween_out.tween_property(tree, "modulate:a", 0.0, 0.15)
	await tween_out.finished

	if tree == null:
		_refreshing = false
		return
	_rebuild_tree(false)

	var tween_in := create_tween()
	tween_in.tween_property(tree, "modulate:a", 1.0, 0.2)
	_refreshing = false


## Rebuilds the tree from disk, then sorts and re-applies the search and type
## filters (so rows a filter hides stay hidden and are never deleted).
## With [param keep_state] (auto-refresh) it also restores each row's check
## state and collapsed state by path and the selected row; a file that appeared
## since takes its folder's check state (see UserDataOps.restore_state). Without it, every row starts checked.
func _rebuild_tree(keep_state: bool) -> void:
	var state := {}
	var selected_path := ""
	if keep_state and tree.get_root() != null:
		state = UserDataOps.capture_state(tree.get_root())
		var selected := tree.get_selected()
		if selected != null and selected.get_metadata(1) is String:
			selected_path = selected.get_metadata(1)

	tree.clear()
	_update_clean_matches()

	var base := EditorInterface.get_base_control()
	var root := tree.create_item()
	root.set_text(0, "user://")
	root.set_icon(0, base.get_theme_icon("Folder", "EditorIcons"))
	root.set_icon_modulate(0, Color(1, 0.71, 0.26, 1))
	root.set_text(1, "Directory")
	root.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
	root.set_checked(2, true)
	root.set_editable(2, true)
	var root_tooltip := "user://\nType: Directory\nPath: %s" % ProjectSettings.globalize_path("user://")
	root.set_tooltip_text(0, root_tooltip)
	root.set_tooltip_text(1, root_tooltip)

	populate_tree(root, "user://")
	if keep_state:
		UserDataOps.restore_state(root, state)
	_sort_cache.clear()
	UserDataOps.sort_children(root, _sort_key(), _sort_cache)
	UserDataOps.filter_tree(root, search_text.text.to_lower() if search_text else "", active_type_filters)
	_last_signature = UserDataOps.listing_signature()
	if selected_path != "":
		var item := UserDataOps.find_item_by_path(root, selected_path)
		if item != null and item.visible:
			item.select(0)
			tree.scroll_to_item(item)
	update_warning_label()
	_update_select_all_checkbox()


## Updates the warning label to reflect the current selection.
func update_warning_label() -> void:
	if warning_label == null:
		return

	# Describe exactly what delete_selected_items() would remove.
	var items_to_delete := UserDataOps.plan_deletion(tree.get_root())
	var stats := UserDataOps.describe(items_to_delete)
	var file_count_ref := [stats.files]
	var folder_count_ref := [stats.folders]
	var total_size_ref := [stats.bytes]

	var base := EditorInterface.get_base_control()

	if items_to_delete.is_empty():
		warning_label.text = "No items selected."
		warning_label.add_theme_color_override(
			"font_color", base.get_theme_color("font_disabled_color", "Editor")
		)
	else:
		var items_text: String
		if file_count_ref[0] > 0 and folder_count_ref[0] > 0:
			items_text = "%d files, %d folders" % [file_count_ref[0], folder_count_ref[0]]
		elif file_count_ref[0] > 0:
			items_text = "%d file(s)" % file_count_ref[0]
		else:
			items_text = "%d folder(s)" % folder_count_ref[0]

		warning_label.text = (
			"%s selected (%s) \u2014 deletion cannot be undone"
			% [items_text, format_file_size(total_size_ref[0])]
		)
		warning_label.add_theme_color_override(
			"font_color", base.get_theme_color("error_color", "Editor")
		)

	_update_select_all_checkbox()


## Returns the total byte size of all files under [param path], recursively.
## Skips unreadable files/directories and does not follow symlinks.
func calculate_folder_size(path: String) -> int:
	return UserDataOps.calculate_folder_size(path)


func _on_search_changed(_new_text: String) -> void:
	_update_clear_button_visibility()
	apply_filters()


func _on_filter_type_toggled(id: int) -> void:
	var popup := filter_menu_button.get_popup()
	var idx := popup.get_item_index(id)
	var currently_checked := popup.is_item_checked(idx)
	popup.set_item_checked(idx, not currently_checked)

	if not currently_checked:
		if not active_type_filters.has(id):
			active_type_filters.append(id)
	else:
		active_type_filters.erase(id)

	_update_filter_button_label()
	_update_clear_button_visibility()
	apply_filters()


func _update_filter_button_label() -> void:
	if filter_menu_button == null:
		return
	if active_type_filters.is_empty():
		filter_menu_button.text = "All Types"
	elif active_type_filters.size() == 1:
		var popup := filter_menu_button.get_popup()
		var idx := popup.get_item_index(active_type_filters[0])
		filter_menu_button.text = popup.get_item_text(idx)
	else:
		filter_menu_button.text = "%d Types" % active_type_filters.size()


## Shows the Clear button only when a type filter other than "All" is active
## (i.e. at least one specific type is selected), satisfying the requirement
## of "more than 1 filter or a filter beside All".
func _update_clear_button_visibility() -> void:
	if clear_filter_btn == null:
		return
	clear_filter_btn.visible = not active_type_filters.is_empty()


func _on_clear_filters() -> void:
	search_text.text = ""
	active_type_filters.clear()
	var popup := filter_menu_button.get_popup()
	for i in popup.item_count:
		popup.set_item_checked(i, false)
	_update_filter_button_label()
	_update_clear_button_visibility()
	apply_filters()


## Applies the active search text and type filters to the entire tree.
func apply_filters() -> void:
	var search_term := search_text.text.to_lower()
	filter_tree_item(tree.get_root(), search_term, active_type_filters)
	if not active_type_filters.is_empty() or not search_term.is_empty():
		expand_matching_parents(tree.get_root())


## Recursively filters tree items. Returns [code]true[/code] if the item or
## any descendant matches the active filters. See [code]UserDataOps.filter_tree()[/code].
func filter_tree_item(item: TreeItem, search_term: String, filter_types: Array[int]) -> bool:
	return UserDataOps.filter_tree(item, search_term, filter_types)


## Expands folders that contain at least one visible child after filtering.
func expand_matching_parents(item: TreeItem) -> void:
	if item == null:
		return

	if UserDataOps.is_folder_item(item) and item.visible:
		var child := item.get_first_child()
		while child != null:
			if child.visible:
				item.set_collapsed(false)
				break
			child = child.get_next()

	var child := item.get_first_child()
	while child != null:
		expand_matching_parents(child)
		child = child.get_next()


## Returns an editor icon for a file based on its extension.
func get_file_icon(file_name: String) -> Texture2D:
	var base := EditorInterface.get_base_control()
	var ext := file_name.get_extension().to_lower()
	match ext:
		"json":
			return base.get_theme_icon("File", "EditorIcons")
		"cfg", "ini", "toml":
			return base.get_theme_icon("FileTree", "EditorIcons")
		"png", "jpg", "jpeg", "webp", "bmp", "svg":
			return base.get_theme_icon("ImageTexture", "EditorIcons")
		"wav":
			return base.get_theme_icon("AudioStreamWAV", "EditorIcons")
		"ogg":
			return base.get_theme_icon("AudioStreamOggVorbis", "EditorIcons")
		"mp3":
			return base.get_theme_icon("AudioStreamMP3", "EditorIcons")
		"tscn":
			return base.get_theme_icon("PackedScene", "EditorIcons")
		"tres":
			return base.get_theme_icon("Resource", "EditorIcons")
		"gd":
			return base.get_theme_icon("GDScript", "EditorIcons")
		"cache":
			return base.get_theme_icon("File", "EditorIcons")
		"save", "dat":
			return base.get_theme_icon("Save", "EditorIcons")
		"bak", "tmp":
			return base.get_theme_icon("History", "EditorIcons")
		"log", "jsonl":
			return base.get_theme_icon("Script", "EditorIcons")
		_:
			return base.get_theme_icon("File", "EditorIcons")


## Returns a human-readable type label for a file based on its extension.
func get_file_type_label(file_name: String) -> String:
	return UserDataOps.get_file_type_label(file_name)


## Returns a human-readable string for the given byte count.
func format_file_size(bytes: int) -> String:
	return UserDataOps.format_file_size(bytes)


func _on_help_pressed() -> void:
	if help_dialog:
		help_dialog.grab_focus()
		return

	var base := EditorInterface.get_base_control()

	var cfg := ConfigFile.new()
	var plugin_version := "2.4.6"
	if cfg.load("res://addons/manage_user_data/plugin.cfg") == OK:
		plugin_version = cfg.get_value("plugin", "version", plugin_version)

	help_dialog = AcceptDialog.new()
	help_dialog.ok_button_text = "Close"
	help_dialog.title = "Help — Manage User Data"
	help_dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_SCREEN_WITH_MOUSE_FOCUS
	help_dialog.size = Vector2i(780, 580)
	help_dialog.min_size = Vector2i(540, 420)
	help_dialog.wrap_controls = true
	help_dialog.exclusive = false

	var outer_vbox := VBoxContainer.new()
	outer_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_vbox.add_theme_constant_override("separation", 0)

	# === HEADER ===
	var header_hbox := HBoxContainer.new()
	header_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	header_hbox.add_theme_constant_override("separation", 10)

	var plugin_icon := TextureRect.new()
	plugin_icon.texture = base.get_theme_icon("Filesystem", "EditorIcons")
	plugin_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	plugin_icon.custom_minimum_size = Vector2(36, 36)
	header_hbox.add_child(plugin_icon)

	var header_vbox := VBoxContainer.new()
	header_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_vbox.add_theme_constant_override("separation", 2)

	var title_label := Label.new()
	title_label.text = "Manage User Data"
	title_label.add_theme_font_size_override("font_size", title_label.get_theme_font_size("font_size") + 6)
	header_vbox.add_child(title_label)

	var subtitle_label := Label.new()
	subtitle_label.text = "v%s  ·  by Lost Rabbit Digital" % plugin_version
	subtitle_label.add_theme_color_override("font_color", base.get_theme_color("font_disabled_color", "Editor"))
	header_vbox.add_child(subtitle_label)

	header_hbox.add_child(header_vbox)

	var header_margin := MarginContainer.new()
	header_margin.add_theme_constant_override("margin_left", 10)
	header_margin.add_theme_constant_override("margin_right", 10)
	header_margin.add_theme_constant_override("margin_top", 10)
	header_margin.add_theme_constant_override("margin_bottom", 10)
	header_margin.add_child(header_hbox)
	outer_vbox.add_child(header_margin)
	outer_vbox.add_child(HSeparator.new())

	# === SCROLLABLE CONTENT ===
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var content_vbox := VBoxContainer.new()
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_vbox.add_theme_constant_override("separation", 10)

	var content_margin := MarginContainer.new()
	content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_margin.add_theme_constant_override("margin_left", 12)
	content_margin.add_theme_constant_override("margin_right", 12)
	content_margin.add_theme_constant_override("margin_top", 10)
	content_margin.add_theme_constant_override("margin_bottom", 10)
	content_margin.add_child(content_vbox)
	scroll.add_child(content_margin)

	# --- Shared helpers ---
	var _add_heading := func(text: String) -> void:
		var lbl := Label.new()
		lbl.text = text
		lbl.add_theme_font_size_override("font_size", lbl.get_theme_font_size("font_size") + 1)
		lbl.add_theme_color_override("font_color", base.get_theme_color("accent_color", "Editor"))
		content_vbox.add_child(lbl)
		content_vbox.add_child(HSeparator.new())

	var _add_body := func(text: String) -> void:
		var lbl := Label.new()
		lbl.text = text
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content_vbox.add_child(lbl)

	# --- Overview ---
	_add_heading.call("Overview")
	_add_body.call(
		"Manage User Data lets you browse and selectively delete files from your project's " +
		"user:// directory — without leaving the editor."
	)

	# --- How to Use ---
	_add_heading.call("How to Use")

	var steps: Array = [
		["1.  Open the plugin", "Click \"User Data\" in the editor toolbar to open the main window."],
		["2.  Browse files", "The tree lists every file and folder inside user://. Folders are shown expanded by default."],
		["3.  Select items", "To delete everything: leave all items checked. To delete specific files: uncheck \"Select All\", then tick only what you want."],
		["4.  Search & filter", "Type in the search bar to find items by name. Use the \"All Types\" dropdown to show only files, folders, .json, .cache, backups and temp files, test-runner data, or logs. Only visible items are ever deleted, so a filter also narrows what Delete removes."],
		["5.  Review", "The status bar shows a live count and total size of your selection before you commit."],
		["6.  Delete", "Click \"Delete Selected\" and confirm. Deletion is permanent and cannot be undone."],
	]

	var steps_grid := VBoxContainer.new()
	steps_grid.add_theme_constant_override("separation", 6)
	for step: Array in steps:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var step_name := Label.new()
		step_name.text = step[0]
		step_name.custom_minimum_size = Vector2(150, 0)
		step_name.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		row.add_child(step_name)

		var step_desc := Label.new()
		step_desc.text = step[1]
		step_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		step_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(step_desc)

		steps_grid.add_child(row)
	content_vbox.add_child(steps_grid)

	# --- Features ---
	_add_heading.call("Features")

	var features: Array = [
		["File Tree", "Full visual tree of user:// with per-item checkboxes for fine-grained selection."],
		["Real-time Search", "Instantly filters the tree as you type — matching parent folders expand automatically."],
		["Type Filters", "Narrow the view (and what Delete removes) to files, folders, .json, .cache, save backups and temp files (.bak, .tmp), test-runner data (user://test_runner/), or logs (.log, .jsonl)."],
		["Bulk Selection", "\"Select All\" selects or deselects every visible item in one click."],
		["File Sizes", "Inline file sizes on every entry; the status bar totals the size of your current selection."],
		["Open in OS", "\"Open Folder\" launches user:// in your operating system's native file manager."],
		["Copy Logs", "Copy the contents of every log file in user://logs/ to your clipboard in one click."],
		["Preview", "Click a file to read it beside the tree: JSON pretty-printed (.jsonl shows its first rows), text, a hex dump for binary files, a thumbnail for images, a size summary for folders. Read-only, capped at 64 KB, and it never changes your selection."],
		["Zip Selected", "Save the checked, visible items as one .zip, paths kept relative to user://: attach it to a bug report, or keep a snapshot before deleting."],
		["Restore Zip", "Extract such a .zip back into user://. Shows how many files it will write and overwrite first; entries that would land outside user:// are skipped."],
		["Clean on Play", "Optionally delete chosen user:// items (paths, folders with a trailing /, or * globs such as *.tmp) every time you press Play, so stale test data does not leak between runs. Off by default; the row below the tree shows how many items match now."],
		["De-dupe Logs", "Copy godot.log with duplicate lines collapsed into \"(×N)\" summaries for compact sharing."],
		["Right-click menu", "Right-click a row: Copy path, Copy absolute path, Show in file manager, Only this (checks just that row and what is inside it, handy before Delete or Zip), Check/Uncheck all in this folder, and Delete this… (asks first). The user:// root offers only the copy and show entries."],
		["Sort", "Order the tree by name, size (largest first) or modified time (newest first). Folders always stay first and only the order changes, never what is checked or deleted. Remembered per project."],
		["Auto-refresh", "While the dialog is open, rescans user:// every second and updates the tree when something changed, keeping your checks, expanded folders, search, filters, sort and selected row. New files start checked, as on first open. Off by default; remembered per project."],
		["Refresh", "Rescans user:// at any time without reopening the plugin window."],
	]

	var features_grid := VBoxContainer.new()
	features_grid.add_theme_constant_override("separation", 6)
	for feat: Array in features:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var bullet := TextureRect.new()
		bullet.texture = base.get_theme_icon("ArrowRight", "EditorIcons")
		bullet.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		bullet.custom_minimum_size = Vector2(16, 16)
		row.add_child(bullet)

		var feat_name := Label.new()
		feat_name.text = feat[0]
		feat_name.custom_minimum_size = Vector2(130, 0)
		feat_name.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		row.add_child(feat_name)

		var feat_desc := Label.new()
		feat_desc.text = feat[1]
		feat_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		feat_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(feat_desc)

		features_grid.add_child(row)
	content_vbox.add_child(features_grid)

	# --- What's in user:// ---
	_add_heading.call("What's in user://")
	_add_body.call(
		"Godot writes to user:// when your game uses paths like \"user://save.json\". " +
		"Common files to clean during development:"
	)

	var user_types: Array = [
		[".cfg / .json", "Save data"],
		[".log", "Log files"],
		[".cache", "Engine/game caches"],
	]

	var user_types_grid := VBoxContainer.new()
	user_types_grid.add_theme_constant_override("separation", 6)
	for entry: Array in user_types:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var ext_lbl := Label.new()
		ext_lbl.text = entry[0]
		ext_lbl.custom_minimum_size = Vector2(130, 0)
		ext_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		row.add_child(ext_lbl)

		var src_lbl := Label.new()
		src_lbl.text = entry[1]
		src_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		src_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(src_lbl)

		user_types_grid.add_child(row)
	content_vbox.add_child(user_types_grid)

	# --- Tips ---
	_add_heading.call("Tips & Notes")
	_add_body.call(
		"\u2022  Deletion is permanent — double-check your selection before confirming.\n" +
		"\u2022  Checking a folder selects all of its contents recursively.\n" +
		"\u2022  The user:// path on disk:\n" +
		"       Windows:  %%APPDATA%%\\Godot\\app_userdata\\<project>\n" +
		"       macOS:    ~/Library/Application Support/Godot/app_userdata/<project>\n" +
		"       Linux:    ~/.local/share/godot/app_userdata/<project>"
	)

	outer_vbox.add_child(scroll)
	outer_vbox.add_child(HSeparator.new())

	# === LINKS FOOTER ===
	var links_hbox := HBoxContainer.new()
	links_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	links_hbox.add_theme_constant_override("separation", 8)

	var _make_outline_style := func(bg_alpha: float) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		var accent := base.get_theme_color("accent_color", "Editor")
		s.bg_color = Color(accent.r, accent.g, accent.b, bg_alpha)
		s.border_color = accent
		s.set_border_width_all(1)
		s.corner_radius_top_left = 4
		s.corner_radius_top_right = 4
		s.corner_radius_bottom_left = 4
		s.corner_radius_bottom_right = 4
		s.content_margin_left = 10
		s.content_margin_right = 10
		s.content_margin_top = 4
		s.content_margin_bottom = 4
		return s

	var credit_btn := Button.new()
	credit_btn.text = "Lost Rabbit Digital"
	credit_btn.icon = base.get_theme_icon("ExternalLink", "EditorIcons")
	credit_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	credit_btn.tooltip_text = "https://lostrabbit.digital/"
	credit_btn.add_theme_stylebox_override("normal", _make_outline_style.call(0.0))
	credit_btn.add_theme_stylebox_override("hover", _make_outline_style.call(0.12))
	credit_btn.add_theme_stylebox_override("pressed", _make_outline_style.call(0.22))
	credit_btn.add_theme_stylebox_override("focus", _make_outline_style.call(0.0))
	credit_btn.pressed.connect(func() -> void:
		OS.shell_open("https://lostrabbit.digital/")
	)
	links_hbox.add_child(credit_btn)

	links_hbox.add_child(VSeparator.new())

	var discord_btn := Button.new()
	discord_btn.text = "Discord Community"
	discord_btn.icon = base.get_theme_icon("ExternalLink", "EditorIcons")
	discord_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	discord_btn.tooltip_text = "https://discord.gg/Y7caBf7gBj"
	discord_btn.add_theme_stylebox_override("normal", _make_outline_style.call(0.0))
	discord_btn.add_theme_stylebox_override("hover", _make_outline_style.call(0.12))
	discord_btn.add_theme_stylebox_override("pressed", _make_outline_style.call(0.22))
	discord_btn.add_theme_stylebox_override("focus", _make_outline_style.call(0.0))
	discord_btn.pressed.connect(func() -> void:
		OS.shell_open("https://discord.gg/Y7caBf7gBj")
	)
	links_hbox.add_child(discord_btn)

	links_hbox.add_child(VSeparator.new())

	var github_btn := Button.new()
	github_btn.text = "GitHub Repo"
	github_btn.icon = base.get_theme_icon("ExternalLink", "EditorIcons")
	github_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	github_btn.tooltip_text = "https://github.com/Lost-Rabbit-Digital/manage_user_data_plugin"
	github_btn.add_theme_stylebox_override("normal", _make_outline_style.call(0.0))
	github_btn.add_theme_stylebox_override("hover", _make_outline_style.call(0.12))
	github_btn.add_theme_stylebox_override("pressed", _make_outline_style.call(0.22))
	github_btn.add_theme_stylebox_override("focus", _make_outline_style.call(0.0))
	github_btn.pressed.connect(func() -> void:
		OS.shell_open("https://github.com/Lost-Rabbit-Digital/manage_user_data_plugin")
	)
	links_hbox.add_child(github_btn)

	var links_margin := MarginContainer.new()
	links_margin.add_theme_constant_override("margin_left", 8)
	links_margin.add_theme_constant_override("margin_right", 8)
	links_margin.add_theme_constant_override("margin_top", 4)
	links_margin.add_theme_constant_override("margin_bottom", 4)
	links_margin.add_child(links_hbox)
	outer_vbox.add_child(links_margin)

	help_dialog.add_child(outer_vbox)
	EditorInterface.get_base_control().add_child(help_dialog)
	help_dialog.popup_centered()

	var _close_help := func() -> void:
		if help_dialog:
			help_dialog.queue_free()
			help_dialog = null
	help_dialog.confirmed.connect(_close_help)
	help_dialog.canceled.connect(_close_help)
	help_dialog.close_requested.connect(_close_help)


func _on_confirmed_delete() -> void:
	var result := delete_selected_items()
	if not result.failed.is_empty():
		push_warning("Manage User Data: %d item(s) could not be deleted." % result.failed.size())
	# Keep every other row's check state: the manual Refresh re-checks
	# everything, which would make the next Delete Selected remove rows the
	# user unchecked.
	if tree != null:
		_rebuild_tree(true)
		_update_select_all_checkbox()
		update_warning_label()
	confirmation_dialog.call_deferred("popup_centered")


func _on_dialog_closed() -> void:
	if help_dialog:
		help_dialog.queue_free()
		help_dialog = null
	if confirmation_dialog:
		confirmation_dialog.queue_free()
		confirmation_dialog = null
		select_all_checkbox = null
		context_menu = null
		delete_one_dialog = null
		preview_header = null
		preview_text = null
		preview_image = null
		preview_copy_btn = null
		filter_menu_button = null
		clear_filter_btn = null
		clean_matches_label = null
		sort_option = null
		auto_refresh_check = null
		refresh_timer = null
		active_type_filters.clear()


## Deletes what the current selection covers: only checked, visible items, and
## a folder wholesale only when everything under it is checked and visible
## (see user_data_ops.gd). Returns {"deleted": int, "failed": Array[String]}.
func delete_selected_items() -> Dictionary:
	return UserDataOps.delete_paths(UserDataOps.plan_deletion(tree.get_root()))


## Applies a visible border/outline to [param btn] using the editor accent color.
## Duplicates the existing button StyleBoxFlat if available; otherwise creates one.
func _apply_outline_to_button(btn: Button, base: Control) -> void:
	var existing_style := base.get_theme_stylebox("normal", "Button")
	var style: StyleBoxFlat
	if existing_style is StyleBoxFlat:
		style = (existing_style as StyleBoxFlat).duplicate()
		style.set_border_width_all(1)
		style.border_color = base.get_theme_color("accent_color", "Editor")
	else:
		style = StyleBoxFlat.new()
		style.bg_color = Color(0.18, 0.18, 0.18, 1.0)
		style.set_border_width_all(1)
		style.border_color = base.get_theme_color("accent_color", "Editor")
		style.set_corner_radius_all(3)
		style.content_margin_left = 6
		style.content_margin_right = 6
		style.content_margin_top = 4
		style.content_margin_bottom = 4
	btn.add_theme_stylebox_override("normal", style)


## Reads the Godot engine log file, de-duplicates lines, and copies the result
## to the clipboard. Shows brief feedback on the button.
## Handles corrupted or excessively large log files gracefully.
func _on_copy_logs_pressed(btn: Button) -> void:
	var log_path := "user://logs/godot.log"
	if not FileAccess.file_exists(log_path):
		DisplayServer.clipboard_set("")
		_show_copy_feedback(btn, "No log file found")
		return

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		DisplayServer.clipboard_set("")
		_show_copy_feedback(btn, "Failed to read logs")
		return

	# Guard against excessively large log files (>50 MB)
	var log_size := file.get_length()
	if log_size > 50 * 1024 * 1024:
		file.close()
		DisplayServer.clipboard_set("")
		_show_copy_feedback(btn, "Log too large (%s)" % format_file_size(log_size))
		return

	var seen := {}
	var unique_lines: PackedStringArray = []
	while not file.eof_reached():
		var line := file.get_line()
		if line.strip_edges() == "":
			continue
		if not seen.has(line):
			seen[line] = true
			unique_lines.append(line)
	file.close()

	if unique_lines.is_empty():
		DisplayServer.clipboard_set("")
		_show_copy_feedback(btn, "Logs empty")
		return

	DisplayServer.clipboard_set("\n".join(unique_lines))
	_show_copy_feedback(btn, "Copied!")


## Asks where to save, then zips what the selection covers (the same set
## Delete would remove; see UserDataOps.zip_paths).
func _on_zip_pressed(btn: Button) -> void:
	var paths := UserDataOps.selected_paths(tree.get_root())
	if paths.is_empty():
		_show_copy_feedback(btn, "Nothing selected")
		return
	var picker := EditorFileDialog.new()
	picker.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	picker.access = EditorFileDialog.ACCESS_FILESYSTEM
	picker.add_filter("*.zip", "Zip archive")
	picker.title = "Save user data as .zip"
	picker.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	picker.current_file = UserDataOps.default_zip_name(str(ProjectSettings.get_setting("application/config/name", "")))
	picker.file_selected.connect(func(zip_path: String) -> void:
		var result := UserDataOps.zip_paths(paths, zip_path)
		if result.error == OK:
			_show_copy_feedback(btn, "Zipped %d file(s)" % result.files)
			OS.shell_show_in_file_manager(zip_path)
		else:
			push_warning("Manage User Data: could not write '%s' (error %d)" % [zip_path, result.error])
			_show_copy_feedback(btn, "Zip failed")
		picker.queue_free()
	)
	picker.canceled.connect(picker.queue_free)
	EditorInterface.get_base_control().add_child(picker)
	picker.popup_file_dialog()


## Picks a .zip, shows what restoring it would write and overwrite, then
## extracts it into user:// (see UserDataOps.unzip_into_user).
func _on_restore_pressed(btn: Button) -> void:
	var picker := EditorFileDialog.new()
	picker.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	picker.access = EditorFileDialog.ACCESS_FILESYSTEM
	picker.add_filter("*.zip", "Zip archive")
	picker.title = "Restore a .zip into user://"
	picker.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	picker.file_selected.connect(func(zip_path: String) -> void:
		picker.queue_free()
		_confirm_restore(btn, zip_path)
	)
	picker.canceled.connect(picker.queue_free)
	EditorInterface.get_base_control().add_child(picker)
	picker.popup_file_dialog()


func _confirm_restore(btn: Button, zip_path: String) -> void:
	var listing := UserDataOps.zip_listing(zip_path)
	if listing.error != OK or listing.entries.is_empty():
		_show_copy_feedback(btn, "Nothing to restore")
		return
	var text := "Restore %d file(s) from %s into user://?" % [listing.entries.size(), zip_path.get_file()]
	if not listing.existing.is_empty():
		text += "\n\n%d existing file(s) will be overwritten." % listing.existing.size()
	if not listing.unsafe.is_empty():
		text += "\n%d entr(ies) point outside user:// and will be skipped." % listing.unsafe.size()
	var confirm := ConfirmationDialog.new()
	confirm.title = "Restore Zip"
	confirm.dialog_text = text
	confirm.get_ok_button().text = "Restore"
	confirm.confirmed.connect(func() -> void:
		var result := UserDataOps.unzip_into_user(zip_path)
		_on_refresh_tree()
		_show_copy_feedback(btn, "Restored %d file(s)" % result.files)
		confirm.queue_free()
	)
	confirm.canceled.connect(confirm.queue_free)
	EditorInterface.get_base_control().add_child(confirm)
	confirm.popup_centered()


## Shows brief feedback text on a button, then restores the original text.
func _show_copy_feedback(btn: Button, message: String) -> void:
	if not is_instance_valid(btn):
		return
	var original_text := btn.text
	btn.text = message
	btn.disabled = true
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if not is_instance_valid(btn):
			return  # The dialog was closed meanwhile.
		btn.text = original_text
		btn.disabled = false
	)


## Recursively deletes all contents inside [param path] without removing the
## directory itself. Symlinks are removed, never followed.
func delete_directory_contents(path: String) -> void:
	UserDataOps.delete_directory_contents(path)
