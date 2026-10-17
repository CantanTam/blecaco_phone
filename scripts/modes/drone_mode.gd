extends Control

# 无人机状态：false = 关闭，true = 开启
var DRONE_STATU: bool = false

# 摇杆"触发"半径：手指落在这个圆内才开始拖动摇杆
const STICK_TRIGGER_RADIUS: float = 100.0

# StickArea 边框颜色的分档（按 BUTTON_DISTANCE：按钮圆心 D → 区域中心 C 的距离）
const BORDER_DISTANCE_BANDS: Array = [
	# 静止/近距离：白色（与场景默认边框色一致），只有 >15px 才开始变色
	{"max": 15.0, "color": Color(1, 1, 1, 0.6275)},
	{"max": 85.0, "color": Color("#00ff00a0")},
	{"max": 155.0, "color": Color("#ffff00a0")},
	{"max": 225.0, "color": Color("#ff0000a0")},
]

# 圆范围A：手指离开这个圆（以 StickArea 中心为圆心）→ 摇杆立刻回中心
const STICK_CANCEL_RADIUS: float = 400.0

# 圆范围B：摇杆按钮圆心的移动上限（以 StickArea 中心为圆心）
const STICK_LIMIT_RADIUS: float = 225.0

# ── 调试：把这个改成 false 就不再刷日志 ──
const DEBUG_INPUT: bool = true

# 鼠标指针使用的特殊 ID
const MOUSE_POINTER_ID: int = -2

@onready var toggle_area: Panel = $ToggleArea
@onready var toggle_button: Panel = $ToggleArea/ToggleButton

# 左右摇杆区域
@onready var left_stick_area: Panel = $LeftStickArea
@onready var right_stick_area: Panel = $RightStickArea

# 摇杆辅助图
@onready var left_stick_guide: TextureRect = $LeftStickArea/LeftStickGuide
@onready var right_stick_guide: TextureRect = $RightStickArea/RightStickGuide
@onready var tilt_area: Panel = $TiltArea

# 左右摇杆按钮
@onready var left_stick_button: Panel = $LeftStickArea/LeftStickButton
@onready var right_stick_button: Panel = $RightStickArea/RightStickButton

var toggle_style: StyleBoxFlat
var toggle_tween: Tween

# 保存左右摇杆的初始位置和尺寸
var left_stick_base_offsets: Vector4
var right_stick_base_offsets: Vector4

# 是否触摸设备（手机上 Godot 会把触摸同时模拟成鼠标事件，
# 两者都处理会导致"一次点击切换两次"→ 看起来切不动）
var _touch_platform: bool = false

# 当前控制左右摇杆的触摸 ID，-1 代表没有触摸
var left_stick_pointer_id: int = -1
var right_stick_pointer_id: int = -1

# 手指按下时的位置，使用对应摇杆区域的局部坐标
var left_stick_touch_start: Vector2 = Vector2.ZERO
var right_stick_touch_start: Vector2 = Vector2.ZERO

# 手指最新位置（视口坐标）：每帧在 _process 里实时刷新按钮位置，
# 不依赖 InputEventScreenDrag 的到达频率，做到"实时跟随"
var left_stick_latest_position: Vector2 = Vector2.ZERO

# BUTTON_DISTANCE：LeftStickButton 圆心 D 到 LeftStickArea 中心 C 的距离（px）
var BUTTON_DISTANCE: float = 0.0
# 右侧同理
var BUTTON_DISTANCE_RIGHT: float = 0.0

# 左右 StickArea 样式的副本（只改边框颜色，不影响场景里的共享资源）
var left_area_style: StyleBoxFlat = null
var right_area_style: StyleBoxFlat = null

