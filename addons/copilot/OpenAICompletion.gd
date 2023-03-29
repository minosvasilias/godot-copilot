tool
extends "res://addons/copilot/LLM.gd"

const URL = "https://api.openai.com/v1/completions"
const PROMPT_PREFIX = """#This is a GDScript script using Godot 3.x. 
#That means the old GDScript syntax is used. Here's a couple of important things to remember:
#- Use Spatial, not Node3D, and translation, not position
#- Use rad2deg, not rad_to_deg
#- Use instance, not instantiate
#- You can't use enumerate(OBJECT). Instead, use "for i in len(OBJECT):" 
#- Use true, not True, and false, not False
#
#Remember, this is not Python. It's GDScript for use in Godot.


"""
const MAX_LENGTH = 8500

func _get_models():
	return [
		"text-davinci-003"
	]

func _set_model(model_name):
	model = model_name

func _send_user_prompt(user_prompt, user_suffix):
	get_completion(user_prompt, user_suffix)

func get_completion(_prompt, _suffix):
	var prompt = _prompt
	var suffix = _suffix
	var combined_prompt = prompt + suffix
	var diff = combined_prompt.length() - MAX_LENGTH
	if diff > 0:
		if suffix.length() > diff:
			suffix = suffix.substr(0,diff)
		else:
			prompt = prompt.substr(diff - suffix.length())
			suffix = ""
	var body = {
		"model": model,
		"prompt": PROMPT_PREFIX + prompt,
		"suffix": suffix,
		"temperature": 0.7,
		"max_tokens": 500,
		"stop": "\n\n" if allow_multiline else "\n" 
	}
	var headers = [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key
	]
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.connect("request_completed",self,"on_request_completed", [_prompt, _suffix])
	var json_body = JSON.print(body)
	var buffer = json_body.to_utf8()
	var error = http_request.request(URL, headers, false, HTTPClient.METHOD_POST, json_body)
	if error != OK:
		emit_signal("completion_error", null)

func on_request_completed(result, response_code, headers, body, pre, post):
	var test_json_conv = JSON.parse(body.get_string_from_utf8())
	var json = test_json_conv.result
	var response = json
	if !response.has("choices"):
		emit_signal("completion_error", response)
		return
	var completion = response.choices[0].text
	emit_signal("completion_received", completion, pre, post)
