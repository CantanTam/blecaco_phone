extends Node

signal binary_message_received(data: PackedByteArray)
signal text_message_received(message: String)
signal connection_succeeded
signal connection_failed
signal connection_lost

## action 发送开关变化时发出（由 LinkButton 触发）。
## 表现层可以据此提示"当前按了也不会发出去"。
signal action_sending_changed(enabled: bool)

const INITIAL_CONNECTION_TIMEOUT := 2.0
const RECONNECT_INTERVAL := 3.0

# 打开后会以 ~100Hz 打印完整 JSON，会冲掉日志缓冲区；
# 排查问题时再改成 true。
const VERBOSE_SEND_LOG := false

var server_url := ""
var waiting_for_initial_connection := false
var has_connected_once := false
var initial_connection_timer := 0.0
var reconnect_timer := 0.0

var socket := WebSocketPeer.new()
# 是否允许发送 action 类型的 JSON
var action_sending_enabled := true


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
				has_connected_once = true
				print("[Godot] Stream connection succeeded")
				connection_succeeded.emit()

			_receive_packets()

		WebSocketPeer.STATE_CLOSED:
			if waiting_for_initial_connection:
				waiting_for_initial_connection = false
				print("[Godot] Stream connection failed")
				connection_failed.emit()

			elif has_connected_once:
				has_connected_once = false
				server_url = ""

				print("[Godot] Blender stream disconnected")
				connection_lost.emit()

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
			
			
func set_action_sending_enabled(enabled: bool) -> void:
	if action_sending_enabled == enabled:
		return

	action_sending_enabled = enabled
	print("[Godot] Action JSON sending enabled: ", enabled)

	action_sending_changed.emit(enabled)
	
	
# json 结构
func send_action(mode: String, data: Dictionary) -> bool:
	var message := {
		"type": "action",
		"mode": mode,
		"data": data
		}
	return send_json(message)


## 地面标记命令（type = "ground"）
## ⚠️ 不走 action 门控：SetGround 按钮只在 unlink 状态显示，
##    而 unlink 恰好会禁用 action 发送 ✗ 所以必须用独立类型 ✓
func send_ground(enabled: bool) -> bool:
	return send_json({
		"type": "ground",
		"enabled": enabled,
	})


func send_setting(setting_name: String, value: Variant) -> bool:
	var message := {
		"type": "setting",
		"name": setting_name,
		"value": value
		}
	return send_json(message)
	
func send_json(data: Dictionary) -> bool:
	# 禁止发送 action JSON，但不影响 setting JSON
	if (
		data.get("type") == "action"
		and not action_sending_enabled
	):
		return false

	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("[Godot] Cannot send JSON: WebSocket is not connected")
		return false

	var message := JSON.stringify(data)

	if VERBOSE_SEND_LOG:
		print("[Godot] Sending JSON: ", message)

	var error := socket.send_text(message)

	if error != OK:
		print("[Godot] Failed to send JSON: ", error)
		return false

	if VERBOSE_SEND_LOG:
		print("[Godot] JSON queued successfully")

	return true


func _handle_closed(delta: float) -> void:
	reconnect_timer += delta

	if reconnect_timer < RECONNECT_INTERVAL:
		return

	reconnect_timer = 0.0
	socket = WebSocketPeer.new()
	_connect_server()
