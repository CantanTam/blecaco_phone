class_name PlaneForwardArea
extends Control

# ============================================================
# PlaneForwardArea：本区域负责「表现 + 触控检测」
# ============================================================
# 分工：
#   plane_forward_area.gd  遮罩 / 颜色 / 大小 / 渐变 / 按压反馈 / 触控检测
#                          → 对外只暴露 forward_speed 这一个状态
#   plane_mode.gd          数据层：把姿态 + 前进量合并成一条消息发给 Blender
#   plane_mode.tscn        只负责节点结构，不含任何视觉参数
#
# 本文件不直接与 Blender 通讯：手势状态由 plane_mode.gd 读取后统一发送，
# 这样「旋转 + 前进」合并为一条消息，消息量减半，也不会两条流抢同一个通道。
# ============================================================

# ---------------- 变量设置（改这里就够）----------------

# 形状遮罩：两个材质共用同一张图
# ⚠️ 飞机模式只有前进（不倒飞），所以用单独的 PlaneForward.svg（只有上三角）
@export var mask_texture: Texture2D = preload(
	"res://resources/PlaneForward.svg"
)

# 指尖光晕圆（ForwardColor）
@export var circle_size: float = 400.0                        # 直径（像素）
@export_range(0.0, 1.0) var gradient_start: float = 0.0       # 0=圆心起渐变, 1=圆周才起
@export_range(0.0, 1.0) var circle_alpha: float = 1.0         # 圆形透明度（1=不透明，0=看不见）

# ---- 圆形颜色分段 ----
# 坐标基准：以本区域「底边」为 y = 0，向上为正
const COLOR_GREEN := Color(0.0, 1.0, 0.0)
const COLOR_YELLOW := Color(1.0, 1.0, 0.0)
const COLOR_RED := Color(1.0, 0.0, 0.0)

const Y_GREEN_END := 350.0       # 0   ~ 350   纯绿
const Y_GREEN_TO_YELLOW := 515.0 # 350 ~ 515   绿 -> 黄
const Y_YELLOW_END := 610.0      # 515 ~ 610   纯黄
const Y_YELLOW_TO_RED := 710.0   # 610 ~ 710   黄 -> 红

# ---- 推进速度分段 ----
# 同样以本区域「底边」为 y = 0，向上为正。
# 数值含义（由 Blender 端 plane_action.py 的 _move_forward 决定）：
#   正数 = 沿相机局部 -Z 前进（朝相机正对的方向飞）
#   负数 = 沿相机局部 +Z 后退
# 这些倍率之后还会再乘 Options 的 "plane/plane_speed"（全局速度缩放）。
# ── 连续油门（推荐，默认开启）──
# 速度随手指高度线性增加，且边界与上面的**颜色边界**对齐：
#   绿区(<350)   → 慢速
#   黄区(515~610)→ 中速
#   红区(>710)   → 满速
# 飞机不倒飞，所以底部不再是后退档 ✓
const PLANE_CONTINUOUS := true
const PLANE_FWD_MAX: float = 9.0        # 满油门倍率
const PLANE_FULL_Y: float = 710.0       # = Y_YELLOW_TO_RED，此处达到满速
const PLANE_NEUTRAL_Y: float = 20.0     # 底部死区（停住）

# ── 油门锁定（防手指滑移）──
const THROTTLE_LATCH_ENABLED: bool = true
const THROTTLE_LATCH_STILL_TIME: float = 0.30
const THROTTLE_LATCH_BREAK_PX: float = 12.0

# 分档模式（PLANE_CONTINUOUS = false 时使用）
const SPEED_Y_LIMITS := [170.0, 370.0, 515.0, 610.0]
const SPEED_VALUES := [-4.0, -2.0, 1.0, 3.0, 9.0]

# 箭头底色（ForwardBottomColor）
@export var base_color: Color = Color(1.0, 1.0, 1.0, 0.117647)
@export_range(0.0, 1.0) var base_pressed_alpha: float = 1.0

