extends Control
## Game Mode（游戏模式）——移动摇杆基础实现
##
## 当前只做两件事（后续再加转向、奔跑等）：
##   ① 手指落在 MoveButton 范围内 → MoveButton 圆心立刻跳到触屏点，并实时跟随
##   ② 手指离开屏幕 → MoveButton 圆心立刻回到 MoveStickArea 的圆心
##
## 触摸用 _input() 手动命中检测（Button 的 gui 信号在真机上不可靠 ✗
## 参考 drone_mode 的 Roll 按钮做法）。

## 静止时 MoveButton 在 MoveStickArea 里的位置（圆心对齐）
var _rest_position: Vector2 = Vector2.ZERO

## 当前是否有一根手指在拖动 MoveButton
var _dragging: bool = false

## 正在拖动的触点 id（多指时用来区分）
var _drag_pointer_id: int = -1

@onready var move_stick_area: Panel = $MoveStickArea
@onready var move_button: Panel = $MoveStickArea/MoveButton


func _ready() -> void:
	# 记录静止位置（MoveStickArea 的圆心，减去 MoveButton 半径）
	_update_rest_position()

	move_button.position = _rest_position

	print(
		"[GameMode] 就绪：MoveStickArea 圆心=",
		move_stick_area.get_global_rect().get_center(),
		" MoveButton 静止位置=",
		_rest_position
	)


## 计算 MoveButton 的静止位置（让它圆心对齐 MoveStickArea 圆心）
func _update_rest_position() -> void:
	if move_stick_area == null or move_button == null:
		return

	var area_size: Vector2 = move_stick_area.size
	var button_size: Vector2 = move_button.size

	_rest_position = (area_size - button_size) * 0.5


## 把 MoveButton 的圆心摆到指定的全局坐标
func _set_button_center(global_center: Vector2) -> void:
	if move_button == null:
		return

	# global_position = 圆心 - 半个尺寸
	move_button.global_position = global_center - move_button.size * 0.5


## 屏幕坐标是否落在 MoveButton 上
func _is_move_button_hit(viewport_position: Vector2) -> bool:
	if move_button == null or not move_button.is_visible_in_tree():
		return false

	return move_button.get_global_rect().has_point(viewport_position)


## 手指抬起 / 触点丢失 → 回到静止位置
func _reset_button() -> void:
	_dragging = false
	_drag_pointer_id = -1
	move_button.position = _rest_position


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch

		if touch.pressed:
			if _dragging:
				return

			# 只有落在 MoveButton 内才开始拖动
			if not _is_move_button_hit(touch.position):
				return

			_dragging = true
			_drag_pointer_id = touch.index

			# 圆心立刻跳到触屏点
			_set_button_center(touch.position)

			print("[GameMode] 开始拖动 index=", touch.index, " pos=", touch.position)
			return

		# 抬起：只处理正在拖动的那根手指
		if _dragging and touch.index == _drag_pointer_id:
			_reset_button()
			print("[GameMode] 松开，回到圆心")
		return

	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag

		if not _dragging or drag.index != _drag_pointer_id:
			return

		# 实时跟随触屏点
		_set_button_center(drag.position)
		return

	# ── 电脑鼠标（真机上触摸会产生模拟鼠标事件，所以要跳过）──
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton

		if mouse.button_index != MOUSE_BUTTON_LEFT:
			return

		if mouse.pressed:
			if _dragging or not _is_move_button_hit(mouse.position):
				return

			_dragging = true
			_drag_pointer_id = -1
			_set_button_center(mouse.position)
		else:
			if _dragging and _drag_pointer_id == -1:
				_reset_button()
		return

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion

		if _dragging and _drag_pointer_id == -1:
			_set_button_center(motion.position)
