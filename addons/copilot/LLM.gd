@tool
extends Node

var model
var api_key
var allow_multiline

signal completion_received(completion, pre, post)
signal completion_error(error)

#Expects return value of String Array
func _get_models():
	return []

#Sets active model
func _set_model(model_name):
	model = model_name

#Sets API key
func _set_api_key(key):
	api_key = key

#Determines if multiline completions are allowed
func _set_multiline(allowed):
	allow_multiline = allowed

#Sends user prompt
func _send_user_prompt(user_prompt, user_suffix):
	pass