# 上一次应用的分档索引（避免每帧重复写样式）
var _last_border_band_left: int = -1
var _last_border_band_right: int = -1
var right_stick_latest_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	_touch_platform = (
		DisplayServer.is_touchscreen_available()
		or OS.has_feature("mobile")
	)

	# 保存摇杆按钮的原始偏移量
	left_stick_base_offsets = _get_button_offsets(left_stick_button)
	right_stick_base_offsets = _get_button_offsets(right_stick_button)

	# 创建独立样式，避免修改场景中的原始资源
	toggle_style = (
		toggle_area.get_theme_stylebox("panel").duplicate()
		as StyleBoxFlat
	)
	toggle_area.add_theme_stylebox_override("panel", toggle_style)

	# 接管左右 StickArea 的样式（复制一份，避免改动场景里的共享资源）
	var left_area_base := left_stick_area.get_theme_stylebox("panel")

	if left_area_base is StyleBoxFlat:
		left_area_style = (left_area_base as StyleBoxFlat).duplicate() as StyleBoxFlat
		left_stick_area.add_theme_stylebox_override("panel", left_area_style)

	var right_area_base := right_stick_area.get_theme_stylebox("panel")

	if right_area_base is StyleBoxFlat:
		right_area_style = (right_area_base as StyleBoxFlat).duplicate() as StyleBoxFlat
		right_stick_area.add_theme_stylebox_override("panel", right_area_style)

	# 按钮阴影颜色固定为 (0, 0.8, 1, 0.6275)
	_fix_button_shadow(left_stick_button)
	_fix_button_shadow(right_stick_button)

	# 开关按钮不拦截输入
	toggle_button.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 摇杆按钮不拦截输入
	left_stick_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right_stick_button.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 初始化开关外观和节点可见状态
	_update_toggle_visual(false)
	_update_node_visibility()

	if DEBUG_INPUT:
		print(
			"[Drone] _ready: 视口=%s  ToggleArea矩形=%s  DRONE_STATU=%s"
			% [
				str(get_viewport_rect().size),
				str(toggle_area.get_global_rect()),
				DRONE_STATU
			]
		)


