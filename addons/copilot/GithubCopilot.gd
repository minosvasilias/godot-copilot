@tool
extends "res://addons/copilot/LLM.gd"

const URL = "https://api.githubcopilot.com/chat/completions"
const AUTH_URL = "https://api.github.com/copilot_internal/v2/token"
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

const PREFERENCES_STORAGE_NAME = "user://github_copilot_llm.cfg"
const PREFERENCES_PASS = "Jr55ICpdp3M3CuWHX0WHLqg3yh4XBjbXX"

var machine_id
var session_id
var auth_token

signal auth_token_retrieved

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
		"gpt-4-github-copilot"
	]

func _set_model(model_name):
	model = model_name.replace("github-copilot", "")

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
	
func gen_hex_str(length: int) -> String:
	var rng = RandomNumberGenerator.new()
	var result = PackedByteArray()
	for i in range(length / 2):
		result.push_back(rng.randi_range(0, 255))
	var hex_str = ""
	for byte in result:
		hex_str += "%02x" % byte
	return hex_str

func create_headers(token: String, stream: bool):
	var contentType: String = "application/json; charset=utf-8"
	if stream:
		contentType = "text/event-stream; charset=utf-8"

	load_config()
	var uuidString: String = UUID.v4()

	return [
		"Authorization: %s" % ("Bearer " + token),
		"X-Request-Id: %s" % uuidString,
		"Vscode-Sessionid: %s" % session_id,
		"Vscode-Machineid: %s" % machine_id,
		"Editor-Version: vscode/1.83.1",
		"Editor-Plugin-Version: copilot-chat/0.8.0",
		"Openai-Organization: github-copilot",
		"Openai-Intent: conversation-panel",
		"Content-Type: %s" % contentType,
		"User-Agent: GitHubCopilotChat/0.8.0",
		"Accept: */*",
		"Accept-Encoding: gzip,deflate,br",
		"Connection: close"
	]

func get_auth():
	var headers = [
		"Accept-Encoding: gzip",
		"Authorization: token %s" % api_key
	]
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.connect("request_completed",on_auth_request_completed)
	var error = http_request.request(AUTH_URL, headers, HTTPClient.METHOD_GET)
	if error != OK:
		emit_signal("completion_error", null)

func get_completion(messages, prompt, suffix):
	if not auth_token:
		get_auth()
		await auth_token_retrieved
	
	var body = {
		"model": model,
		"messages": messages,
		"temperature": 0.7,
		"top_p": 1,
		"n": 1,
		"stream": false,
	}
	var headers = create_headers(auth_token, false)
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.connect("request_completed",on_request_completed.bind(prompt, suffix, http_request))
	var json_body = JSON.stringify(body)
	var error = http_request.request(URL, headers, HTTPClient.METHOD_POST, json_body)
	if error != OK:
		emit_signal("completion_error", null)

func on_auth_request_completed(result, response_code, headers, body):
	var test_json_conv = JSON.new()
	test_json_conv.parse(body.get_string_from_utf8())
	var json = test_json_conv.get_data()
	auth_token = json.token
	auth_token_retrieved.emit()

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

func store_config():
	var config = ConfigFile.new()
	config.set_value("auth", "machine_id", machine_id)
	config.save_encrypted_pass(PREFERENCES_STORAGE_NAME, PREFERENCES_PASS)
	
func load_config():
	var config = ConfigFile.new()
	var err = config.load_encrypted_pass(PREFERENCES_STORAGE_NAME, PREFERENCES_PASS)
	if not session_id:
		session_id = gen_hex_str(8) + "-" + gen_hex_str(4) + "-" + gen_hex_str(4) + "-" + gen_hex_str(4) + "-" + gen_hex_str(25)
	if err != OK:
		machine_id = UUID.v4()
		store_config()
		return
	machine_id = config.get_value("auth", "machine_id", UUID.v4())
