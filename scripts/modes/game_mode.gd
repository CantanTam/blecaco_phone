extends Control
## Game Mode（游戏模式）——移动摇杆基础实现
##
## 当前只做两件事（后续再加转向、奔跑等）：
##   ① 手指落在 MoveButton 范围内 → MoveButton 圆心立刻跳到触屏点，并实时跟随
##   ② 手指离开屏幕 → MoveButton 圆心立刻回到 MoveStickArea 的圆心
##
## 触摸用 _input() 手动命中检测（Button 的 gui 信号在真机上不可靠 ✗
## 参考 drone_mode 的 Roll 按钮做法）。

## 摇杆归一化半径（位移 / 此值 = -1..1）
const STICK_LIMIT_RADIUS: float = 250.0

## 发送频率（Hz）
const SEND_HZ: float = 60.0

## Blender 连接节点名
const CONNECTION_NODE_NAME: String = "Connection"

## GameRunNotice 出现的触发距离（MoveButton 圆心到 MoveStickArea 圆心的像素距离）
const RUN_NOTICE_TRIGGER_DIST: float = 250.0

## GameRunNotice 圆心到 MoveButton 圆心的距离
## 100px 时会被手指遮住 ✗ 改到 200px ✓
const RUN_NOTICE_OFFSET_DIST: float = 200.0

## 静止时 MoveButton 在 MoveStickArea 里的位置（圆心对齐）
var _rest_position: Vector2 = Vector2.ZERO

## MoveStickArea 的圆心（全局坐标）
var _area_center: Vector2 = Vector2.ZERO

## 摇杆归一化向量（x 右为正 / y 下为正，长度 ≤ 1）
var _stick_vector: Vector2 = Vector2.ZERO

## Blender 连接节点
var connection_node: Node = null

## 是否已初始化
var game_initialized: bool = false

## 发送计时
var _send_timer: float = 0.0

## 当前是否有一根手指在拖动 MoveButton
var _dragging: bool = false

## 正在拖动的触点 id（多指时用来区分）
var _drag_pointer_id: int = -1

@onready var move_stick_area: Panel = $MoveStickArea
@onready var move_button: Panel = $MoveStickArea/MoveButton
@onready var game_run_notice: Panel = $GameRunNotice


