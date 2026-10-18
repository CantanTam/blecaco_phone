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

# ── 临时功能开关（按需求分阶段实现）──
# 右摇杆：控制 DRONE_EMPTY 沿局部 X / Y 移动（先禁用）
const RIGHT_STICK_ENABLED: bool = true
# TiltArea 双指倾斜手势（先禁用）
const TILT_GESTURE_ENABLED: bool = true

# ── TiltArea 双指手势 ──
const TILT_SEND_HZ: float = 30.0
# 每帧平均滑动多少像素算"满速"（越小越灵敏）
const TILT_PIXELS_FULL: float = 12.0
# "归水平 / 朝下" 两个一次性命令的去抖时间
const TILT_GESTURE_COOLDOWN: float = 1.2

# ── 速度档位：按摇杆距离分档（与边框颜色一一对应）──
# 0=白(<15px) 1=绿(15~85) 2=黄(85~155) 3=红(155~225)
const SPEED_TIER_MULTIPLIERS: Array = [0.25, 0.5, 1.0, 1.8]
const SPEED_TIER_THRESHOLDS: Array = [15.0, 85.0, 155.0]
# 迟滞（px）：避免在阈值附近来回跳档
const SPEED_TIER_HYSTERESIS: float = 8.0

# ── 方向限位时的边框宽度指示 ──
const ORIENTATION_BORDER_THICK: int = 50   # 限定方向那一侧
const ORIENTATION_BORDER_DEFAULT: int = 15 # 其它情况（与 .tscn 默认一致）

# ── 方向限位（LIMIT_ORIENTATION）──
# 手指到 X 轴 / Y 轴距离"相等"的容差（px）：落在这个带内 → 动作全部暂停
const ORIENTATION_LIMIT_EPSILON: float = 6.0

# ── 摇杆低通滤波（抗手指抖动）──
# 时间常数（秒）：越大越平滑、越"肉"；0.045 ≈ 60Hz 下 α≈0.30，延迟约 2~3 帧
const STICK_SMOOTH_TAU: float = 0.045
# 是否启用（关掉就是原始直通）
const STICK_SMOOTH_ENABLED: bool = true

# 摇杆数据的发送频率（Hz）
const STICK_SEND_HZ: float = 30.0
# 初始化消息的重试间隔（秒）
const INITIALIZE_RETRY_INTERVAL: float = 0.5

# 圆范围A：手指离开这个圆（以 StickArea 中心为圆心）→ 摇杆立刻回中心
const STICK_CANCEL_RADIUS: float = 400.0

# 圆范围B：摇杆按钮圆心的移动上限（以 StickArea 中心为圆心）
const STICK_LIMIT_RADIUS: float = 225.0

# 限向（暂时只做样式，不做真实功能）
var LIMIT_ORIENTATION: bool = false

# 限向按钮的两个图标
const ICON_LIMIT_OFF: String = "res://resources/UnLimitOrientation.svg"
const ICON_LIMIT_ON: String = "res://resources/LimitOrientation.svg"

var _icon_limit_off: Texture2D = null
var _icon_limit_on: Texture2D = null

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
@onready var limit_orientation_button: Button = $LimitOrientationButton

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

# ── 归一化摇杆向量（长度 0~1，方向 = 摇杆方向；设备无关，可直接驱动无人机）──
# 例：右推到底 → (1, 0)；左上 45° 半推 → (-0.35, -0.35)
var left_stick_vector: Vector2 = Vector2.ZERO
var right_stick_vector: Vector2 = Vector2.ZERO

# ── 网络发送 ──
var connection_node: Node = null
var _send_timer: float = 0.0
var _init_retry_timer: float = 0.0
var _drone_initialized: bool = false
var _drone_was_sending: bool = false

# TiltArea 双指手势状态
var _tilt_pointers: Dictionary = {}     # 手指 id → 当前视口坐标
var _tilt_prev: Dictionary = {}         # 手指 id → 上一帧视口坐标
var _tilt_accum: float = 0.0            # 累积的垂直滑动量（像素）
var _tilt_send_timer: float = 0.0
var _tilt_cooldown: float = 0.0

# 当前速度档位（默认 2 = 黄档 = 1.0×）
var _left_speed_tier: int = 2
var _right_speed_tier: int = 2

# 上一次应用的边框宽度（left/top/right/bottom），用于避免重复写主题
var _left_border_widths: Vector4 = Vector4(-1, -1, -1, -1)
var _right_border_widths: Vector4 = Vector4(-1, -1, -1, -1)

