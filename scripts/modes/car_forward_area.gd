class_name CarForwardArea
extends Control

# ============================================================
# CarForwardArea：本区域负责视觉表现与触控检测
# ============================================================
# 分工：
#   car_forward_area.gd  遮罩 / 颜色 / 大小 / 渐变 / 按压反馈 / 触控检测
#                        对外暴露 forward_speed 状态
#   car_mode.gd          将手机姿态与车辆速度合并后发送给 Blender
#   car_mode.tscn        负责节点结构
#
# 本文件不直接与 Blender 通讯。
# 触控产生的速度状态由 car_mode.gd 读取并统一发送。
# ============================================================

# ---------------- 变量设置（改这里就够）----------------

# 形状遮罩：两个材质共用同一张图。
@export var mask_texture: Texture2D = preload(
	"res://resources/ForwardBackward.svg"
)

# 指尖光晕圆（ForwardColor）。
@export var circle_size: float = 400.0
@export_range(0.0, 1.0) var gradient_start: float = 0.0
@export_range(0.0, 1.0) var circle_alpha: float = 1.0

# ---- 圆形颜色分段 ----
# 坐标基准：以本区域底边为 y = 0，向上为正。
const COLOR_GREEN := Color(0.0, 1.0, 0.0)
const COLOR_YELLOW := Color(1.0, 1.0, 0.0)
const COLOR_RED := Color(1.0, 0.0, 0.0)

const Y_GREEN_END := 350.0
const Y_GREEN_TO_YELLOW := 515.0
const Y_YELLOW_END := 610.0
const Y_YELLOW_TO_RED := 710.0

# ---- 车辆速度分段 ----
# 同样以本区域底边为 y = 0，向上为正。
#
# 数值含义：
#   正数 = 前进，沿车辆局部 -Z 方向移动
#   负数 = 后退，沿车辆局部 +Z 方向移动
#
# 最终位移倍率还会乘以 Options 中的 car/car_speed。
# ── 连续油门（真车化，默认开启）──
# 手指 y 距底部：
#   0    ~ 370   → 倒车：0 在 370，越往下越快，最低 -REV_MAX
#   370  ~ 430   → 空档死区（滑行不加速）
#   430  ~ 610   → 前进：0 → +FWD_MAX
#   610 以上     → 满油门平台（FWD_MAX）
const THROTTLE_CONTINUOUS := true
const THROTTLE_FWD_MAX: float = 9.0

# ── 油门锁定（防手指滑移）──
# 手指在某个位置静止一小会儿后，自动锁定当前速度；
# 只有明显移动（超过 THROTTLE_LATCH_BREAK_PX）才解锁重新跟手。
const THROTTLE_LATCH_ENABLED: bool = true
const THROTTLE_LATCH_STILL_TIME: float = 0.30
const THROTTLE_LATCH_BREAK_PX: float = 12.0     # 前进最高档（×）
# 倒车最高档 = 前进最高档 × 此比例（最小/最大倒退都按 60% 线性跟随）
const THROTTLE_REV_RATIO: float = 0.6
const THROTTLE_REVERSE_TOP: float = 370.0   # 倒车区上边界（此处速度 = 0）
const THROTTLE_NEUTRAL_TOP: float = 430.0   # 空档区上边界
const THROTTLE_FULL_Y: float = 610.0        # 满油门位置

# ── 分档模式（THROTTLE_CONTINUOUS = false 时使用）──
const SPEED_Y_LIMITS := [170.0, 370.0, 515.0, 610.0]
const SPEED_VALUES := [-4.0, -2.0, 1.0, 3.0, 9.0]

# 箭头底色（ForwardBottomColor）。
@export var base_color: Color = Color(1.0, 1.0, 1.0, 0.117647)
@export_range(0.0, 1.0) var base_pressed_alpha: float = 1.0

# ---------------- 以下一般不用改 ----------------

@onready var glow_color: ColorRect = $ForwardColor
@onready var bottom_color: ColorRect = $ForwardBottomColor

var _glow_material: ShaderMaterial = null
var _base_material: ShaderMaterial = null
var _base_idle_alpha: float = 0.0

# 记录所有正在触屏的手指及其当前位置（视口坐标）。
var active_touches: Dictionary = {}

# 油门锁定状态
var _latch_active: bool = false
var _latch_speed: float = 0.0
var _latch_y_from_bottom: float = 0.0
var _still_time: float = 0.0
var _last_y_from_bottom: float = -1.0
var _current_y_from_bottom: float = -1.0

# 电脑鼠标测试状态。
var mouse_pressed: bool = false
var mouse_position: Vector2 = Vector2.ZERO

