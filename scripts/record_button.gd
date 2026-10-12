extends Button

@onready var indicator: Panel = $Indicator
@onready var connection: Node = get_node_or_null("../../Connection")

var is_recording := false

var indicator_style: StyleBoxFlat
var indicator_tween: Tween

const TRANSITION_DURATION: float = 0.3


func _ready() -> void:
	# 红色指示器不拦截按钮的鼠标和触摸事件
	indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 复制 Inspector 中的样式，保留背景颜色等设置
	var current_style := indicator.get_theme_stylebox("panel")

	if current_style is StyleBoxFlat:
		indicator_style = current_style.duplicate() as StyleBoxFlat
		indicator.add_theme_stylebox_override(
			"panel",
			indicator_style
		)
	else:
		push_error(
			"[RecordButton] Indicator 必须使用 StyleBoxFlat"
		)

	pressed.connect(_on_pressed)

	if connection != null:
		connection.connect(
			"text_message_received",
			_on_text_message_received
		)

	# 初始化状态，不播放动画
	_update_indicator(false)


func _on_pressed() -> void:
	# 立即切换录制状态
	is_recording = not is_recording

	# 启动视觉动画，但不等待动画完成
	_update_indicator()

	# 立即发送录制指令
	if connection == null:
		push_error("[RecordButton] 找不到 Connection 节点")
		return

	var queued: bool = connection.call(
		"send_setting",
		"record",
		is_recording
	)

	if queued:
		print(
			"[RecordButton] 录制状态已加入发送队列：",
			is_recording
		)
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

	# 只在状态变化时更新，避免重复播放动画
	if is_recording != value:
		is_recording = value
		_update_indicator()

	print(
		"[RecordButton] Blender recording 状态：",
		is_recording
	)


func _update_indicator(animate: bool = true) -> void:
	var target_position: Vector2
	var target_size: Vector2
	var target_radius: int

	if is_recording:
		# 录制中：50 × 50 px 圆角方形
		target_position = Vector2(35, 35)
		target_size = Vector2(50, 50)
		target_radius = 8
	else:
		# 未录制：104 × 104 px 圆形
		target_position = Vector2(8, 8)
		target_size = Vector2(104, 104)
		target_radius = 52

	# 中断上一段动画，从当前显示状态继续过渡
	if indicator_tween != null and indicator_tween.is_running():
		indicator_tween.kill()

	# 初始化时直接设置，不播放动画
	if not animate or indicator_style == null:
		indicator.position = target_position
		indicator.size = target_size
		_set_indicator_corner_radius(target_radius)
		return

	# 创建非阻塞动画
	indicator_tween = create_tween()
	indicator_tween.set_parallel(true)
	indicator_tween.set_trans(Tween.TRANS_CUBIC)
	indicator_tween.set_ease(Tween.EASE_IN_OUT)

	# 位置与尺寸同时变化
	indicator_tween.tween_property(
		indicator,
		"position",
		target_position,
		TRANSITION_DURATION
	)

	indicator_tween.tween_property(
		indicator,
		"size",
		target_size,
		TRANSITION_DURATION
	)

	# 四个角的圆角半径同时平滑变化
	indicator_tween.tween_property(
		indicator_style,
		"corner_radius_top_left",
		target_radius,
		TRANSITION_DURATION
	)

	indicator_tween.tween_property(
		indicator_style,
		"corner_radius_top_right",
		target_radius,
		TRANSITION_DURATION
	)

	indicator_tween.tween_property(
		indicator_style,
		"corner_radius_bottom_left",
		target_radius,
		TRANSITION_DURATION
	)

	indicator_tween.tween_property(
		indicator_style,
		"corner_radius_bottom_right",
		target_radius,
		TRANSITION_DURATION
	)


func _set_indicator_corner_radius(radius: int) -> void:
	if indicator_style == null:
		return

	indicator_style.corner_radius_top_left = radius
	indicator_style.corner_radius_top_right = radius
	indicator_style.corner_radius_bottom_left = radius
	indicator_style.corner_radius_bottom_right = radius
