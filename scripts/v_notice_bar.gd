extends Panel

# 长条宽度（像素）
const NOTICE_BAR_THICKNESS := 10.0

# 长条与扫描框左侧的间距（像素）
const NOTICE_BAR_MARGIN := 10.0


func _ready() -> void:
	# 垂直居中，锚定到父节点 FrameBorder 的左侧
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.5
	anchor_bottom = 0.5

	# 固定长条宽度和与扫描框的间距
	offset_left = -(NOTICE_BAR_MARGIN + NOTICE_BAR_THICKNESS)
	offset_right = -NOTICE_BAR_MARGIN


func _process(_delta: float) -> void:
	var gravity: Vector3 = Input.get_gravity()
	var gravity_length := gravity.length()

	# 默认保持最大高度
	var v_ratio := 1.0

	if gravity_length > 0.1:
		# 手机自身 Z 轴方向的重力分量
		var z_ratio := clampf(
			absf(gravity.z) / gravity_length,
			0.0,
			1.0
		)

		# cos(β)，其中 β 是手机自身 Z 轴与水平面的夹角
		v_ratio = sqrt(
			maxf(0.0, 1.0 - z_ratio * z_ratio)
		)

	# 父节点 FrameBorder 的高度就是长条的最大高度
	var frame_border := get_parent() as Control

	if frame_border == null:
		return

	var v_height := frame_border.size.y * v_ratio

	# 上下对称收缩，始终保持垂直居中
	offset_top = -v_height / 2.0
	offset_bottom = v_height / 2.0