# 供 car_mode.gd 读取的车辆速度倍率。
# 正数 = 前进，负数 = 后退，0 = 没有推进指令。
var forward_speed: float = 0.0

# 当前是否允许发送 action。
# 由 Connection.action_sending_changed 同步。
var _actions_enabled: bool = true

var connection_node: Node = null


func _ready() -> void:
	# Connection 常驻在 main.tscn。
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
	)

	if connection_node == null:
		push_warning(
			"[CarForwardArea] Connection not found; "
			+ "pause feedback will be unavailable"
		)
	elif connection_node.has_signal("action_sending_changed"):
		connection_node.connect(
			"action_sending_changed",
			_on_action_sending_changed
		)

		_actions_enabled = bool(
			connection_node.get("action_sending_enabled")
		)

	_glow_material = glow_color.material as ShaderMaterial
	_base_material = bottom_color.material as ShaderMaterial

	_apply_style()

	glow_color.visible = false

	_update_glow_size()
	glow_color.resized.connect(_update_glow_size)


# LinkButton 暂停或恢复 action 发送时同步状态，
# 并立即刷新反馈。
func _on_action_sending_changed(enabled: bool) -> void:
	_actions_enabled = enabled
	_update_feedback()


# 将视觉参数应用到节点和 shader。
func _apply_style() -> void:
	bottom_color.color = base_color
	_base_idle_alpha = base_color.a

	if mask_texture != null:
		if _base_material != null:
			_base_material.set_shader_parameter(
				"mask_texture",
				mask_texture
			)

		if _glow_material != null:
			_glow_material.set_shader_parameter(
				"mask_texture",
				mask_texture
			)

	if _glow_material == null:
		return

	_glow_material.set_shader_parameter(
		"circle_size",
		circle_size
	)

	_glow_material.set_shader_parameter(
		"gradient_start",
		gradient_start
	)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return

	# 手机触屏：记录按下与松开。
	if event is InputEventScreenTouch:
		if event.pressed:
			active_touches[event.index] = event.position
		else:
			active_touches.erase(event.index)

		_update_feedback()

	# 手机触屏：持续更新滑动位置。
	elif event is InputEventScreenDrag:
		if active_touches.has(event.index):
			active_touches[event.index] = event.position
			_update_feedback()

	# 电脑鼠标：按下时开始追踪。
	elif event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return

		mouse_pressed = event.pressed
		mouse_position = event.position
		_update_feedback()

	# 电脑鼠标：按住并滑动。
	elif event is InputEventMouseMotion:
		mouse_position = event.position
		_update_feedback()


func _update_feedback() -> void:
	var active_position := Vector2.ZERO
	var is_inside := false

	# 只要任意一根手指位于区域内，就触发反馈。
	for touch_position in active_touches.values():
		if _is_inside(touch_position):
			active_position = touch_position
			is_inside = true
			break

	# 电脑鼠标测试。
	if (
		not is_inside
		and mouse_pressed
		and _is_inside(mouse_position)
	):
		active_position = mouse_position
		is_inside = true

	# 暂停发送时，不显示按压反馈，也不提供速度。
	if not _actions_enabled:
		is_inside = false

	# 手指在本区域内的局部坐标。
	# 这里没有旋转或缩放，因此直接减去 global_position。
	var local_position: Vector2 = (
		active_position - global_position
	)

	# 以区域底边为 y = 0，向上为正。
	var y_from_bottom: float = size.y - local_position.y

	_current_y_from_bottom = y_from_bottom if is_inside else -1.0

	# 根据手指高度计算车辆前进/后退倍率。
	# 未按在区域内或暂停时，速度为 0。
	if not is_inside:
		_reset_latch()
		forward_speed = 0.0
	elif _latch_active:
		# 锁定中：只有明显移动才解锁，避免手指滑移改速度
		if absf(y_from_bottom - _latch_y_from_bottom) > THROTTLE_LATCH_BREAK_PX:
			_latch_active = false
			_still_time = 0.0
			forward_speed = _speed_for_y(y_from_bottom)
		else:
			forward_speed = _latch_speed
	else:
		forward_speed = _speed_for_y(y_from_bottom)

	# 箭头底色：按下时变实心。
	bottom_color.color.a = (
		base_pressed_alpha
		if is_inside
		else _base_idle_alpha
	)

	# 光晕圆：只有手指位于有效区域时才显示。
	glow_color.visible = is_inside

	if not is_inside or _glow_material == null:
		return

	# 圆心：x 固定为区域水平中心，y 取手指局部 y。
	_glow_material.set_shader_parameter(
		"circle_center",
		Vector2(
			glow_color.size.x * 0.5,
			local_position.y
		)
	)

	# 根据手指所在高度设置光晕颜色。
	_glow_material.set_shader_parameter(
		"circle_color",
		_color_for_y(y_from_bottom)
	)


