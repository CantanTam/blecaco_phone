extends Node

# ============================================================
# Plane Mode 数据层
# ============================================================
# 职责：把「手机姿态」与「前进键状态」合并成一条消息发给 Blender。
# 表现层（遮罩/颜色/触控检测）全在 plane_forward_area.gd，
# 本文件不碰任何 UI，也不参与视觉逻辑。
#
# 为什么合并成一条：
#   拆成两条（旋转 100Hz + 前进 100Hz = 200 条/秒）时，Blender 端每个 tick
#   要吞 3~4 条，而只有最后一条能反映到画面，旋转采样被大量丢弃
#   → 看起来一格一格地卡。合并后消息量 = 本文件的发送频率（60Hz），
#   一条消息同时携带姿态与位移。
# ============================================================

const INITIALIZE_RETRY_INTERVAL: float = 0.25

# 发送频率自适应 Blender 的输出帧率：
#   插件会在「客户端接入 / 帧率变化」时推送 setting/output_fps，
#   main.gd 收下后存进 Options（默认 60）。
# 规则：不低于 MIN（保证实时手感），不高于 MAX（超高帧率时别刷爆）。
# 取「输出帧率」的意义：时间轴每一帧都能拿到一个新姿态，
# 不会出现同一个姿态被连续几帧重复采样。
const MIN_SEND_RATE: float = 60.0
const MAX_SEND_RATE: float = 120.0

# ---- 推进速度的「加速度」效果 ----
# 速度按固定速率逼近目标档位（而不是瞬间跳变），单位是「倍率/秒」。
#   1x → 3x    ：(3-1)/18  ≈ 0.11 秒
#   1x → 9x    ：(9-1)/18  ≈ 0.44 秒
#  -4x → +9x   ：(9+4)/18  ≈ 0.72 秒（含换向：先减到 0 再反向加速）
# 想要更跟手就调大（25~30），想要更沉稳/更"重"就调小（10~12）。
const SPEED_RAMP_PER_SECOND: float = 18.0

# ── 飞行轨迹防抖等级（StableButton，四档循环）──
# PLANE_STABLE_LEVEL % 4：1 → 0（无防抖） 2 → 0.05  3 → 0.12  0 → 0.3
const STABLE_ICONS: Array = [
	"res://resources/StableLevelThree.svg",   # %4 == 0 → τ 0.30
	"res://resources/StableLevelZero.svg",    # %4 == 1 → τ 0
	"res://resources/StableLevelOne.svg",     # %4 == 2 → τ 0.05
	"res://resources/StableLevelTwo.svg",     # %4 == 3 → τ 0.12
]
const STABLE_TAUS: Array = [0.30, 0.0, 0.05, 0.12]

var PLANE_STABLE_LEVEL: int = 1
var _stable_icons: Array = [null, null, null, null]

# 触摸平台标志（真机会把触摸也发一份模拟鼠标事件，需要忽略）
var _touch_platform: bool = false

# 油门力度曲线（>1 = 低段更柔和；连续油门本身已线性，1.2 比较自然）
const THROTTLE_EXPO: float = 1.2
const THROTTLE_MAX_REF: float = 9.0

# 打开后会以 ~60Hz 打印每条四元数，会把 logcat 环形缓冲区冲掉，
# 导致真正有用的日志在你回看时已经消失；排查时再改 true。
const VERBOSE_ORIENTATION_LOG := false

var rotation_sender = preload(
	"res://scripts/getrotation.gd"
).new()

var rotation_send_timer: float = 0.0
var initialize_retry_timer: float = 0.0

# 当前推进速度（带符号倍率）：由下面的斜坡逐帧逼近 PlaneForwardArea 给的档位
var _current_speed: float = 0.0

var connection_node: Node = null

# 表现层节点：本文件只读它的 forward_speed（带符号速度倍率）
# 用 Node 类型 + get() 访问，避免依赖 Godot 的全局类缓存
@onready var stable_button: Button = $StableButton
@onready var forward_area: Node = (
	get_node_or_null("PlaneForwardArea")
)


