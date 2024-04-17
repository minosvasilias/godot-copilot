@tool
extends Control

@onready var llms = $LLMs
@onready var context_label = $VBoxParent/Context
@onready var status_label = $VBoxParent/Status
@onready var model_select = $VBoxParent/ModelSetting/Model
@onready var shortcut_modifier_select = $VBoxParent/ShortcutSetting/HBoxContainer/Modifier
@onready var shortcut_key_select = $VBoxParent/ShortcutSetting/HBoxContainer/Key
@onready var multiline_toggle = $VBoxParent/MultilineSetting/Multiline
@onready var openai_key_title = $VBoxParent/OpenAiSetting/Label
@onready var openai_key_input = $VBoxParent/OpenAiSetting/OpenAiKey
@onready var version_label = $Version
@onready var info = $VBoxParent/Info

@export var icon_shader : ShaderMaterial
@export var highlight_color : Color

var editor_interface : EditorInterface
var screen = "Script"

var request_code_state = null
var cur_highlight = null
var indicator = null

var models = {}
var openai_api_key
var cur_model
var cur_shortcut_modifier = "Control" if is_mac() else "Alt"
var cur_shortcut_key = "C"
var allow_multiline = true

const PREFERENCES_STORAGE_NAME = "user://copilot.cfg"
const PREFERENCES_PASS = "F4fv2Jxpasp20VS5VSp2Yp2v9aNVJ21aRK"
const GITHUB_COPILOT_DISCLAIMER = "Use GitHub Copilot keys at your own risk. Retrieve key by following instructions [url=https://gitlab.com/aaamoon/copilot-gpt4-service?tab=readme-ov-file#obtaining-copilot-token]here[/url]."

func _ready():
	#Initialize dock, load settings
	populate_models()
	populate_modifiers()
	load_config()

func populate_models():
	#Add all found models to settings
	model_select.clear()
	for llm in llms.get_children():
		var new_models = llm._get_models()
		for model in new_models:
			model_select.add_item(model)
			models[model] = get_path_to(llm)
	model_select.select(0)
	set_model(model_select.get_item_text(0))

func populate_modifiers():
	#Add available shortcut modifiers based on platform
	shortcut_modifier_select.clear()
	var modifiers = ["Alt", "Ctrl", "Shift"]
	if is_mac(): modifiers = ["Cmd", "Option", "Control", "Shift"]
	for modifier in modifiers:
		shortcut_modifier_select.add_item(modifier)
	apply_by_value(shortcut_modifier_select, cur_shortcut_modifier)

func _unhandled_key_input(event):
	#Handle input
	if event is InputEventKey:
		if cur_highlight:
			#If completion is shown, TAB will accept it
			#and the TAB input ignored
			if event.keycode == KEY_TAB:
				undo_input()
				clear_highlights()
			#BACKSPACE will remove it
			elif event.keycode == KEY_BACKSPACE:
				revert_change()
				clear_highlights()
			#Any other key press will plainly accept it
			else:
				clear_highlights()
		#If shortcut modifier and key are pressed, request completion
		if shortcut_key_pressed(event) and shortcut_modifier_pressed(event):
			request_completion()

func is_mac():
	#Platform check
	return OS.get_name() == "macOS"

func shortcut_key_pressed(event):
	#Check if selected shortcut key is pressed
	var key_string = OS.get_keycode_string(event.keycode)
	return key_string == cur_shortcut_key

func shortcut_modifier_pressed(event):
	#Check if selected shortcut modifier is pressed
	match cur_shortcut_modifier:
		"Control":
			return event.ctrl_pressed
		"Ctrl":
			return event.ctrl_pressed
		"Alt":
			return event.alt_pressed
		"Option":
			return event.alt_pressed
		"Shift":
			return event.shift_pressed
		"Cmd":
			return event.meta_pressed
		_:
			return false

func clear_highlights():
	#Clear all currently highlighted lines
	#and reset request status
	request_code_state = null
	cur_highlight = null
	var editor = get_code_editor()
	for line in range(editor.get_line_count()):
		editor.set_line_background_color(line, Color(0, 0, 0, 0))

func undo_input():
	#Undo last input in code editor
	var editor = get_code_editor()
	editor.undo()

