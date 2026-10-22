extends Control
## Game Mode（游戏模式）——移动摇杆基础实现
##
## 当前只做两件事（后续再加转向、奔跑等）：
##   ① 手指落在 MoveButton 范围内 → MoveButton 圆心立刻跳到触屏点，并实时跟随
##   ② 手指离开屏幕 → MoveButton 圆心立刻回到 MoveStickArea 的圆心
##
## 触摸用 _input() 手动命中检测（Button 的 gui 信号在真机上不可靠 ✗
## 参考 drone_mode 的 Roll 按钮做法）。

## SetBodyHeight 长按/拖动参数（与 car_mode 的 SetGround 同款 ✓）
const BODY_HEIGHT_HOLD_SEC: float = 2.0
const BODY_HEIGHT_DRAG_DIST: float = 300.0
const BODY_HEIGHT_SNAP_SEC: float = 0.15
const BODY_HEIGHT_FLASH_IN: float = 0.12
const BODY_HEIGHT_FLASH_HOLD: float = 0.10
const BODY_HEIGHT_FLASH_OUT: float = 0.22
const ICON_BODY_HEIGHT_ON: String = "res://resources/BodyHeight.svg"
const ICON_BODY_HEIGHT_OFF: String = "res://resources/NoBodyHeight.svg"
const COLOR_ON := Color("00d455ff")
const COLOR_OFF := Color("ff5555ff")
const COLOR_BTN_NORMAL := Color("000000a0")

## 摇杆归一化半径（位移 / 此值 = -1..1）
const STICK_LIMIT_RADIUS: float = 250.0

## 分档倍率（只作用于【冲刺】速度，行走速度不受影响 ✓）
##   RUN_SPEED % 3 == 1 → 1.10x
##   RUN_SPEED % 3 == 2 → 1.20x
##   RUN_SPEED % 3 == 0 → 1.30x
const RUN_SPEED_MULTIPLIERS := {
	1: 1.10,
	2: 1.20,
	0: 1.30,
}

## 冲刺触发/退出距离（迟滞 20px，防止边界抖动 ✗）
const RUN_TRIGGER_DIST: float = 250.0
const RUN_RELEASE_DIST: float = 230.0

## 倍率过渡时间常数（150ms，避免"突然被推一把"✗）
const RUN_TRANSITION_TAU: float = 0.15

## RunSpeed 图标映射：key = RUN_SPEED % 3 的结果
##   RUN_SPEED % 3 == 1 → One
##   RUN_SPEED % 3 == 2 → Two
##   RUN_SPEED % 3 == 0 → Three
const ICON_RUN_SPEED := {
	1: "res://resources/RunSpeedOne.svg",
	2: "res://resources/RunSpeedTwo.svg",
	0: "res://resources/RunSpeedThree.svg",
}

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

## RunSpeed 档位计数：每次点击 +1，图标由 RUN_SPEED % 3 决定
var RUN_SPEED: int = 1

## Blender 推来的脚下状态（与 car_mode 同款 ✓）
func _on_ground_indicator_message(message: String) -> void:
	var data: Variant = JSON.parse_string(message)
	if not (data is Dictionary):
		return
	if data.get("type") != "ground_indicator":
		return

	# 只取 has_surface（长按前置条件 ✓）
	# ⚠️ 不用它改 HAS_GAME_GROUND ✗ 那是"开关状态"，只能由用户长按切换 ✓
	_gg_has_surface = bool(data.get("has_surface", false))


## 地面人物高度开关
var HAS_GAME_GROUND: bool = false

## 相机 -Y 下方是否有物体（Blender 每 100ms 推 ✓）
var _gg_has_surface: bool = false

## SetBodyHeight 交互状态
var _gg_holding: bool = false
var _gg_hold_time: float = 0.0
var _gg_dragging: bool = false
var _gg_grab_offset: Vector2 = Vector2.ZERO
## 手指最新位置（长按满 2 秒时立刻用它对位 ✓）
var _gg_last_pos: Vector2 = Vector2.ZERO
var _gg_rest_position: Vector2 = Vector2.ZERO
var _gg_style: StyleBoxFlat = null
var _gg_flash_tween: Tween = null

## 是否为触摸设备（真机上触摸会产生【模拟鼠标事件】✗ 必须跳过 ✗）
var _touch_platform: bool = false

## 是否处于冲刺状态（带迟滞 ✓）
var _sprinting: bool = false

## 当前倍率（150ms lerp 过渡中）
var _sprint_multiplier: float = 1.0

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
@onready var run_speed_button: Button = $RunSpeed
@onready var set_body_height_button: Button = $SetBodyHeight