# 根据手指高度返回光晕颜色。
func _color_for_y(y_from_bottom: float) -> Color:
	var color: Color

	if y_from_bottom <= Y_GREEN_END:
		color = COLOR_GREEN
	elif y_from_bottom <= Y_GREEN_TO_YELLOW:
		color = COLOR_GREEN.lerp(
			COLOR_YELLOW,
			(y_from_bottom - Y_GREEN_END)
			/ (Y_GREEN_TO_YELLOW - Y_GREEN_END)
		)
	elif y_from_bottom <= Y_YELLOW_END:
		color = COLOR_YELLOW
	elif y_from_bottom <= Y_YELLOW_TO_RED:
		color = COLOR_YELLOW.lerp(
			COLOR_RED,
			(y_from_bottom - Y_YELLOW_END)
			/ (Y_YELLOW_TO_RED - Y_YELLOW_END)
		)
	else:
		color = COLOR_RED

	color.a = circle_alpha

	return color


# 根据手指高度返回车辆前进/后退速度倍率。
#
#   0    ~ 170   后退 4x
#   170  ~ 370   后退 2x
#   370  ~ 515   前进 1x
#   515  ~ 610   前进 3x
#   610 以上     前进 9x
#
# 正数表示前进，负数表示后退。
func _speed_for_y(y_from_bottom: float) -> float:
	if THROTTLE_CONTINUOUS:
		return _continuous_speed_for_y(y_from_bottom)

	for i in SPEED_Y_LIMITS.size():
		if y_from_bottom <= SPEED_Y_LIMITS[i]:
			return SPEED_VALUES[i]

	return SPEED_VALUES[SPEED_VALUES.size() - 1]


## 连续油门：像真车踏板一样，越推越快
func _continuous_speed_for_y(y_from_bottom: float) -> float:
	# 倒车区：370 → 0，越往下越快
	if y_from_bottom <= THROTTLE_REVERSE_TOP:
		var t: float = 1.0 - clampf(
			y_from_bottom / maxf(THROTTLE_REVERSE_TOP, 1.0),
			0.0,
			1.0
		)

		return -(THROTTLE_FWD_MAX * THROTTLE_REV_RATIO) * t

	# 空档死区：滑行不加速
	if y_from_bottom <= THROTTLE_NEUTRAL_TOP:
		return 0.0

	# 前进区：430 → 610，线性到满油门；以上是满油门平台
	var forward_span: float = maxf(
		THROTTLE_FULL_Y - THROTTLE_NEUTRAL_TOP,
		1.0
	)
	var t: float = clampf(
		(y_from_bottom - THROTTLE_NEUTRAL_TOP) / forward_span,
		0.0,
		1.0
	)

	return THROTTLE_FWD_MAX * t


# 节点尺寸变化时同步给 shader。
func _update_glow_size() -> void:
	if _glow_material == null:
		return

	_glow_material.set_shader_parameter(
		"node_size",
		glow_color.size
	)


func _is_inside(point: Vector2) -> bool:
	return get_global_rect().has_point(point)


# ============================================================
# 油门锁定：手指静止 → 锁定速度；明显移动 → 解锁
# ============================================================

func _process(delta: float) -> void:
	if not THROTTLE_LATCH_ENABLED:
		return

	if _latch_active:
		return

	if _current_y_from_bottom < 0.0:
		_still_time = 0.0
		_last_y_from_bottom = -1.0
		return

	# 手指几乎没动 → 累计静止时间
	if (
		_last_y_from_bottom >= 0.0
		and absf(_current_y_from_bottom - _last_y_from_bottom) <= 1.0
	):
		_still_time += delta

		if (
			_still_time >= THROTTLE_LATCH_STILL_TIME
			and not is_zero_approx(forward_speed)
		):
			_latch_active = true
			_latch_speed = forward_speed
			_latch_y_from_bottom = _current_y_from_bottom
			_still_time = 0.0
	else:
		_still_time = 0.0

	_last_y_from_bottom = _current_y_from_bottom


## 清空锁定（松手 / 离开区域时调用）
func _reset_latch() -> void:
	_latch_active = false
	_latch_speed = 0.0
	_latch_y_from_bottom = 0.0
	_still_time = 0.0
	_last_y_from_bottom = -1.0