func update_loading_indicator(create = false):
	#Make sure loading indicator is placed at caret position
	if screen != "Script": return
	var editor = get_code_editor()
	if !editor: return
	var line_height = editor.get_line_height()
	if !is_instance_valid(indicator):
		if !create: return
		indicator = ColorRect.new()
		indicator.material = icon_shader
		indicator.custom_minimum_size = Vector2(line_height, line_height)
		editor.add_child(indicator)
	var pos = editor.get_caret_draw_pos()
	var pre_post = get_pre_post()
	#Caret position returned from Godot is not reliable
	#Needs to be adjusted for empty lines
	var is_on_empty_line = pre_post[0].right(1) == "\n"
	var offset = line_height/2-1 if is_on_empty_line else line_height-1
	indicator.position = Vector2(pos.x, pos.y - offset)
	editor.editable = false

func remove_loading_indicator():
	#Free loading indicator, and return editor to editable state
	if is_instance_valid(indicator): indicator.queue_free()
	set_status("")
	var editor = get_code_editor()
	editor.editable = true

func set_status(text):
	#Update status label in dock
	status_label.text = ""

func insert_completion(content: String, pre, post):
	#Overwrite code editor text to insert received completion
	var editor = get_code_editor()
	var scroll = editor.scroll_vertical
	
	var caret_text = pre + content
	var lines_from = pre.split("\n")
	var lines_to = caret_text.split("\n")
	
	cur_highlight = [lines_from.size(), lines_to.size()]
	
	editor.set_text(pre + content + post)
	editor.set_caret_line(lines_to.size())
	editor.set_caret_column(lines_to[-1].length())
	editor.scroll_vertical = scroll
	editor.update_code_completion_options(false)

func revert_change():
	#Revert inserted completion
	var code_edit = get_code_editor()
	var scroll = code_edit.scroll_vertical
	var old_text = request_code_state[0] + request_code_state[1]
	var lines_from = request_code_state[0].strip_edges(false, true).split("\n")
	code_edit.set_text(old_text)
	code_edit.set_caret_line(lines_from.size()-1)
	code_edit.set_caret_column(lines_from[-1].length())
	code_edit.scroll_vertical = scroll
	clear_highlights()

func _process(delta):
	#Update visuals and context label
	update_highlights()
	update_loading_indicator()
	update_context()

func update_highlights():
	#Make sure highlighted lines persist until explicitely removed
	#via key input
	if cur_highlight:
		var editor = get_code_editor()
		for line in range(cur_highlight[0]-1, cur_highlight[1]):
			editor.set_line_background_color(line, highlight_color)

func update_context():
	#Show currently edited file in dock
	var script = get_current_script()
	if script: context_label.text = script.resource_path.get_file()

func on_main_screen_changed(_screen):
	#Track current editor screen (2D, 3D, Script)
	screen = _screen

func get_current_script():
	#Get currently edited script
	if !editor_interface: return
	var script_editor = editor_interface.get_script_editor()
	return script_editor.get_current_script()

func get_code_editor():
	#Get currently used code editor
	#This does not return the shader editor!
	if !editor_interface: return
	var script_editor = editor_interface.get_script_editor()
	var base_editor = script_editor.get_current_editor()
	if base_editor:
		var code_edit = base_editor.get_base_editor()
		return code_edit
	return null

func request_completion():
	#Get current code and request completion from active model
	if request_code_state: return
	set_status("Asking %s..." % cur_model)
	update_loading_indicator(true)
	var pre_post = get_pre_post()
	var llm = get_llm()
	if !llm: return
	llm._send_user_prompt(pre_post[0], pre_post[1])
	request_code_state = pre_post

func get_pre_post():
	#Split current code based on caret position
	var editor = get_code_editor()
	var text = editor.get_text()
	var pos = Vector2(editor.get_caret_line(), editor.get_caret_column())
	var pre = ""
	var post = ""
	for i in range(pos.x):
		pre += editor.get_line(i) + "\n"
	pre += editor.get_line(pos.x).substr(0,pos.y)
	post += editor.get_line(pos.x).substr(pos.y) + "\n"
	for ii in range(pos.x+1, editor.get_line_count()):
		post += editor.get_line(ii) + "\n"
	return [pre, post]