# 当前发送频率（Hz）：跟着 Blender 的输出帧率走
func _send_rate() -> float:
	return clampf(
		Options.get_float("blender/output_fps"),
		MIN_SEND_RATE,
		MAX_SEND_RATE
	)


# 每条消息前进的基准步长。
# 故意取「发送间隔」：每秒位移 = 发送频率 × 步长 = 1.0 单位，
# 与发送频率无关 —— 所以改 Blender 输出帧率不会改变飞行速度。
func _forward_step() -> float:
	return 1.0 / _send_rate()


# 加速度效果：把 _current_speed 按固定速率逼近 PlaneForwardArea 给的档位。
# 松手 / LinkButton 暂停时，目标变成 0，于是也会平滑减速而不是硬停。
func _ramp_speed(delta: float) -> void:
	var target_speed := 0.0

	if forward_area != null:
		var speed_value: Variant = forward_area.get("forward_speed")

		if speed_value != null:
			target_speed = float(speed_value)

	# 油门力度曲线
	target_speed = _apply_throttle_curve(target_speed)

	_current_speed = move_toward(
		_current_speed,
		target_speed,
		SPEED_RAMP_PER_SECOND * delta
	)

# 手机是否已经完成初始姿态校准
var phone_calibrated: bool = false

# Blender 是否已经记录摄像机初始姿态
var free_mode_initialized: bool = false


func _ready() -> void:
	# StableButton：四个图标 + 初始样式
	for i in range(STABLE_ICONS.size()):
		if ResourceLoader.exists(STABLE_ICONS[i]):
			_stable_icons[i] = load(STABLE_ICONS[i])

	_touch_platform = (
		DisplayServer.is_touchscreen_available()
		or OS.has_feature("mobile")
	)

	if stable_button != null:
		stable_button.focus_mode = Control.FOCUS_NONE
		stable_button.expand_icon = true

	_update_stable_icon()

	# 查找现有的 Connection 节点
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
	)

	# LinkButton 恢复发送时：把手机"当前姿态"当成新的零点重新校准，
	# 配合 Blender 侧 relink 恢复的相机基准 → 暂停期间转过手机，恢复后相机不会跳。
	if (
		connection_node != null
		and connection_node.has_signal("action_sending_changed")
	):
		connection_node.connect(
			"action_sending_changed",
			_on_action_sending_changed
		)

	if rotation_sender.is_available():
		print("[Orientation] Plugin loaded")
	else:
		push_error(
			"[Orientation] Plugin singleton not found"
		)

	if connection_node == null:
		push_error(
			"[Orientation] Connection node not found"
		)
	elif not connection_node.has_method("send_action"):
		push_error(
			"[Orientation] Connection.send_action() not found"
		)


func _process(delta: float) -> void:
	if not rotation_sender.has_orientation_data():
		return

	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	# 第一次进入 Free Mode 时，记录手机当前姿态
	if not phone_calibrated:
		if not rotation_sender.calibrate():
			return

		phone_calibrated = true

		print("[Orientation] Phone orientation calibrated")

	# 先通知 Blender 保存活动摄像机的初始旋转
	# 初始化消息成功发送前，不发送手机旋转数据
	if not free_mode_initialized:
		initialize_retry_timer += delta

		if initialize_retry_timer < INITIALIZE_RETRY_INTERVAL:
			return

		initialize_retry_timer = 0.0

		var sent: bool = bool(
			connection_node.call(
				"send_action",
				"plane",
				{"command": "initialize"}
			)
		)

		if sent:
			free_mode_initialized = true

			print(
				"[Orientation] Blender camera initialized"
			)

		return

	# 加速度效果：把当前速度按固定速率逼近 PlaneForwardArea 给出的档位。
	# 放在发送节流「之前」—— 每帧都推进，所以松手 / 暂停发送时也会平滑减速到 0。
	_ramp_speed(delta)

	# 初始化完成后，继续发送手机相对旋转 + 前进量
	rotation_send_timer += delta

	if rotation_send_timer < 1.0 / _send_rate():
		return

	rotation_send_timer = 0.0

	var q: Quaternion = (
		rotation_sender.get_rotation_quaternion()
	)

	# 前进/后退量 = 带符号速度倍率 × 全局缩放 × 每条消息的步长。
	# 正数 → Blender 沿相机局部 -Z 前飞；负数 → 沿 +Z 后退。
	var forward_distance := _forward_step() * (
		_current_speed
		* maxf(0.0, Options.get_float("move_speed"))
	)

	var plane_data: Dictionary = {
		"x": q.x,
		"y": q.y,
		"z": q.z,
		"w": q.w,
		"forward": forward_distance,
		"stable_tau": _stable_tau()
	}

	connection_node.call(
		"send_action",
		"plane",
		plane_data
	)

	if VERBOSE_ORIENTATION_LOG:
		print(
			"[Orientation] Quaternion sent: ",
			"X=", snappedf(q.x, 0.01),
			" Y=", snappedf(q.y, 0.01),
			" Z=", snappedf(q.z, 0.01),
			" W=", snappedf(q.w, 0.01)
		)


