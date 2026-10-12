extends Panel

# 长条厚度（像素）
const NOTICE_BAR_THICKNESS := 10.0

# 长条与扫描框左侧的间距（像素）
const NOTICE_BAR_MARGIN := 10.0

var cos_beta: float = 1.0


func _ready() -> void:
	# 垂直居中，锚定到父节点 FrameBorder 的左侧
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.5
	anchor_bottom = 0.5

	# 固定长条厚度和与扫描框的间距
	offset_left = -(NOTICE_BAR_MARGIN + NOTICE_BAR_THICKNESS)
	offset_right = -NOTICE_BAR_MARGIN


func _process(_delta: float) -> void:
	var gravity: Vector3 = Input.get_gravity()
	var gravity_length := gravity.length()

	# 默认保持最大长度
	var v_ratio := 1.0
	var display_ratio := 1.0

	if gravity_length > 0.1:
		var z_ratio := clampf(
			absf(gravity.z) / gravity_length,
			0.0,
			1.0
		)

		# 保留原来的比例计算逻辑
		v_ratio = sqrt(maxf(0.0, 1.0 - z_ratio * z_ratio))

		# 将角度线性转换为 0～1 的显示比例
		display_ratio = acos(z_ratio) / (PI / 2.0)

	cos_beta = v_ratio

	# 父节点 FrameBorder 的高度就是长条的最大长度
	var frame_border := get_parent() as Control

	if frame_border == null:
		return

	var v_height := frame_border.size.y * display_ratio

	# 上下对称收缩，始终保持垂直居中
	offset_top = -v_height / 2.0
	offset_bottom = v_height / 2.0
