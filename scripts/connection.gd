extends Node

signal binary_message_received(data: PackedByteArray)
signal text_message_received(message: String)
signal connection_succeeded
signal connection_failed

const INITIAL_CONNECTION_TIMEOUT := 2.0
const RECONNECT_INTERVAL := 3.0

var server_url := ""
var waiting_for_initial_connection := false
var initial_connection_timer := 0.0
var reconnect_timer := 0.0

var socket := WebSocketPeer.new()


func _process(delta: float) -> void:
	if server_url.is_empty():
		return

	socket.poll()

	if waiting_for_initial_connection:
		initial_connection_timer -= delta

		if initial_connection_timer <= 0.0:
			waiting_for_initial_connection = false
			socket.close()
			print("[Godot] Initial connection timeout")
			connection_failed.emit()
			return

	match socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			reconnect_timer = 0.0

			if waiting_for_initial_connection:
				waiting_for_initial_connection = false
				print("[Godot] Stream connection succeeded")
				connection_succeeded.emit()

			_receive_packets()

		WebSocketPeer.STATE_CLOSED:
			if waiting_for_initial_connection:
				waiting_for_initial_connection = false
				print("[Godot] Stream connection failed")
				connection_failed.emit()
			else:
				_handle_closed(delta)


func set_server_url(url: String) -> void:
	server_url = url.replace("http://", "ws://").replace("https://", "wss://")

	if not server_url.ends_with("/"):
		server_url += "/"

	print("[Godot] Server URL: ", server_url)

	socket.close()
	socket = WebSocketPeer.new()

	reconnect_timer = 0.0
	waiting_for_initial_connection = true
	initial_connection_timer = INITIAL_CONNECTION_TIMEOUT

	_connect_server()


func _connect_server() -> void:
	if server_url.is_empty():
		return

	print("[Godot] Connecting to: ", server_url)

	var error := socket.connect_to_url(server_url)

	if error != OK:
		print("[Godot] connect_to_url() failed: ", error)
		reconnect_timer = RECONNECT_INTERVAL


func _receive_packets() -> void:
	while socket.get_available_packet_count() > 0:
		var packet: PackedByteArray = socket.get_packet()

		if socket.was_string_packet():
			text_message_received.emit(packet.get_string_from_utf8())
		else:
			binary_message_received.emit(packet)


func send_json(data: Dictionary) -> bool:
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("[Godot] Cannot send JSON: WebSocket is not connected")
		return false

	var message := JSON.stringify(data)
	var error := socket.send_text(message)

	if error != OK:
		print("[Godot] Failed to send JSON: ", error)
		return false

	return true


func _handle_closed(delta: float) -> void:
	reconnect_timer += delta

	if reconnect_timer < RECONNECT_INTERVAL:
		return

	reconnect_timer = 0.0
	socket = WebSocketPeer.new()
	_connect_server()