# ---------------- 以下一般不用改 ----------------

@onready var glow_color: ColorRect = $ForwardColor
@onready var bottom_color: ColorRect = $ForwardBottomColor

var _glow_material: ShaderMaterial = null
var _base_material: ShaderMaterial = null
var _base_idle_alpha: float = 0.0

# 记录所有正在触屏的手指及其当前位置（视口坐标）
var active_touches: Dictionary = {}

# 电脑鼠标测试状态
var mouse_pressed: bool = false
var mouse_position: Vector2 = Vector2.ZERO

# 供 plane_mode.gd 读取：手指位置对应的推进速度倍率
# 带符号（正 = 前飞 / 负 = 后退），0 表示没按在区域内或已暂停发送
var forward_speed: float = 0.0

# 油门锁定状态
var _latch_active: bool = false
var _latch_speed: float = 0.0
var _latch_y_from_bottom: float = 0.0
var _still_time: float = 0.0
var _last_y_from_bottom: float = -1.0
var _current_y_from_bottom: float = -1.0

# 当前是否允许发送 action（由 Connection.action_sending_changed 同步）
var _actions_enabled: bool = true

var connection_node: Node = null


func _ready() -> void:
	# Connection 常驻在 main.tscn；模式场景是连接成功之后才加载的，所以这里能找到。
	# 找不到也不影响功能，只是反馈不会反映「暂停」状态。
	connection_node = get_tree().root.find_child("Connection", true, false)

	if connection_node == null:
		push_warning(
			"[PlaneForwardArea] 找不到 Connection，按压反馈不会反映暂停状态"
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


# LinkButton 关/开 action 发送时同步过来，并立刻刷新一次画面，
# 不用等下一次触摸事件。
func _on_action_sending_changed(enabled: bool) -> void:
	_actions_enabled = enabled
	_update_feedback()


# 把上面那些变量推给节点与 shader（遮罩也在这里接上）
func _apply_style() -> void:
	bottom_color.color = base_color
	_base_idle_alpha = base_color.a

	if mask_texture != null:
		if _base_material != null:
			_base_material.set_shader_parameter("mask_texture", mask_texture)

		if _glow_material != null:
			_glow_material.set_shader_parameter("mask_texture", mask_texture)

	if _glow_material == null:
		return

	_glow_material.set_shader_parameter("circle_size", circle_size)
	_glow_material.set_shader_parameter("gradient_start", gradient_start)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return

	# 手机触屏：记录按下与松开
	if event is InputEventScreenTouch:
		if event.pressed:
			active_touches[event.index] = event.position
		else:
			active_touches.erase(event.index)

		_update_feedback()

	# 手机触屏：持续更新滑动位置
	elif event is InputEventScreenDrag:
		if active_touches.has(event.index):
			active_touches[event.index] = event.position
			_update_feedback()

	# 电脑鼠标：按下时开始追踪
	elif event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return

		mouse_pressed = event.pressed
		mouse_position = event.position
		_update_feedback()

	# 电脑鼠标：按住并滑动
	elif event is InputEventMouseMotion:
		mouse_position = event.position
		_update_feedback()


func _update_feedback() -> void:
	var active_position := Vector2.ZERO
	var is_inside := false

	# 只要任意一根手指位于区域内，就触发反馈
	for touch_position in active_touches.values():
		if _is_inside(touch_position):
			active_position = touch_position
			is_inside = true
			break

	# 鼠标测试
	if not is_inside and mouse_pressed and _is_inside(mouse_position):
		active_position = mouse_position
		is_inside = true

	# 暂停发送时不给任何反馈：只保留最基本的 ForwardBottomColor
	# （消息会被 Connection 静默丢弃，亮起来只会让人以为触摸坏了）
	if not _actions_enabled:
		is_inside = false

	# 手指在本区域内的局部坐标，以及「以底边为 0」的高度
	# （Control 没有 to_local()，且这里没有旋转/缩放，
	#   直接减去 global_position 与 _is_inside() 用的坐标系一致）
	var local_position: Vector2 = active_position - global_position
	var y_from_bottom: float = size.y - local_position.y

	# 速度倍率：按手指高度取段（带符号）；没按在区域内 / 已暂停时为 0
	_current_y_from_bottom = y_from_bottom if is_inside else -1.0

	if not is_inside:
		_reset_latch()
		forward_speed = 0.0
	elif _latch_active:
		if absf(y_from_bottom - _latch_y_from_bottom) > THROTTLE_LATCH_BREAK_PX:
			_latch_active = false
			_still_time = 0.0
			forward_speed = _speed_for_y(y_from_bottom)
		else:
			forward_speed = _latch_speed
	else:
		forward_speed = _speed_for_y(y_from_bottom)

	# 箭头底色：按下 → 变实心；暂停时不参与，保持原样
	bottom_color.color.a = (
		base_pressed_alpha if is_inside else _base_idle_alpha
	)

	# 光晕圆：只有手指落在区域内时才出现
	glow_color.visible = is_inside

	if not is_inside or _glow_material == null:
		return

	# 圆心：x 固定为区域水平中心，y 取手指的局部 y
	_glow_material.set_shader_parameter(
		"circle_center",
		Vector2(glow_color.size.x * 0.5, local_position.y)
	)

	# 颜色：以本区域「底边」为 y = 0、向上为正，按手指高度取色
	_glow_material.set_shader_parameter(
		"circle_color",
		_color_for_y(y_from_bottom)
	)


# 以本区域底边为 y = 0（向上为正），按手指高度返回圆的颜色：
#   0    ~ 350   纯绿          (0, 1, 0)
#   350  ~ 515   绿 -> 黄      ( (y-350)/165 , 1 , 0 )
#   515  ~ 610   纯黄          (1, 1, 0)
#   610  ~ 710   黄 -> 红      ( 1 , 1-(y-610)/100 , 0 )
#   710 以上    纯红          (1, 0, 0)
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


# 以本区域底边为 y = 0（向上为正），按手指高度返回推进速度倍率：
#   0    ~ 170   后退  4x      ← 区域底部（箭头 ▼ 那一端）
#   170  ~ 370   后退  2x
#   370  ~ 515   前进  1x
#   515  ~ 610   前进  3x
#   610  ~ 710   前进  9x      ← 区域顶部（箭头 ▲ 那一端）
#   710 以上      同上（前进 9x）
# 正数 = 沿相机局部 -Z 前进；负数 = 沿 +Z 后退（与 plane_action.py 一致）。
func _speed_for_y(y_from_bottom: float) -> float:
	if PLANE_CONTINUOUS:
		return _continuous_speed_for_y(y_from_bottom)

	for i in SPEED_Y_LIMITS.size():
		if y_from_bottom <= SPEED_Y_LIMITS[i]:
			return SPEED_VALUES[i]

	return SPEED_VALUES[SPEED_VALUES.size() - 1]


## 连续油门：底部 0 → PLANE_FULL_Y 处满速，与颜色边界对齐
func _continuous_speed_for_y(y_from_bottom: float) -> float:
	if y_from_bottom <= PLANE_NEUTRAL_Y:
		return 0.0

	var span: float = maxf(PLANE_FULL_Y - PLANE_NEUTRAL_Y, 1.0)
	var t: float = clampf(
		(y_from_bottom - PLANE_NEUTRAL_Y) / span,
		0.0,
		1.0
	)

	return PLANE_FWD_MAX * t


# 节点尺寸变化时同步给 shader（UV → 像素换算要用）
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


## 清空锁定
func _reset_latch() -> void:
	_latch_active = false
	_latch_speed = 0.0
	_latch_y_from_bottom = 0.0
	_still_time = 0.0
	_last_y_from_bottom = -1.0
