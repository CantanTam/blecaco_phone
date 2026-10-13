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

	stream.visible = false


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
