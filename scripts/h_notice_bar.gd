
extends Panel

# 长条厚度（像素）
const NOTICE_BAR_THICKNESS := 10.0

# 长条与扫描框底部的间距（像素）
const NOTICE_BAR_MARGIN := 10.0


func _ready() -> void:
	# 水平居中，锚定到父节点 FrameBorder 的底部
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0

	# 固定长条厚度和与扫描框的间距
	offset_top = NOTICE_BAR_MARGIN
	offset_bottom = NOTICE_BAR_MARGIN + NOTICE_BAR_THICKNESS


func _process(_delta: float) -> void:
	var gravity: Vector3 = Input.get_gravity()
	var gravity_length := gravity.length()

	# 默认保持最大长度
	var h_ratio := 1.0

	if gravity_length > 0.1:
		# 根据当前屏幕方向选择手机长轴对应的重力分量
		var window_size := DisplayServer.window_get_size()
		var is_landscape := window_size.x > window_size.y

		var device_long_axis_g: float

		if is_landscape:
			device_long_axis_g = gravity.x
		else:
			device_long_axis_g = gravity.y

		var axis_ratio := clampf(
			absf(device_long_axis_g) / gravity_length,
			0.0,
			1.0
		)

		h_ratio = 1.0 - axis_ratio

	# 父节点 FrameBorder 的宽度就是长条的最大长度
	var frame_border := get_parent() as Control

	if frame_border == null:
		return

	var h_length := frame_border.size.x * h_ratio

	# 左右对称收缩，始终保持水平居中
	offset_left = -h_length / 2.0
	offset_right = h_length / 2.0
