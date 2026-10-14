extends Control

@onready var qr_code = $QRCode
@onready var stream = $Stream
@onready var connection = $Connection
@onready var active_mode_host: Control = $ModeContainer/ActiveModeHost

func _ready() -> void:
	qr_code.qr_scanned.connect(_on_qr_scanned)
	stream.connection_succeeded.connect(_on_stream_connection_succeeded)
	stream.connection_failed.connect(_on_stream_connection_failed)
	connection.connection_lost.connect(_on_connection_lost)
	connection.text_message_received.connect(_on_text_message_received)

	stream.visible = false


# Blender 推来的设置（目前只有输出帧率）。
# 在这里接收并写进 Options，而不是让各模式各自监听：
# 模式场景是连接成功之后才加载的，Blender 的推送可能早于它，
# 放在 main（常驻）里收下，模式启动时直接读就行。
func _on_text_message_received(message: String) -> void:
	var data: Variant = JSON.parse_string(message)

	if not (data is Dictionary):
		return

	if data.get("type") != "setting":
		return

	if data.get("name") != "output_fps":
		return

	var fps: float = float(data.get("value", 0.0))

	if fps <= 0.0:
		return

	# 只更新内存，不落盘：这个值只对当前连接的那台 Blender 有效
	Options.set_value("blender/output_fps", fps, false)

	print("[Main] Blender 输出帧率同步：", fps, " fps")


func _on_qr_scanned(url: String) -> void:
	print("[Main] QR scanned: ", url)

	qr_code.show_connecting()
	stream.set_server_url(url)


func _on_stream_connection_succeeded() -> void:
	print("[Main] Stream connection succeeded")

	qr_code.visible = false
	stream.visible = true
	_load_active_mode(Options.get_mode_scene_path())
	

func _on_stream_connection_failed() -> void:
	print("[Main] Stream connection failed")
	_clear_active_mode()

	qr_code.visible = true
	stream.visible = false
	qr_code.show_error()
	

func _on_connection_lost() -> void:
	print("[Main] Blender disconnected")
	_clear_active_mode()

	stream.visible = false
	qr_code.visible = true
	qr_code.show_error()
	
	
func _load_active_mode(scene_path: String) -> void:
	_clear_active_mode()

	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null:
		push_error("[Main] 无法加载模式场景: " + scene_path)
		return

	var mode_instance := packed_scene.instantiate()
	active_mode_host.add_child(mode_instance)


func _clear_active_mode() -> void:
	for child in active_mode_host.get_children():
		active_mode_host.remove_child(child)
		child.queue_free()