func _ready() -> void:
	# 记录静止位置（MoveStickArea 的圆心，减去 MoveButton 半径）
	_update_rest_position()

	move_button.position = _rest_position

	# MoveStickArea 的圆心（全局坐标）
	_area_center = move_stick_area.get_global_rect().get_center()

	# 通知图标初始隐藏（距离为 0 < 250）
	if game_run_notice != null:
		game_run_notice.visible = false

	# 触摸设备检测：真机上触摸会同时产生 InputEventScreenTouch
	# 和模拟的 InputEventMouseButton ✗ 不跳过会处理两次 ✗
	_touch_platform = (
		DisplayServer.is_touchscreen_available()
		or OS.has_feature("mobile")
	)

	# RunSpeed：应用初始图标
	if run_speed_button != null:
		run_speed_button.focus_mode = Control.FOCUS_NONE
		run_speed_button.expand_icon = true

	_apply_run_speed_icon()

	# SetBodyHeight：复制专属样式 + 记录原位 + 初始图标
	if set_body_height_button != null:
		set_body_height_button.focus_mode = Control.FOCUS_NONE
		set_body_height_button.expand_icon = true

		var bh_base: StyleBox = set_body_height_button.get_theme_stylebox("normal")

		if bh_base is StyleBoxFlat:
			_gg_style = (bh_base as StyleBoxFlat).duplicate()
			set_body_height_button.add_theme_stylebox_override("normal", _gg_style)
			_gg_style.bg_color = COLOR_BTN_NORMAL

		set_body_height_button.mouse_filter = Control.MOUSE_FILTER_IGNORE

		_gg_rest_position = set_body_height_button.global_position
		_apply_body_height_icon()

	# 找 Blender 连接节点
	connection_node = get_tree().root.find_child(CONNECTION_NODE_NAME, true, false)

	# 接收脚下状态推送
	if connection_node != null and is_instance_valid(connection_node):
		if connection_node.has_signal("text_message_received"):
			if not connection_node.text_message_received.is_connected(
				_on_ground_indicator_message
			):
				connection_node.text_message_received.connect(
					_on_ground_indicator_message
				)

	print(
		"[GameMode] 就绪：MoveStickArea 圆心=",
		_area_center,
		" MoveButton 静止位置=",
		_rest_position,
		" Connection=",
		connection_node != null
	)


## 当前档位对应的冲刺倍率
func _run_speed_multiplier() -> float:
	var key: int = RUN_SPEED % 3
	return float(RUN_SPEED_MULTIPLIERS.get(key, 1.0))


## 按距离 + 迟滞更新冲刺状态
##   距离 > 250 → 进入冲刺 ✓
##   距离 < 230 → 退出冲刺 ✓
##   230~250 之间 → 保持当前状态 ✓（防抖动）
func _update_sprint_state(distance: float) -> void:
	if not _sprinting and distance > RUN_TRIGGER_DIST:
		_sprinting = true
		print("[GameMode] 进入冲刺 distance=%.1f" % distance)
	elif _sprinting and distance < RUN_RELEASE_DIST:
		_sprinting = false
		print("[GameMode] 退出冲刺 distance=%.1f" % distance)


## 按 RUN_SPEED % 3 更新图标
func _apply_run_speed_icon() -> void:
	if run_speed_button == null:
		return

	var key: int = RUN_SPEED % 3
	var path: String = ICON_RUN_SPEED.get(key, "")

	if path.is_empty():
		return

	if not ResourceLoader.exists(path):
		print("[GameMode] RunSpeed 图标缺失：", path)
		return

	run_speed_button.icon = load(path)
	run_speed_button.expand_icon = true


## RunSpeed 被点击：RUN_SPEED +1（不重置，图标靠 mod 3 循环）
func _cycle_run_speed() -> void:
	RUN_SPEED += 1
	_apply_run_speed_icon()

	print("[GameMode] RUN_SPEED = ", RUN_SPEED, " (mod 3 = ", RUN_SPEED % 3, ")")


## 屏幕坐标是否落在 RunSpeed 按钮上
func _is_run_speed_hit(viewport_position: Vector2) -> bool:
	if run_speed_button == null or not run_speed_button.is_visible_in_tree():
		return false

	return run_speed_button.get_global_rect().has_point(viewport_position)


# ============================================================
# SetBodyHeight：长按 → 拖动 → 松手判定 → 切换 + 弹回 + 闪烁
# 交互逻辑与 car_mode 的 SetGround 一致 ✓
# ============================================================

## 是否正在移动（摇杆有输出 ✓ 对标 car_mode 的 _is_forward_pressed）
func _is_game_moving() -> bool:
	return _stick_vector.length() > 0.01


