extends Control

@onready var move_speed_spin_box: SpinBox = (
	$SetScrollPage/SettingsList/MoveSpeedRow/SpeedInput
)


func _ready() -> void:
	# 设置允许的数值范围
	move_speed_spin_box.min_value = 0.01
	move_speed_spin_box.max_value = 100.0
	move_speed_spin_box.step = 0.01

	# 读取已保存的移动倍数
	move_speed_spin_box.value = clampf(
		Options.get_float("move_speed"),
		0.01,
		100.0
	)

	# 数值改变时，自动保存
	move_speed_spin_box.value_changed.connect(
		_on_move_speed_changed
	)


func _on_move_speed_changed(value: float) -> void:
	Options.set_value("move_speed", value)