# 低通滤波后的摇杆向量（实际发送用这个）
var _left_vector_smooth: Vector2 = Vector2.ZERO
var _right_vector_smooth: Vector2 = Vector2.ZERO

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

	# 找 Connection 节点（发摇杆数据用）
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
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

	# 限向按钮：图标 + 初始样式
	if ResourceLoader.exists(ICON_LIMIT_OFF):
		_icon_limit_off = load(ICON_LIMIT_OFF)

	if ResourceLoader.exists(ICON_LIMIT_ON):
		_icon_limit_on = load(ICON_LIMIT_ON)

	if limit_orientation_button != null:
		limit_orientation_button.focus_mode = Control.FOCUS_NONE
		limit_orientation_button.expand_icon = true

	_update_limit_orientation_icon()

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

			# 限向按钮
			if _is_orientation_button_hit(touch.position):
				_toggle_limit_orientation()
				get_viewport().set_input_as_handled()
				return

			# 尝试激活其中一个摇杆
			if _try_start_stick(touch.index, touch.position):
				get_viewport().set_input_as_handled()
				return

			# 其余触摸 → 记为倾斜手势的候选手指
			# （飞行时 TiltArea 是隐藏的，所以不限制具体区域；
			#   摇杆/开关已在上面的分支被占用，不会冲突）
			_tilt_pointers[touch.index] = touch.position
			_tilt_prev.erase(touch.index)
		else:
			# 手指松开，释放对应摇杆 / 移出倾斜手势
			_end_stick(touch.index)

			_tilt_pointers.erase(touch.index)
			_tilt_prev.erase(touch.index)

			if _tilt_pointers.is_empty():
				_tilt_accum = 0.0

	# 手机手指拖动
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag

		if _tilt_pointers.has(drag.index):
			_tilt_pointers[drag.index] = drag.position

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

				# 限向按钮
				if _is_orientation_button_hit(mouse.position):
					_toggle_limit_orientation()
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

			if DEBUG_INPUT:
				print("[Drone] 左摇杆已捕获 (id=%d)" % pointer_id)

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

			if DEBUG_INPUT:
				print("[Drone] 右摇杆已捕获 (id=%d)" % pointer_id)

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
	_update_orientation_borders()
	_update_speed_tiers()
	_update_stick_vectors()
	_update_smoothed_vectors(_delta)
	_send_sticks(_delta)
	_update_tilt(_delta)


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
		_left_vector_smooth = Vector2.ZERO

		_set_button_offsets(
			left_stick_button,
			left_stick_base_offsets,
			Vector2.ZERO
		)

	# 右摇杆松开：回到中心
	if right_stick_pointer_id == pointer_id:
		right_stick_pointer_id = -1
		_right_vector_smooth = Vector2.ZERO

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

	# 通知 Blender：开启时创建 DRONE_EMPTY 并挂载摄像机，关闭时删除
	_send_drone_rig_state(DRONE_STATU)


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


## 每帧计算两侧归一化摇杆向量（除以圆范围B半径，所以满推 = 1.0）
func _update_stick_vectors() -> void:
	if STICK_LIMIT_RADIUS <= 0.0:
		return

	left_stick_vector = _stick_vector(left_stick_button, left_stick_area)
	right_stick_vector = _stick_vector(right_stick_button, right_stick_area)


## 按钮圆心相对区域中心的位移 → 归一化向量（长度 ≤ 1）
func _stick_vector(button: Control, area: Control) -> Vector2:
	var button_center: Vector2 = (
		button.get_global_transform_with_canvas() * (button.size * 0.5)
	)
	var area_center: Vector2 = (
		area.get_global_transform_with_canvas() * (area.size * 0.5)
	)

	return (button_center - area_center) / STICK_LIMIT_RADIUS


## 把左右摇杆的归一化向量发给 Blender（"drone" 模式）
func _send_sticks(delta: float) -> void:
	if connection_node == null or not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	# 关闭状态：发一次零值让 Blender 停下，并复位初始化标志
	if not DRONE_STATU:
		if _drone_was_sending:
			_send_stick_payload(Vector2.ZERO, Vector2.ZERO)
			_drone_was_sending = false

		_drone_initialized = false
		_init_retry_timer = 0.0
		_send_timer = 0.0
		return

	# 先发初始化消息，成功后才开始发摇杆数据
	if not _drone_initialized:
		_init_retry_timer += delta

		if _init_retry_timer < INITIALIZE_RETRY_INTERVAL:
			return

		_init_retry_timer = 0.0

		var ok: bool = bool(
			connection_node.call(
				"send_action",
				"drone",
				{"command": "initialize"}
			)
		)

		if ok:
			_drone_initialized = true
			print("[Drone] Blender 摄像机已初始化（开始发送摇杆数据）")

		return

	# 固定频率发送
	_send_timer += delta

	if _send_timer < 1.0 / STICK_SEND_HZ:
		return

	_send_timer = 0.0
	_send_stick_payload(_left_vector_smooth, _right_vector_smooth)
	_drone_was_sending = true