## LinkButton 恢复发送：重新校准手机姿态（当前姿态 = 新零点）
func _on_action_sending_changed(enabled: bool) -> void:
	if not enabled:
		return   # 暂停：不用做任何事（Blender 那边已收到 unlink 并存好相机旋转）

	if rotation_sender.calibrate():
		print("[Orientation] Link 恢复：已重新校准手机姿态")
	else:
		push_warning("[Orientation] Link 恢复：手机姿态重新校准失败（暂无数据？）")


## 油门力度曲线：保留符号，按 |值| 归一化后做指数
func _apply_throttle_curve(raw_speed: float) -> float:
	if is_zero_approx(raw_speed):
		return 0.0

	var sign_value: float = signf(raw_speed)
	var normalized: float = clampf(
		absf(raw_speed) / THROTTLE_MAX_REF,
		0.0,
		1.0
	)

	return sign_value * THROTTLE_MAX_REF * pow(normalized, THROTTLE_EXPO)


## 离开 Plane Mode：把速度与计时器复位，避免残留状态
func _exit_tree() -> void:
	_current_speed = 0.0
	rotation_send_timer = 0.0
	initialize_retry_timer = 0.0


# ============================================================
# 飞行轨迹防抖等级（StableButton）
# ============================================================

## 当前防抖时间常数（秒）
func _stable_tau() -> float:
	return float(STABLE_TAUS[PLANE_STABLE_LEVEL % 4])


## 触摸/鼠标输入：命中 StableButton 就切换档位
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _is_stable_hit(event.position):
			_cycle_stable_level()
			get_viewport().set_input_as_handled()

		return

	if event is InputEventMouseButton:
		if _touch_platform:
			return

		if (
			event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT
			and _is_stable_hit(event.position)
		):
			_cycle_stable_level()
			get_viewport().set_input_as_handled()


## 屏幕坐标是否落在 StableButton 上
func _is_stable_hit(viewport_position: Vector2) -> bool:
	if stable_button == null or not stable_button.visible:
		return false

	return stable_button.get_global_rect().has_point(viewport_position)


## 点击：PLANE_STABLE_LEVEL = (PLANE_STABLE_LEVEL + 1) % 4
func _cycle_stable_level() -> void:
	PLANE_STABLE_LEVEL = (PLANE_STABLE_LEVEL + 1) % 4
	_update_stable_icon()

	print(
		"[PlaneMode] PLANE_STABLE_LEVEL =",
		PLANE_STABLE_LEVEL,
		" τ =",
		_stable_tau()
	)


## 按当前等级设置图标
func _update_stable_icon() -> void:
	if stable_button == null:
		return

	var index: int = PLANE_STABLE_LEVEL % 4
	var icon: Texture2D = _stable_icons[index]

	if icon != null:
		stable_button.icon = icon
		stable_button.text = ""
	else:
		stable_button.text = str(index)
