
extends Button

@onready var indicator: Panel = $Indicator
@onready var connection: Node = get_node_or_null("../../Connection")

var is_recording := false


func _ready() -> void:
	# 红色指示器不拦截按钮的鼠标和触摸事件
	indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE

	pressed.connect(_on_pressed)
	
	if connection != null:
		connection.connect(
			"text_message_received",
			_on_text_message_received
		)

	# 初始化为未录制状态
	_update_indicator()


func _on_pressed() -> void:
	is_recording = not is_recording

	# 更新按钮外观
	_update_indicator()

	# 检查 Connection 节点
	if connection == null:
		push_error("[RecordButton] 找不到 Connection 节点")
		return

	# 发送 setting 类型的 JSON
	var queued: bool = connection.call(
		"send_setting",
		"record",
		is_recording
	)

	if queued:
		print("[RecordButton] 录制状态已加入发送队列：", is_recording)
	else:
		push_error("[RecordButton] 录制状态发送失败")


func _on_text_message_received(message: String) -> void:
	print("[RecordButton] 收到 Blender 消息：", message)

	var data: Variant = JSON.parse_string(message)

	if not (data is Dictionary):
		return

	if data.get("type") != "setting":
		return

	if data.get("name") != "record":
		return

	var value: Variant = data.get("value")

	if not (value is bool):
		return

	# 只更新按钮状态，不向 Blender 再次发送消息
	is_recording = value
	_update_indicator()

	print("[RecordButton] Blender recording 状态：", is_recording)
	

func _update_indicator() -> void:
	if is_recording:
		# 录制中：缩小为圆角正方形
		indicator.position = Vector2(45, 45)
		indicator.size = Vector2(60, 60)
		_set_indicator_corner_radius(10)
	else:
		# 未录制：恢复红色圆形
		indicator.position = Vector2(12, 12)
		indicator.size = Vector2(126, 126)
		_set_indicator_corner_radius(63)


func _set_indicator_corner_radius(radius: int) -> void:
	var style := indicator.get_theme_stylebox("panel").duplicate() as StyleBoxFlat

	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius

	indicator.add_theme_stylebox_override("panel", style)