## 发送一条摇杆数据：左杆=平移、右杆=转向，dt=本条消息代表的时间
func _send_stick_payload(left_vector: Vector2, right_vector: Vector2) -> void:
	connection_node.call(
		"send_action",
		"drone",
		{
			"command": "stick",
			"lx": left_vector.x,
			"ly": left_vector.y,
			"rx": right_vector.x if RIGHT_STICK_ENABLED else 0.0,
			"ry": right_vector.y if RIGHT_STICK_ENABLED else 0.0,
			"speed_l": float(SPEED_TIER_MULTIPLIERS[_left_speed_tier]),
			"speed_r": float(SPEED_TIER_MULTIPLIERS[_right_speed_tier]),
			"dt": 1.0 / STICK_SEND_HZ,
		}
	)


## 通知 Blender 创建 / 删除 DRONE_EMPTY 支架
func _send_drone_rig_state(enabled: bool) -> void:
	if connection_node == null or not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	var ok: bool = bool(
		connection_node.call(
			"send_action",
			"drone",
			{"command": "enable" if enabled else "disable"}
		)
	)

	print(
		"[Drone] 通知 Blender：%s（%s）"
		% [
			"创建 DRONE_EMPTY" if enabled else "删除 DRONE_EMPTY",
			"已发送" if ok else "发送失败"
		]
	)


# ============================================================
# TiltArea 双指手势 → 绕活动摄像机自身 X 轴旋转
# ============================================================

func _update_tilt(delta: float) -> void:
	if not TILT_GESTURE_ENABLED:
		return

	_tilt_cooldown = maxf(_tilt_cooldown - delta, 0.0)

	# 按需求：只有在 DRONE_STATU == true（飞行中）时才响应双指倾斜手势
	if not DRONE_STATU:
		_tilt_prev.clear()
		_tilt_accum = 0.0
		return

	if _tilt_pointers.size() < 2:
		_tilt_prev.clear()
		_tilt_accum = 0.0
		return

	var ids: Array = _tilt_pointers.keys()
	var id_a: int = ids[0]
	var id_b: int = ids[1]
	var pos_a: Vector2 = _tilt_pointers[id_a]
	var pos_b: Vector2 = _tilt_pointers[id_b]

	if not _tilt_prev.has(id_a) or not _tilt_prev.has(id_b):
		_tilt_prev[id_a] = pos_a
		_tilt_prev[id_b] = pos_b
		return

	var delta_a: Vector2 = pos_a - _tilt_prev[id_a]
	var delta_b: Vector2 = pos_b - _tilt_prev[id_b]

	_tilt_prev[id_a] = pos_a
	_tilt_prev[id_b] = pos_b

	var vertical_a: float = absf(delta_a.y)
	var vertical_b: float = absf(delta_b.y)
	var horizontal_a: float = absf(delta_a.x)
	var horizontal_b: float = absf(delta_b.x)

	var same_direction_up_down: bool = (
		vertical_a > 1.0
		and vertical_b > 1.0
		and signf(delta_a.y) == signf(delta_b.y)
	)
	var opposite_up_down: bool = (
		vertical_a > 6.0
		and vertical_b > 6.0
		and signf(delta_a.y) != signf(delta_b.y)
	)
	var opposite_left_right: bool = (
		horizontal_a > 6.0
		and horizontal_b > 6.0
		and signf(delta_a.x) != signf(delta_b.x)
	)

	# 一个向上一个向下 → 归水平
	if opposite_up_down and _tilt_cooldown <= 0.0:
		_send_tilt_command("tilt_level")
		_tilt_cooldown = TILT_GESTURE_COOLDOWN
		return

	# 一个向左一个向右 → 镜头朝下（世界 -Z）
	if opposite_left_right and _tilt_cooldown <= 0.0:
		_send_tilt_command("tilt_down")
		_tilt_cooldown = TILT_GESTURE_COOLDOWN
		return

	# 同时向上 / 同时向下 → 增量旋转（上滑 = 正度数）
	if same_direction_up_down:
		_tilt_accum += -(delta_a.y + delta_b.y) * 0.5

	_tilt_send_timer += delta

	if _tilt_send_timer < 1.0 / TILT_SEND_HZ:
		return

	_tilt_send_timer = 0.0

	var amount: float = clampf(_tilt_accum / TILT_PIXELS_FULL, -1.0, 1.0)
	_tilt_accum = 0.0

	if absf(amount) <= 0.02:
		return

	if connection_node == null or not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	connection_node.call(
		"send_action",
		"drone",
		{
			"command": "tilt",
			"amount": amount,
			"dt": 1.0 / TILT_SEND_HZ,
		}
	)