func _is_body_height_hit(viewport_position: Vector2) -> bool:
	if set_body_height_button == null or not set_body_height_button.is_visible_in_tree():
		return false
	return set_body_height_button.get_global_rect().has_point(viewport_position)


func _apply_body_height_icon() -> void:
	if set_body_height_button == null:
		return

	var path: String = ICON_BODY_HEIGHT_ON if HAS_GAME_GROUND else ICON_BODY_HEIGHT_OFF

	if not ResourceLoader.exists(path):
		print("[GameMode] BodyHeight 图标缺失：", path)
		return

	set_body_height_button.icon = load(path)
	set_body_height_button.expand_icon = true


func _on_body_height_down(grab_pos: Vector2) -> void:
	_gg_holding = true
	_gg_hold_time = 0.0
	_gg_grab_offset = grab_pos - set_body_height_button.global_position
	_gg_last_pos = grab_pos


func _on_body_height_up() -> void:
	_gg_holding = false
	_gg_hold_time = 0.0

	if not _gg_dragging:
		return

	# 松手时才判定距离 ✓
	var moved: float = (
		set_body_height_button.global_position - _gg_rest_position
	).length()

	if moved >= BODY_HEIGHT_DRAG_DIST:
		_gg_dragging = false
		HAS_GAME_GROUND = not HAS_GAME_GROUND
		print("[GameMode] HAS_GAME_GROUND = ", HAS_GAME_GROUND)

		# 通知 Blender 建立/清除 is_ground 标记 ✓
		if connection_node != null and is_instance_valid(connection_node):
			# ⚠️ 用 "game_ground" ✗ 不能用 "ground"（那会被转给 car_action ✗）
			connection_node.call(
				"send_setting", "game_ground", HAS_GAME_GROUND
			)
		_apply_body_height_icon()
		_gg_snap_back(true)
	else:
		_gg_dragging = false
		print("[GameMode] SetBodyHeight 拖动取消（未满 300px）")
		_gg_snap_back(false)     # 只弹回，不闪烁、不改图标 ✗


## 长按计时：满 2 秒进入拖动状态
func _tick_body_height_hold(delta: float) -> void:
	if not _gg_holding:
		return

	_gg_hold_time += clampf(delta, 0.0, 0.05)

	# 移动中 → 长按中止 ✓
	if _is_game_moving():
		_gg_holding = false
		_gg_hold_time = 0.0
		print("[GameMode] 移动中 → SetBodyHeight 长按中止")
		return

	if _gg_hold_time < BODY_HEIGHT_HOLD_SEC:
		return

	_gg_holding = false
	_gg_hold_time = 0.0

	# 相机下方没有物体 → 不能拖动 ✓（与 car_mode 一致 ✓）
	if not _gg_has_surface:
		print("[GameMode] 相机下方没有物体 → SetBodyHeight 无法拖动")
		return

	_gg_dragging = true
	_gg_rest_position = set_body_height_button.global_position

	# ★ 照搬 MoveButton：圆心 = 手指 ✓
	set_body_height_button.global_position = _gg_last_pos - set_body_height_button.size * 0.5

	print("[GameMode] SetBodyHeight 进入拖动状态（拖满 300px 后松手切换）")


## 拖动跟随（不触发切换 ✗）
func _move_body_height_to(global_pos: Vector2) -> void:
	if not _gg_dragging:
		return

	# 拖动中开始移动 → 取消拖动 ✓
	if _is_game_moving():
		_on_body_height_up_cancel()
		return

	set_body_height_button.global_position = global_pos - set_body_height_button.size * 0.5


## 取消拖动：弹回，不切换 ✓
func _on_body_height_up_cancel() -> void:
	_gg_dragging = false
	print("[GameMode] SetBodyHeight 拖动取消（移动中）")
	_gg_snap_back(false)


