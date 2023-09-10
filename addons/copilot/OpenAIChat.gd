@tool
extends "res://addons/copilot/LLM.gd"

const URL = "https://api.openai.com/v1/chat/completions"
const SYSTEM_TEMPLATE = """You are a brilliant coding assistant for the game-engine Godot. The version used is Godot 4.0, and all code must be valid GDScript!
That means the new GDScript 2.0 syntax is used. Here's a couple of important changes that were introduced:
- Use @export annotation for exports
- Use Node3D instead of Spatial, and position instead of translation
- Use randf_range and randi_range instead of rand_range
- Connect signals via node.SIGNAL_NAME.connect(Callable(TARGET_OBJECT, TARGET_FUNC))
- Same for sort_custom calls, pass a Callable(TARGET_OBJECT, TARGET_FUNC)
- Use rad_to_deg instead of rad2deg
- Use PackedByteArray instead of PoolByteArray
- Use instantiate instead of instance
- You can't use enumerate(OBJECT). Instead, use "for i in len(OBJECT):"

Remember, this is not Python. It's GDScript for use in Godot.

You may only answer in code, never add any explanations. In your prompt, there will be an !INSERT_CODE_HERE! tag. Only respond with plausible code that may be inserted at that point. Never repeat the full script, only the parts to be inserted. Treat this as if it was an autocompletion. You may continue whatever word or expression was left unfinished before the tag. Make sure indentation matches the surrounding context."""
const INSERT_TAG = "!INSERT_CODE_HERE!"
const MAX_LENGTH = 8500

class Message:
	var role: String
	var content: String
	
	func get_json():
		return {
			"role": role,
			"content": content
		}

const ROLES = {
	"SYSTEM": "system",
	"USER": "user",
	"ASSISTANT": "assistant"
}

func _get_models():
	return [
		"gpt-3.5-turbo",
		"gpt-4"
	]

func _set_model(model_name):
	model = model_name

func _send_user_prompt(user_prompt, user_suffix):
	var messages = format_prompt(user_prompt, user_suffix)
	get_completion(messages, user_prompt, user_suffix)

func format_prompt(prompt, suffix):
	var messages = []
	var system_prompt = SYSTEM_TEMPLATE
	
	var combined_prompt = prompt + suffix
	var diff = combined_prompt.length() - MAX_LENGTH
	if diff > 0:
		if suffix.length() > diff:
			suffix = suffix.substr(0,diff)
		else:
			prompt = prompt.substr(diff - suffix.length())
			suffix = ""
	var user_prompt = prompt + INSERT_TAG + suffix
	
	var msg = Message.new()
	msg.role = ROLES.SYSTEM
	msg.content = system_prompt
	messages.append(msg.get_json())
	
	msg = Message.new()
	msg.role = ROLES.USER
	msg.content = user_prompt
	messages.append(msg.get_json())
	
	return messages

func get_completion(messages, prompt, suffix):
	var body = {
		"model": model,
		"messages": messages,
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
	http_request.connect("request_completed",on_request_completed.bind(prompt, suffix, http_request))
	var json_body = JSON.stringify(body)
	var error = http_request.request(URL, headers, HTTPClient.METHOD_POST, json_body)
	if error != OK:
		emit_signal("completion_error", null)


func on_request_completed(result, response_code, headers, body, pre, post, http_request):
	var test_json_conv = JSON.new()
	test_json_conv.parse(body.get_string_from_utf8())
	var json = test_json_conv.get_data()
	var response = json
	if !response.has("choices") :
		emit_signal("completion_error", response)
		return
	var completion = response.choices[0].message
	if is_instance_valid(http_request):
		http_request.queue_free()
	emit_signal("completion_received", completion.content, pre, post)
