extends Control

# Blender 推来的 setting 名 → 本机 Options 的键。
# 收到之后就写进 Options，而不是让各模式各自监听：
# 模式场景是连接成功之后才加载的，Blender 的推送可能早于它，
# 放在 main（常驻）里收下，模式启动时直接读就行。
#
#   output_fps  场景输出帧率（决定手机发送频率 / 前进步长）
#   fps         推流帧率 ┐
#   width       推流宽度 ├ 手机连上时的「校准」用，见 addon_set.gd
#   quality     推流画质 │
#   smooth      平滑程度 ┘
#   cameras     摄像机列表 + 活动摄像机    见 camera_select.gd
#   shading     3D 视图的着色方式 + X-Ray  见 shade_set_page.gd
const BLENDER_SETTING_KEYS := {
	"output_fps": "blender/output_fps",
	"fps": "blender/fps",
	"width": "blender/width",
	"quality": "blender/quality",
	"smooth": "blender/smooth",
	"cameras": "blender/cameras",
	"shading": "blender/shading",
}

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


# Blender 推来的设置（output_fps + 三个推流参数）。
# 见文件开头 BLENDER_SETTING_KEYS 的说明。
func _on_text_message_received(message: String) -> void:
	var data: Variant = JSON.parse_string(message)

	if not (data is Dictionary):
		return

	if data.get("type") != "setting":
		return

	var setting_name := str(data.get("name", ""))

	if not BLENDER_SETTING_KEYS.has(setting_name):
		return

	var raw: Variant = data.get("value")
	var key: String = BLENDER_SETTING_KEYS[setting_name]

	# 收到的是字典类型的状态：摄像机列表、着色方式……都是整份覆盖。
	# 具体由各页面读出来用（camera_select.gd / shade_set_page.gd）。
	if raw is Dictionary:
		Options.set_value(key, raw, false)
		print(
			"[Main] Blender 同步 %s：%s" % [setting_name, str(raw)]
		)
		return

	if not (raw is float or raw is int):
		return

	var value := float(raw)

	# output_fps 是「时间轴每秒前进几帧」，0 或负数没有意义
	if setting_name == "output_fps" and value <= 0.0:
		return

	# ⚠️ 只更新内存，不落盘：这几个值以当前连的那台 Blender 为准，
	#    下次连上还会被重新校准一次（见 addon_set.gd 的 Options.changed 处理）。
	Options.set_value(key, value, false)

	print("[Main] Blender 同步 %s = %s" % [setting_name, str(value)])


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