## 发送一次性倾斜命令（tilt_level / tilt_down）
func _send_tilt_command(command: String) -> void:
	if connection_node == null or not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	connection_node.call("send_action", "drone", {"command": command})
	print("[Drone] 发送倾斜命令：", command)


## 按两侧 BUTTON_DISTANCE 更新速度档位（带迟滞，避免阈值附近抖动）
func _update_speed_tiers() -> void:
	_left_speed_tier = _next_speed_tier(BUTTON_DISTANCE, _left_speed_tier)
	_right_speed_tier = _next_speed_tier(BUTTON_DISTANCE_RIGHT, _right_speed_tier)


## 距离 → 档位（0..3），带迟滞
func _next_speed_tier(distance: float, current: int) -> int:
	var tier: int = current

	# 升档：越过"阈值 + 迟滞"
	while (
		tier < SPEED_TIER_MULTIPLIERS.size() - 1
		and distance >= SPEED_TIER_THRESHOLDS[tier] + SPEED_TIER_HYSTERESIS
	):
		tier += 1

	# 降档：低于"阈值 - 迟滞"
	while (
		tier > 0
		and distance < SPEED_TIER_THRESHOLDS[tier - 1] - SPEED_TIER_HYSTERESIS
	):
		tier -= 1

	return tier


## 摇杆向量低通滤波：抑制手指抖动（松手时已在 _end_stick 里立刻清零）
func _update_smoothed_vectors(delta: float) -> void:
	if not STICK_SMOOTH_ENABLED:
		_left_vector_smooth = _apply_orientation_limit(
			left_stick_vector, left_stick_area, left_stick_pointer_id,
			_left_speed_tier, true
		)
		_right_vector_smooth = _apply_orientation_limit(
			right_stick_vector, right_stick_area, right_stick_pointer_id,
			_right_speed_tier, false
		)
		return

	# 与帧率无关的指数平滑：k = 1 - e^(-dt/τ)
	var k: float = 1.0 - exp(-maxf(delta, 1e-4) / STICK_SMOOTH_TAU)

	# 先做方向限位（锁定在单一轴），再平滑 —— 切换轴时会有短暂过渡，不会突变
	var left_target: Vector2 = _apply_orientation_limit(
		left_stick_vector,
		left_stick_area,
		left_stick_pointer_id,
		_left_speed_tier,
		true
	)
	var right_target: Vector2 = _apply_orientation_limit(
		right_stick_vector,
		right_stick_area,
		right_stick_pointer_id,
		_right_speed_tier,
		false
	)

	_left_vector_smooth = _left_vector_smooth.lerp(left_target, k)
	_right_vector_smooth = _right_vector_smooth.lerp(right_target, k)

	# 已经贴到目标就吸附过去，避免无限逼近
	if (_left_vector_smooth - left_target).length() < 1e-4:
		_left_vector_smooth = left_target

	if (_right_vector_smooth - right_target).length() < 1e-4:
		_right_vector_smooth = right_target


# ============================================================
# 限向按钮（暂时只有样式切换）
# ============================================================

## 屏幕坐标是否落在限向按钮上
func _is_orientation_button_hit(viewport_position: Vector2) -> bool:
	if limit_orientation_button == null or not limit_orientation_button.visible:
		return false

	return limit_orientation_button.get_global_rect().has_point(viewport_position)


## 点击限向按钮：切换状态 + 换图标
func _toggle_limit_orientation() -> void:
	LIMIT_ORIENTATION = not LIMIT_ORIENTATION
	_update_limit_orientation_icon()

	print("[Drone] LIMIT_ORIENTATION =", LIMIT_ORIENTATION)


## 按当前状态设置按钮图标
func _update_limit_orientation_icon() -> void:
	if limit_orientation_button == null:
		return

	var icon: Texture2D = _icon_limit_on if LIMIT_ORIENTATION else _icon_limit_off

	if icon != null:
		limit_orientation_button.icon = icon
		limit_orientation_button.text = ""
	else:
		# 图标缺失时退化为文字，不影响使用
		limit_orientation_button.text = "ON" if LIMIT_ORIENTATION else "OFF"