func _input(event: InputEvent) -> void:
	# 手机触摸按下或松开
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch

		if DEBUG_INPUT and touch.pressed:
			print(
				"[Drone] 触摸 index=%d pos=%s 命中ToggleArea=%s DRONE_STATU=%s"
				% [
					touch.index,
					str(touch.position),
					_is_position_inside(toggle_area, touch.position),
					DRONE_STATU
				]
			)

		if touch.pressed:
			# 优先处理开关
			if _is_position_inside(toggle_area, touch.position):
				_toggle_drone_status()
				get_viewport().set_input_as_handled()
				return

			# 尝试激活其中一个摇杆
			if _try_start_stick(touch.index, touch.position):
				get_viewport().set_input_as_handled()
		else:
			# 手指松开，释放对应摇杆
			_end_stick(touch.index)

	# 手机手指拖动
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_move_stick(drag.index, drag.position)

	# 电脑鼠标按下或松开（触摸设备跳过：那是触摸事件的模拟副本）
	elif event is InputEventMouseButton:
		if _touch_platform:
			return

		var mouse := event as InputEventMouseButton

		if mouse.button_index == MOUSE_BUTTON_LEFT:
			if DEBUG_INPUT and mouse.pressed:
				print(
					"[Drone] 鼠标 pos=%s 命中ToggleArea=%s DRONE_STATU=%s"
					% [
						str(mouse.position),
						_is_position_inside(toggle_area, mouse.position),
						DRONE_STATU
					]
				)

			if mouse.pressed:
				# 优先处理开关
				if _is_position_inside(toggle_area, mouse.position):
					_toggle_drone_status()
					get_viewport().set_input_as_handled()
					return

				# 尝试激活摇杆
				if _try_start_stick(
					MOUSE_POINTER_ID,
					mouse.position
				):
					get_viewport().set_input_as_handled()
			else:
				_end_stick(MOUSE_POINTER_ID)

	# 电脑鼠标拖动（触摸设备跳过）
	elif event is InputEventMouseMotion:
		if _touch_platform:
			return

		var motion := event as InputEventMouseMotion

		if (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_move_stick(MOUSE_POINTER_ID, motion.position)


func _is_position_inside(
	control: Control,
	viewport_position: Vector2
) -> bool:
	# 将屏幕坐标转换为控件的局部坐标
	var local_position: Vector2 = (
		control.get_global_transform_with_canvas().affine_inverse()
		* viewport_position
	)

	return Rect2(Vector2.ZERO, control.size).has_point(local_position)


func _viewport_to_local(
	control: Control,
	viewport_position: Vector2
) -> Vector2:
	return (
		control.get_global_transform_with_canvas().affine_inverse()
		* viewport_position
	)


func _get_button_center_in_area(
	area: Control,
	button: Control
) -> Vector2:
	# 计算摇杆按钮圆心在屏幕坐标中的位置
	var center_in_viewport: Vector2 = (
		button.get_global_transform_with_canvas()
		* (button.size / 2.0)
	)

	# 转换为对应摇杆区域的局部坐标
	return _viewport_to_local(area, center_in_viewport)


func _get_button_offsets(button: Control) -> Vector4:
	# X、Y、Z、W 分别保存左、上、右、下偏移量
	return Vector4(
		button.offset_left,
		button.offset_top,
		button.offset_right,
		button.offset_bottom
	)


func _set_button_offsets(
	button: Control,
	base_offsets: Vector4,
	movement: Vector2
) -> void:
	# 同时移动四条边，保持摇杆按钮尺寸不变
	button.offset_left = base_offsets.x + movement.x
	button.offset_top = base_offsets.y + movement.y
	button.offset_right = base_offsets.z + movement.x
	button.offset_bottom = base_offsets.w + movement.y


func _try_start_stick(
	pointer_id: int,
	viewport_position: Vector2
) -> bool:
	# 只有无人机控制状态开启时，才能操作摇杆
	if not DRONE_STATU:
		return false

	# 尝试激活左摇杆
	if left_stick_pointer_id == -1:
		var left_local := _viewport_to_local(
			left_stick_area,
			viewport_position
		)
		var left_center := _get_button_center_in_area(
			left_stick_area,
			left_stick_button
		)

		if left_local.distance_to(left_center) <= STICK_TRIGGER_RADIUS:
			left_stick_pointer_id = pointer_id
			left_stick_touch_start = left_local
			left_stick_latest_position = viewport_position
			return true

	# 尝试激活右摇杆
	if right_stick_pointer_id == -1:
		var right_local := _viewport_to_local(
			right_stick_area,
			viewport_position
		)
		var right_center := _get_button_center_in_area(
			right_stick_area,
			right_stick_button
		)

		if right_local.distance_to(right_center) <= STICK_TRIGGER_RADIUS:
			right_stick_pointer_id = pointer_id
			right_stick_touch_start = right_local
			right_stick_latest_position = viewport_position
			return true

	return false


func _move_stick(
	pointer_id: int,
	viewport_position: Vector2
) -> void:
	# 只记录手指最新位置；真正的位移在 _process 里每帧应用 →
	# 不依赖拖拽事件的到达频率，按钮可以做到实时跟随手指
	if left_stick_pointer_id == pointer_id:
		left_stick_latest_position = viewport_position

	if right_stick_pointer_id == pointer_id:
		right_stick_latest_position = viewport_position


func _process(_delta: float) -> void:
	# 每帧把摇杆按钮移动到手指当前位置（实时跟随）
	if left_stick_pointer_id != -1:
		_apply_stick_position(true)

	if right_stick_pointer_id != -1:
		_apply_stick_position(false)

	_update_area_border()


## 根据手指最新位置刷新某侧摇杆按钮的偏移
func _apply_stick_position(is_left: bool) -> void:
	var area: Control = left_stick_area if is_left else right_stick_area
	var button: Control = left_stick_button if is_left else right_stick_button
	var base_offsets: Vector4 = (
		left_stick_base_offsets if is_left else right_stick_base_offsets
	)
	var latest: Vector2 = (
		left_stick_latest_position if is_left else right_stick_latest_position
	)

	# 手指在区域内的局部坐标，以及区域中心（摇杆的圆心）
	var local_position := _viewport_to_local(area, latest)
	var area_center: Vector2 = area.size * 0.5

	# 手指相对区域中心的向量
	var offset: Vector2 = local_position - area_center

	# 圆范围A：手指超出 → 摇杆立刻回到区域中心（位移为 0）
	if offset.length() > STICK_CANCEL_RADIUS:
		_set_button_offsets(button, base_offsets, Vector2.ZERO)
		return

	# 圆范围B：按钮圆心最多移动 STICK_LIMIT_RADIUS；方向与手指一致
	# （在 B 内时 = 跟手指位置完全一致；在 B 外 A 内时 = 同方向但停在 B 边界）
	_set_button_offsets(
		button,
		base_offsets,
		offset.limit_length(STICK_LIMIT_RADIUS)
	)


func _end_stick(pointer_id: int) -> void:
	# 左摇杆松开：回到中心
	if left_stick_pointer_id == pointer_id:
		left_stick_pointer_id = -1

		_set_button_offsets(
			left_stick_button,
			left_stick_base_offsets,
			Vector2.ZERO
		)

	# 右摇杆松开：回到中心
	if right_stick_pointer_id == pointer_id:
		right_stick_pointer_id = -1

		_set_button_offsets(
			right_stick_button,
			right_stick_base_offsets,
			Vector2.ZERO
		)


func _reset_sticks() -> void:
	# 重置两侧摇杆状态
	left_stick_pointer_id = -1
	right_stick_pointer_id = -1

	_set_button_offsets(
		left_stick_button,
		left_stick_base_offsets,
		Vector2.ZERO
	)

	_set_button_offsets(
		right_stick_button,
		right_stick_base_offsets,
		Vector2.ZERO
	)


func _toggle_drone_status() -> void:
	DRONE_STATU = not DRONE_STATU

	if DEBUG_INPUT:
		print("[Drone] 切换 → DRONE_STATU=", DRONE_STATU)

	# 关闭控制状态时，停止摇杆操作并复位
	if not DRONE_STATU:
		_reset_sticks()

	_update_toggle_visual(true)
	_update_node_visibility()


func _update_toggle_visual(animated: bool) -> void:
	var target_y: float

	if DRONE_STATU:
		# 开启：绿色，按钮移动到下方
		toggle_style.bg_color = Color("#00c245")
		target_y = 45.0
	else:
		# 关闭：红色，按钮回到上方
		toggle_style.bg_color = Color("#d90000")
		target_y = 5.0

	# 停止尚未结束的动画
	if toggle_tween != null and toggle_tween.is_running():
		toggle_tween.kill()

	# 获取按钮当前高度，保持尺寸不变
	var button_height: float = (
		toggle_button.offset_bottom - toggle_button.offset_top
	)

	# 计算目标上下边缘
	var target_top: float = target_y
	var target_bottom: float = target_y + button_height

	if animated:
		# 同时动画上下边缘，保持按钮大小不变
		toggle_tween = create_tween()
		toggle_tween.set_parallel(true)
		toggle_tween.set_trans(Tween.TRANS_SINE)
		toggle_tween.set_ease(Tween.EASE_OUT)

		toggle_tween.tween_property(
			toggle_button,
			"offset_top",
			target_top,
			0.2
		)

		toggle_tween.tween_property(
			toggle_button,
			"offset_bottom",
			target_bottom,
			0.2
		)
	else:
		# 初始化时直接定位
		toggle_button.offset_top = target_top
		toggle_button.offset_bottom = target_bottom


## 可见性切换（独立函数：任何一个节点缺失都不会影响开关本身的颜色/动画）
func _update_node_visibility() -> void:
	var show_guides: bool = not DRONE_STATU

	_set_visible_safe(left_stick_guide, show_guides, "LeftStickArea/LeftStickGuide")
	_set_visible_safe(right_stick_guide, show_guides, "RightStickArea/RightStickGuide")
	_set_visible_safe(tilt_area, show_guides, "TiltArea")

	_set_visible_safe(left_stick_button, not show_guides, "LeftStickArea/LeftStickButton")
	_set_visible_safe(right_stick_button, not show_guides, "RightStickArea/RightStickButton")


## 安全地设置可见性：节点为空只警告、不报错
func _set_visible_safe(node: Control, value: bool, node_path: String) -> void:
	if node == null:
		push_warning("[Drone] 找不到节点：" + node_path)
		return

	node.visible = value


## 固定摇杆按钮的阴影颜色（不随距离变化）
func _fix_button_shadow(button: Control) -> void:
	var style := button.get_theme_stylebox("panel")

	if not (style is StyleBoxFlat):
		return

	var fixed := (style as StyleBoxFlat).duplicate() as StyleBoxFlat
	fixed.shadow_color = Color(0, 0.8, 1, 0.6275)
	button.add_theme_stylebox_override("panel", fixed)


## 计算两侧 BUTTON_DISTANCE，并据此更新对应 StickArea 的边框颜色
func _update_area_border() -> void:
	if left_area_style != null:
		BUTTON_DISTANCE = _button_distance(left_stick_button, left_stick_area)
		_last_border_band_left = _apply_border_color(
			left_area_style,
			BUTTON_DISTANCE,
			_last_border_band_left
		)

	if right_area_style != null:
		BUTTON_DISTANCE_RIGHT = _button_distance(
			right_stick_button,
			right_stick_area
		)
		_last_border_band_right = _apply_border_color(
			right_area_style,
			BUTTON_DISTANCE_RIGHT,
			_last_border_band_right
		)


## 按钮圆心 D 到 StickArea 中心 C 的距离（视口坐标，与显示一致）
func _button_distance(button: Control, area: Control) -> float:
	var button_center: Vector2 = (
		button.get_global_transform_with_canvas() * (button.size * 0.5)
	)
	var area_center: Vector2 = (
		area.get_global_transform_with_canvas() * (area.size * 0.5)
	)

	return button_center.distance_to(area_center)


## 按距离选档位并写入边框颜色；返回本次档位（供调用方缓存）
func _apply_border_color(
	style: StyleBoxFlat,
	distance: float,
	last_band: int
) -> int:
	var band: int = BORDER_DISTANCE_BANDS.size() - 1

	for i in range(BORDER_DISTANCE_BANDS.size()):
		if distance < float(BORDER_DISTANCE_BANDS[i]["max"]):
			band = i
			break

	if band != last_band:
		style.border_color = BORDER_DISTANCE_BANDS[band]["color"]

	return band
