extends TextureRect


func _process(_delta: float) -> void:
	var gravity: Vector3 = Input.get_gravity()

	# 手机接近平放时，暂时保持当前状态
	var xy_length := Vector2(gravity.x, gravity.y).length()

	if xy_length < 4.0:
		return

	# 竖屏显示，横屏隐藏
	visible = absf(gravity.y) < absf(gravity.x)