func get_llm():
	#Get currently active llm and set active model
	var llm = get_node(models[cur_model])
	llm._set_api_key(openai_api_key)
	llm._set_model(cur_model)
	llm._set_multiline(allow_multiline)
	return llm

func matches_request_state(pre, post):
	#Check if code passed for completion request matches current code
	return request_code_state[0] == pre and request_code_state[1] == post

func set_openai_api_key(key):
	#Apply API key
	openai_api_key = key

func set_model(model_name):
	#Apply selected model
	cur_model = model_name
	# Handle some special model scenarios
	if "github-copilot" in model_name:
		openai_key_title.text = "GitHub Copilot API Key"
		info.parse_bbcode(GITHUB_COPILOT_DISCLAIMER)
		info.show()
	else:
		openai_key_title.text = "OpenAI API Key"
		info.hide()

func set_shortcut_modifier(modifier):
	#Apply selected shortcut modifier
	cur_shortcut_modifier = modifier

func set_shortcut_key(key):
	#Apply selected shortcut key
	cur_shortcut_key = key

func set_multiline(active):
	#Apply selected multiline setting
	allow_multiline = active

func _on_code_completion_received(completion, pre, post):
	#Attempt to insert received code completion
	remove_loading_indicator()
	if matches_request_state(pre, post):
		insert_completion(completion, pre, post)
	else:
		clear_highlights()

func _on_code_completion_error(error):
	#Display error
	remove_loading_indicator()
	clear_highlights()
	push_error(error)

func _on_open_ai_key_changed(key):
	#Apply setting and store in config file
	set_openai_api_key(key)
	store_config()

func _on_model_selected(index):
	#Apply setting and store in config file
	set_model(model_select.get_item_text(index))
	store_config()

func _on_shortcut_modifier_selected(index):
	#Apply setting and store in config file
	set_shortcut_modifier(shortcut_modifier_select.get_item_text(index))
	store_config()

func _on_shortcut_key_selected(index):
	#Apply setting and store in config file
	set_shortcut_key(shortcut_key_select.get_item_text(index))
	store_config()

func _on_multiline_toggled(button_pressed):
	#Apply setting and store in config file
	set_multiline(button_pressed)
	store_config()

func store_config():
	#Store current setting in config file
	var config = ConfigFile.new()
	config.set_value("preferences", "model", cur_model)
	config.set_value("preferences", "shortcut_modifier", cur_shortcut_modifier)
	config.set_value("preferences", "shortcut_key", cur_shortcut_key)
	config.set_value("preferences", "allow_multiline", allow_multiline)
	config.set_value("keys", "openai", openai_api_key)
	config.save_encrypted_pass(PREFERENCES_STORAGE_NAME, PREFERENCES_PASS)

func load_config():
	#Retrieve current settings from config file
	var config = ConfigFile.new()
	var err = config.load_encrypted_pass(PREFERENCES_STORAGE_NAME, PREFERENCES_PASS)
	if err != OK: return
	cur_model = config.get_value("preferences", "model", cur_model)
	apply_by_value(model_select, cur_model)
	set_model(model_select.get_item_text(model_select.selected))
	cur_shortcut_modifier = config.get_value("preferences", "shortcut_modifier", cur_shortcut_modifier)
	apply_by_value(shortcut_modifier_select, cur_shortcut_modifier)
	cur_shortcut_key = config.get_value("preferences", "shortcut_key", cur_shortcut_key)
	apply_by_value(shortcut_key_select, cur_shortcut_key)
	allow_multiline = config.get_value("preferences", "allow_multiline", allow_multiline)
	multiline_toggle.set_pressed_no_signal(allow_multiline)
	openai_api_key = config.get_value("keys", "openai", "")
	openai_key_input.text = openai_api_key

func apply_by_value(option_button, value):
	#Select item for option button based on value instead of index
	for i in option_button.item_count:
		if option_button.get_item_text(i) == value:
			option_button.select(i)

func set_version(version):
	version_label.text = "v%s" % version


func on_info_meta_clicked(meta):
	OS.shell_open(meta)