## 方向限位：把摇杆向量锁到单一轴上
##   手指离 X 轴更近（偏水平）→ 只保留水平分量（左=旋转 / 右=横移）
##   手指离 Y 轴更近（偏竖直）→ 只保留竖直分量（左=升降 / 右=纵移）
##   到两轴距离相等（容差内）→ 全部为 0
func _apply_orientation_limit(
	raw: Vector2,
	area: Control,
	pointer_id: int,
	tier: int,
	is_left: bool
) -> Vector2:
	if not LIMIT_ORIENTATION:
		return raw

	# 摇杆没被按住（或还在白档 = 未开始移动）→ 不做限位
	if pointer_id == -1 or tier < 1:
		return raw

	var latest: Vector2 = (
		left_stick_latest_position if is_left else right_stick_latest_position
	)
	var local_position: Vector2 = _viewport_to_local(area, latest)
	var offset: Vector2 = local_position - (area.size * 0.5)

	# 到 X 轴（水平轴）的距离 = |offset.y|；到 Y 轴（竖直轴）的距离 = |offset.x|
	var distance_to_x: float = absf(offset.y)
	var distance_to_y: float = absf(offset.x)

	# 相等（容差内）→ 旋转与移动都暂停
	if absf(distance_to_x - distance_to_y) <= ORIENTATION_LIMIT_EPSILON:
		return Vector2.ZERO

	# 离 X 轴更近 → 偏水平 → 只执行水平动作
	if distance_to_x < distance_to_y:
		return Vector2(raw.x, 0.0)

	# 离 Y 轴更近 → 偏竖直 → 只执行竖直动作
	return Vector2(0.0, raw.y)


# ============================================================
# 方向限位的边框宽度指示（左右各一份）
# ============================================================

## 根据当前限位方向计算边框宽度 (left, top, right, bottom)
func _orientation_border_widths(is_left: bool) -> Vector4:
	var default_widths := Vector4(
		ORIENTATION_BORDER_DEFAULT, ORIENTATION_BORDER_DEFAULT,
		ORIENTATION_BORDER_DEFAULT, ORIENTATION_BORDER_DEFAULT
	)

	if not LIMIT_ORIENTATION:
		return default_widths

	var pointer_id: int = left_stick_pointer_id if is_left else right_stick_pointer_id
	var tier: int = _left_speed_tier if is_left else _right_speed_tier

	# 没在拖动 / 白档（未开始移动）→ 保持默认
	if pointer_id == -1 or tier < 1:
		return default_widths

	var area: Control = left_stick_area if is_left else right_stick_area
	var latest: Vector2 = (
		left_stick_latest_position if is_left else right_stick_latest_position
	)

	var local_position: Vector2 = _viewport_to_local(area, latest)
	var offset: Vector2 = local_position - (area.size * 0.5)

	var distance_to_x: float = absf(offset.y)
	var distance_to_y: float = absf(offset.x)

	# 相等（容差内）→ 默认（四边 15）
	if absf(distance_to_x - distance_to_y) <= ORIENTATION_LIMIT_EPSILON:
		return default_widths

	# 偏水平 → 只标左 / 右
	if distance_to_x < distance_to_y:
		if offset.x < 0.0:
			return Vector4(ORIENTATION_BORDER_THICK, 0, 0, 0)

		return Vector4(0, 0, ORIENTATION_BORDER_THICK, 0)

	# 偏竖直 → 只标上 / 下
	if offset.y < 0.0:
		return Vector4(0, ORIENTATION_BORDER_THICK, 0, 0)

	return Vector4(0, 0, 0, ORIENTATION_BORDER_THICK)


## 把宽度写到两侧 StickArea 的样式上（变化时才写）
func _update_orientation_borders() -> void:
	var left_widths: Vector4 = _orientation_border_widths(true)
	var right_widths: Vector4 = _orientation_border_widths(false)

	if left_area_style != null and left_widths != _left_border_widths:
		_left_border_widths = left_widths
		left_area_style.border_width_left = int(left_widths.x)
		left_area_style.border_width_top = int(left_widths.y)
		left_area_style.border_width_right = int(left_widths.z)
		left_area_style.border_width_bottom = int(left_widths.w)

	if right_area_style != null and right_widths != _right_border_widths:
		_right_border_widths = right_widths
		right_area_style.border_width_left = int(right_widths.x)
		right_area_style.border_width_top = int(right_widths.y)
		right_area_style.border_width_right = int(right_widths.z)
		right_area_style.border_width_bottom = int(right_widths.w)