func _ready() -> void:
	# 记录静止位置（MoveStickArea 的圆心，减去 MoveButton 半径）
	_update_rest_position()

	move_button.position = _rest_position

	# MoveStickArea 的圆心（全局坐标）
	_area_center = move_stick_area.get_global_rect().get_center()

	# 通知图标初始隐藏（距离为 0 < 250）
	if game_run_notice != null:
		game_run_notice.visible = false

	# 找 Blender 连接节点
	connection_node = get_tree().root.find_child(CONNECTION_NODE_NAME, true, false)

	print(
		"[GameMode] 就绪：MoveStickArea 圆心=",
		_area_center,
		" MoveButton 静止位置=",
		_rest_position,
		" Connection=",
		connection_node != null
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

	# 更新摇杆向量（发给 Blender 驱动机位移动）
	_update_stick_vector(global_center)

	# 每次移动都更新通知图标
	_update_run_notice(global_center)


## 取控件的【几何圆心】（全局坐标）
func _control_center(control: Control) -> Vector2:
	if control == null:
		return Vector2.ZERO
	return control.global_position + control.size * 0.5


## 屏幕坐标是否落在 MoveStickArea 范围内（圆心为原点、半径 = 区域宽度的一半）
## 之前是判断 MoveButton 范围 ✗ 只有 72×72 太小，很难点准 ✗
func _is_stick_area_hit(viewport_position: Vector2) -> bool:
	if move_stick_area == null or not move_stick_area.is_visible_in_tree():
		return false

	# 用圆形范围（区域是正方形 Panel，视觉上是圆的）
	var radius: float = minf(move_stick_area.size.x, move_stick_area.size.y) * 0.5

	if radius <= 0.0:
		return move_stick_area.get_global_rect().has_point(viewport_position)

	return viewport_position.distance_to(_area_center) <= radius


## 计算摇杆归一化向量
##   x：右为正（屏幕坐标）
##   y：下为正（屏幕坐标）
##   长度 ≤ 1（超出上限就钳制，方向保留）
func _update_stick_vector(button_center: Vector2) -> void:
	var offset: Vector2 = button_center - _area_center
	var distance: float = offset.length()

	if distance < 1e-5:
		_stick_vector = Vector2.ZERO
		return

	var normalized: Vector2 = offset / distance
	var magnitude: float = minf(distance / STICK_LIMIT_RADIUS, 1.0)

	_stick_vector = normalized * magnitude


## 按 MoveButton 当前位置更新 GameRunNotice 的显示与位置
##
## 触发：MoveButton 圆心到 MoveStickArea 圆心 > RUN_NOTICE_TRIGGER_DIST
## 位置：沿「区域圆心 → 按钮圆心」方向的射线，按钮圆心再往外 RUN_NOTICE_OFFSET_DIST
##       → d(区域, 通知) = d(区域, 按钮) + 100 > 100 = d(按钮, 通知) ✓
func _update_run_notice(button_center: Vector2) -> void:
	if game_run_notice == null:
		return

	var offset: Vector2 = button_center - _area_center
	var distance: float = offset.length()

	# 没超过触发距离 → 隐藏
	if distance <= RUN_NOTICE_TRIGGER_DIST:
		if game_run_notice.visible:
			game_run_notice.visible = false
			print("[GameMode] 距离 ", snappedf(distance, 0.1), " ≤ 250 → 隐藏 RunNotice")
		return

	# 方向退化（理论上不会，因为 distance > 250）
	var direction: Vector2 = offset / distance

	# 通知圆心 = 按钮圆心 + 方向 × 100（再往外）✓
	#   三点共线验证：area_center → button_center → notice_center
	#   都在同一条射线上（direction 相同，只差倍数）✓
	var notice_center: Vector2 = button_center + direction * RUN_NOTICE_OFFSET_DIST

	# ⚠️ global_position 是【左上角】✗ 不是圆心 ✗
	#    必须减去半个尺寸，才是"以 panel 圆心对齐"✓
	game_run_notice.global_position = notice_center - game_run_notice.size * 0.5

	if not game_run_notice.visible:
		game_run_notice.visible = true
		print(
			"[GameMode] 距离 ", snappedf(distance, 0.1), " > 250 → 显示 RunNotice",
			" 圆心=", notice_center
		)


## 手指抬起 / 触点丢失 → 回到静止位置
func _reset_button() -> void:
	_dragging = false
	_drag_pointer_id = -1
	move_button.position = _rest_position

	# 回到圆心 → 摇杆归零 + 隐藏通知
	_stick_vector = Vector2.ZERO

	if game_run_notice != null:
		game_run_notice.visible = false


## 按固定频率把摇杆向量发给 Blender
func _process(delta: float) -> void:
	if connection_node == null or not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	# 先发一次 initialize（Blender 记录时间基准）
	if not game_initialized:
		_send_timer += delta

		if _send_timer < 0.5:
			return

		_send_timer = 0.0

		var sent: bool = bool(
			connection_node.call(
				"send_action",
				"game",
				{"command": "initialize"}
			)
		)

		if sent:
			game_initialized = true
			print("[GameMode] Blender game control initialized")

		return

	# 按频率发送摇杆向量
	_send_timer += delta

	var interval: float = 1.0 / maxf(SEND_HZ, 1.0)

	if _send_timer < interval:
		return

	_send_timer = 0.0

	connection_node.call(
		"send_action",
		"game",
		{
			"rx": _stick_vector.x,
			"ry": _stick_vector.y,
		}
	)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch

		if touch.pressed:
			if _dragging:
				return

			# 只有落在 MoveButton 内才开始拖动
			if not _is_stick_area_hit(touch.position):
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
			if _dragging or not _is_stick_area_hit(mouse.position):
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