## 弹回原位（0.15s BACK 缓动）→ 完成后闪烁
func _gg_snap_back(flash: bool) -> void:
	if _gg_flash_tween != null and _gg_flash_tween.is_valid():
		_gg_flash_tween.kill()

	_gg_flash_tween = create_tween()
	_gg_flash_tween.tween_property(
		set_body_height_button, "global_position", _gg_rest_position,
		BODY_HEIGHT_SNAP_SEC
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	if flash:
		_gg_flash_tween.tween_callback(_play_body_height_flash)


## 颜色反馈：透明 → 彩色 → 保持 → 透明 → 直接回常态色
func _play_body_height_flash() -> void:
	if _gg_style == null:
		return

	if _gg_flash_tween != null and _gg_flash_tween.is_valid():
		_gg_flash_tween.kill()

	var flash_color: Color = COLOR_ON if HAS_GAME_GROUND else COLOR_OFF
	var transparent: Color = flash_color
	transparent.a = 0.0

	_gg_flash_tween = create_tween()
	_gg_flash_tween.tween_property(_gg_style, "bg_color", flash_color, BODY_HEIGHT_FLASH_IN)
	_gg_flash_tween.tween_interval(BODY_HEIGHT_FLASH_HOLD)
	_gg_flash_tween.tween_property(_gg_style, "bg_color", transparent, BODY_HEIGHT_FLASH_OUT)
	_gg_flash_tween.tween_callback(
		func() -> void: _gg_style.bg_color = COLOR_BTN_NORMAL
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

	# 先按迟滞更新冲刺状态
	_update_sprint_state(distance)

	# 没进入冲刺 → 隐藏
	if not _sprinting:
		if game_run_notice.visible:
			game_run_notice.visible = false
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


## 手指抬起 / 触点丢失 → 回到静止位置
func _reset_button() -> void:
	_dragging = false
	_drag_pointer_id = -1
	move_button.position = _rest_position

	# 回到圆心 → 摇杆归零 + 退出冲刺 + 隐藏通知
	_stick_vector = Vector2.ZERO
	_sprinting = false

	if game_run_notice != null:
		game_run_notice.visible = false


## 按固定频率把摇杆向量发给 Blender
func _process(delta: float) -> void:
	# SetBodyHeight 长按计时（放最前面，避免被后面的早退挡住 ✓）
	_tick_body_height_hold(delta)

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

	# 倍率平滑过渡（150ms）
	var target_multiplier: float = _run_speed_multiplier() if _sprinting else 1.0
	var k: float = 1.0 - exp(-delta / maxf(RUN_TRANSITION_TAU, 1e-4))
	_sprint_multiplier = lerpf(_sprint_multiplier, target_multiplier, k)

	connection_node.call(
		"send_action",
		"game",
		{
			"rx": _stick_vector.x,
			"ry": _stick_vector.y,
			"sprint": _sprinting,
			"run_multiplier": _sprint_multiplier,
		}
	)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch

		if touch.pressed:
			# RunSpeed 优先（它在摇杆区域之外，不会冲突）
			if _is_run_speed_hit(touch.position):
				_cycle_run_speed()
				return

			# SetBodyHeight 按下 → 开始长按计时
			if _is_body_height_hit(touch.position):
				# 移动中不允许拖动 ✓（对标 car_mode ✓）
				if _is_game_moving():
					return
				_on_body_height_down(touch.position)
				return

			# 拖动中不响应别的
			if _gg_dragging:
				return

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

		# SetBodyHeight 抬起
		if _gg_holding or _gg_dragging:
			_on_body_height_up()
			return

		# 抬起：只处理正在拖动的那根手指
		if _dragging and touch.index == _drag_pointer_id:
			_reset_button()
			print("[GameMode] 松开，回到圆心")
		return

	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag

		_gg_last_pos = drag.position        # 始终记录 ✓

		# SetBodyHeight 拖动
		if _gg_dragging:
			_move_body_height_to(drag.position)
			return

		if not _dragging or drag.index != _drag_pointer_id:
			return

		# 实时跟随触屏点
		_set_button_center(drag.position)
		return

	# ── 电脑鼠标（真机上触摸会产生模拟鼠标事件，所以要跳过）──
	if event is InputEventMouseButton:
		# 真机上触摸会产生模拟鼠标事件 → 必须忽略，否则会处理两次 ✗
		if _touch_platform:
			return

		var mouse := event as InputEventMouseButton

		if mouse.button_index != MOUSE_BUTTON_LEFT:
			return

		if mouse.pressed:
			if _is_run_speed_hit(mouse.position):
				_cycle_run_speed()
				return

			# SetBodyHeight 按下（桌面测试用 ✓）
			if _is_body_height_hit(mouse.position):
				if _is_game_moving():
					return
				_on_body_height_down(mouse.position)
				return

			if _gg_dragging:
				return

			if _dragging or not _is_stick_area_hit(mouse.position):
				return

			_dragging = true
			_drag_pointer_id = -1
			_set_button_center(mouse.position)
		else:
			# SetBodyHeight 抬起
			if _gg_holding or _gg_dragging:
				_on_body_height_up()
				return

			if _dragging and _drag_pointer_id == -1:
				_reset_button()
		return

	if event is InputEventMouseMotion:
		if _touch_platform:
			return

		_gg_last_pos = (event as InputEventMouseMotion).position

		# SetBodyHeight 拖动（桌面测试用 ✓）
		if _gg_dragging:
			_move_body_height_to((event as InputEventMouseMotion).position)
			return

		var motion := event as InputEventMouseMotion

		if _dragging and _drag_pointer_id == -1:
			_set_button_center(motion.position)
