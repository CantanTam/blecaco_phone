extends Node

# ============================================================
# Car Mode 数据层
# ============================================================
# 职责：把「手机姿态」与「车辆前进/后退状态」合并成一条消息发给 Blender。
#
# 分工：
#   car_mode.gd          负责姿态校准、速度平滑、数据合并和消息发送
#   car_forward_area.gd  负责触控区域、遮罩、渐变、光晕和速度倍率
#   car_mode.tscn        负责节点结构
#
# 为什么合并成一条：
#   将旋转与前进量放在同一条消息中发送，减少消息数量，
#   让 Blender 在一次更新中同时获得姿态和前进数据。
# ============================================================

# ============================================================
# ⚙️ Car Mode 全部可调参数（集中在这里改）
# ============================================================

# ── 推流画面：动态反向旋转（旋转手机 → 画面不跟着转）──
const STREAM_ROLL_ENABLED: bool = true
# 反向旋转方向（真机若反了改成 -1.0）
const STREAM_ROLL_SIGN: float = -1.0
# 补偿系数（Blender 端相机已去掉横滚 → 这里补满手机横滚 = 1.0）
const STREAM_ROLL_GAIN: float = 1.0
# 画面抖动抑制：旋转平滑时间常数（越大越稳、越"肉"）
const STREAM_ROLL_SMOOTH_TAU: float = 0.08
# 调试：每秒打印重力/角度
const STREAM_ROLL_DEBUG: bool = false

# ── 方向盘灵敏度（三档循环）──
# STEER_SENSITIVITY % 3：
#   0 = 最强（1.6×）  1 = 最弱（0.6×，默认）  2 = 次之（1.0×）
const STEER_SENSITIVITY_MULTIPLIERS: Array = [1.6, 0.6, 1.0]
const ICON_STEER_SENSITIVITY: Array = [
	"res://resources/SteerSensitivityThree.svg",   # %3 == 0（最强）
	"res://resources/SteerSensitivityOne.svg",     # %3 == 1（最弱）
	"res://resources/SteerSensitivityTwo.svg",     # %3 == 2（次之）
]

var STEER_SENSITIVITY: int = 1
var _steer_sensitivity_icons: Array = [null, null, null]

# ── ZoomFit 缩放适配 ──
# 放大/缩小过渡动画时长（秒）
const ZOOM_FIT_TWEEN_TIME: float = 0.28

# ── 发送与初始化 ──
# 发送频率自适应 Blender 输出帧率（最低 60Hz，最高 120Hz）
const MIN_SEND_RATE: float = 60.0
const MAX_SEND_RATE: float = 120.0
const INITIALIZE_RETRY_INTERVAL: float = 0.25

# ── 车辆速度（油门）──
# 速度变化平滑：每秒逼近目标速度的速率（越大越跟手）
const SPEED_RAMP_PER_SECOND: float = 18.0
# 油门力度曲线（>1 = 低段更柔和，满油门保持满速）
# ⚠️ CarForwardArea 现在已经是连续油门，这里只是轻微踏板非线性 → 1.2 比较自然
const THROTTLE_EXPO: float = 1.2
# 油门归一化参考值（CarForwardArea 最大给出 9x）
const THROTTLE_MAX_REF: float = 9.0

# ── 转向（实际计算在 car_action.py，参数就在那个文件顶部）──
#   STEER_EXPO            舵量曲线（>1 = 中心更细腻）
#   STEER_SMOOTH_TAU      舵量平滑（抖动抑制）
#   STEER_FULL_SPEED      速度联动参考（达到该速度转向才满效率）
#   STEER_YAW_RATE_DEG_PER_SEC  满舵角速度
#   STEER_MAX_DEG / STEER_DEADZONE_DEG / STEER_SIGN

# ── 调试 ──
# 打印四元数信息（平时保持 false）
const VERBOSE_ORIENTATION_LOG := false

# ── 推流画面状态 ──
var stream_window: Control = null
var _stream_roll: float = 0.0
var _stream_debug_timer: float = 0.0
# 测试用：非零时替代 Input.get_gravity()
var _gravity_override: Vector3 = Vector3.ZERO

# 推流画面旋转是否被外部暂停（例如打开预览设置页时）
var _stream_rotation_suspended: bool = false

# ── ZoomFit 按钮（缩放适配开关，目前只做样式）──
var ZOOM_FIT: bool = false

const ICON_ZOOM_OFF: String = "res://resources/UnZoom.svg"
const ICON_ZOOM_ON: String = "res://resources/Zoom.svg"

# ── SetGround：地面追踪开关 ──────────────────────────────
# 只在 unlink 状态显示；长按 2 秒切换 HAS_GROUND
const ICON_NO_GROUND: String = "res://resources/NoCarGround.svg"
const ICON_HAS_GROUND: String = "res://resources/HasCarGround.svg"
const SET_GROUND_HOLD_SEC: float = 2.0

# ── SetGround 拖动切换 ──────────────────────────────────
## 长按成功后进入拖动状态，拖满这个距离才切换（防误触 ✓）
const SET_GROUND_DRAG_DIST: float = 300.0
## 弹回原位的时长
const SET_GROUND_SNAP_SEC: float = 0.15
## 颜色反馈：透明 → 彩色（0.12s）→ 保持（0.10s）→ 透明（0.22s）→ 直接回常态
const SET_GROUND_FLASH_IN: float = 0.12
const SET_GROUND_FLASH_HOLD: float = 0.10
const SET_GROUND_FLASH_OUT: float = 0.22
## HAS_GROUND = true 时闪绿色
const COLOR_HAS_GROUND := Color("00d455ff")
## HAS_GROUND = false 时闪红色
const COLOR_NO_GROUND := Color("ff5555ff")
## 常态背景色
const COLOR_SET_GROUND_NORMAL := Color("000000a0")

# 是否启用地面追踪（默认关闭）
var HAS_GROUND: bool = false

## 是否处于拖动状态（长按满 2 秒后进入）
var _sg_dragging: bool = false
## 按下点相对按钮左上角的偏移（保证拖动不跳位）
var _sg_grab_offset: Vector2 = Vector2.ZERO
## 按钮的固定位置（拖动前记录）
var _sg_rest_position: Vector2 = Vector2.ZERO
## 按钮专属的 StyleBoxFlat（必须 duplicate，否则会影响共用同一 SubResource 的其他按钮 ✗）
var _sg_style: StyleBoxFlat = null
## 颜色反馈用的 Tween
var _sg_flash_tween: Tween = null

var _icon_no_ground: Texture2D = null
var _icon_has_ground: Texture2D = null
var _set_ground_holding: bool = false
var _set_ground_hold_time: float = 0.0
var _link_button: Node = null

var _icon_zoom_off: Texture2D = null
var _icon_zoom_on: Texture2D = null

var _zoom_tween: Tween = null

# 触摸平台标志（真机上触摸会同时产生模拟鼠标事件，需要忽略鼠标避免双触发）
var _touch_platform: bool = false

var rotation_sender = preload(
	"res://scripts/getrotation.gd"
).new()

var rotation_send_timer: float = 0.0
var initialize_retry_timer: float = 0.0

# 当前车辆速度倍率，带正负号。
# 正数 = 前进，负数 = 后退，0 = 停止。
var _current_speed: float = 0.0

var connection_node: Node = null

# 读取 CarForwardArea 的 forward_speed。
# 使用 Node 类型，避免依赖 Godot 的全局脚本类缓存。
@onready var zoom_fit_button: Button = $ZoomFit
@onready var steer_sensitivity_button: Button = $SteerSensitivity
@onready var set_ground_button: Button = $SetGround
@onready var forward_area: Node = (
	get_node_or_null("CarForwardArea")
)


# 当前发送频率（Hz），跟随 Blender 的输出帧率。
func _send_rate() -> float:
	return clampf(
		Options.get_float("blender/output_fps"),
		MIN_SEND_RATE,
		MAX_SEND_RATE
	)


# 每条消息的基准位移。
# 每秒位移 = 发送频率 × 每条消息的步长 = 1.0 单位。
# 因此改变发送频率不会直接改变理论移动速度。
func _forward_step() -> float:
	return 1.0 / _send_rate()


# 让当前速度逐渐逼近触控区域给出的目标速度。
# 松开触控或暂停发送时，目标速度变为 0，车辆平滑减速。
func _ramp_speed(delta: float) -> void:
	var target_speed: float = 0.0

	if forward_area != null:
		var speed_value: Variant = forward_area.get(
			"forward_speed"
		)

		if speed_value != null:
			target_speed = float(speed_value)

	# ── 油门力度曲线 ──
	# CarForwardArea 给的是离散档位（后退 2x / 前进 1x、3x、9x）。
	# 归一化后做指数曲线，再还原量级：
	#   THROTTLE_EXPO > 1 → 低档更柔和，高档保持满速
	target_speed = _apply_throttle_curve(target_speed)

	# ⚠️ delta 异常大时（App 刚启动 / 场景加载卡顿）会一帧冲到满速 ✗
	#    表现为"第一次点前进突然窜出去一大段" ✗
	#    限制到 50ms（20fps）以内 ✓
	var ramp_delta: float = clampf(delta, 0.0, 0.05)

	_current_speed = move_toward(
		_current_speed,
		target_speed,
		SPEED_RAMP_PER_SECOND * ramp_delta
	)


# 手机是否已经完成初始姿态校准。
var phone_calibrated: bool = false

# Blender 是否已经记录车辆控制的初始状态。
var car_mode_initialized: bool = false


# ── SetGround 相关 ──────────────────────────────────────


## 屏幕坐标是否落在 SetGround 按钮上
func _is_set_ground_hit(viewport_position: Vector2) -> bool:
	if set_ground_button == null or not set_ground_button.visible:
		return false

	return set_ground_button.get_global_rect().has_point(viewport_position)


## 解析 Blender 推来的 ground_status 消息
func _on_ground_status_message(message: String) -> void:
	var data: Variant = JSON.parse_string(message)

	if not (data is Dictionary):
		return

	if data.get("type") != "ground_status":
		return

	_on_ground_status(
		bool(data.get("has_ground", false)),
		str(data.get("object", ""))
	)


## Blender 回报地面标记结果
##   has_ground = true  → 打标成功，跟踪该物体
##   has_ground = false → 没打到物体，HAS_GROUND 保持 false（Blender 用水平面兜底）
func _on_ground_status(has_ground: bool, object_name: String) -> void:
	HAS_GROUND = has_ground

	if HAS_GROUND:
		print("[CarMode] 地面追踪：开启（已标记 ", object_name, "）")
	else:
		print("[CarMode] 地面追踪：关闭（使用水平面）")

	_update_set_ground_icon()


## LinkButton 切换：pressed=true 表示 unlink（暂停），false 表示 link（恢复）
## ⚠️ 重新 link 时把 car_mode_initialized 清零 ✗
##    → 下一帧会重发 initialize
##    → Blender 用【当前相机的旋转/位置】重新做基准 ✓
##    → 不会再把手机上累积的转向数据强加到相机上 ✓
func _on_link_toggled(pressed: bool) -> void:
	if pressed:
		# unlink：暂停发送
		print("[CarMode] unlink")
		return

	# link：重新初始化（用 Blender 当前相机姿态做基准）
	car_mode_initialized = false
	initialize_retry_timer = 0.0
	phone_calibrated = false

	print("[CarMode] 重新 link → 将用 Blender 当前相机姿态重新初始化")


## 通知 Blender 开启/关闭地面标记
##   enabled = true  → Blender 沿相机局部 -Y 打射线，第一个命中的物体打上 is_ground
##   enabled = false → Blender 删掉已标记物体的 is_ground
func _send_ground_command(enabled: bool) -> void:
	if connection_node == null or not is_instance_valid(connection_node):
		print("[CarMode] Connection 不可用，无法发送地面命令")
		return

	# ⚠️ 不能用 send_action：unlink 状态下它被禁用 ✗
	#    改用 send_setting（type = "setting" 不受门控）✓
	#    setting 通道本来就是「手机 → Blender 单向命令」的既有通路
	var sent = connection_node.call("send_setting", "ground", enabled)

	print("[CarMode] 发送地面命令 enabled=", enabled, " 成功=", sent)


## 拖动中：按钮跟随手指
func _move_set_ground_to(global_pos: Vector2) -> void:
	if not _sg_dragging:
		return

	set_ground_button.global_position = global_pos - _sg_grab_offset

	# ⚠️ 这里【不触发】✗ 只在松手时判定（见 _on_set_ground_button_up）


## 拖满 300px：弹回原位 + 切换状态 + 闪烁
func _trigger_drag_toggle() -> void:
	_sg_dragging = false

	print("[CarMode] SetGround 拖动完成 → 切换状态")

	# HAS_GROUND 先取反（Blender 会再回传确认，最终以回传为准 ✓）
	if HAS_GROUND:
		_send_ground_command(false)
	else:
		_send_ground_command(true)

	_snap_back()      # 弹回后会通过 tween_callback 触发闪烁 ✓


## 拖动取消（没拖够就松手）：弹回，不切换
func _cancel_drag() -> void:
	_sg_dragging = false
	print("[CarMode] SetGround 拖动取消（未满 300px）")
	_snap_back()


## 弹回固定位置（0.15s 补间）
func _snap_back() -> void:
	if _sg_flash_tween != null and _sg_flash_tween.is_valid():
		_sg_flash_tween.kill()

	_sg_flash_tween = create_tween()
	_sg_flash_tween.tween_property(
		set_ground_button, "global_position", _sg_rest_position, SET_GROUND_SNAP_SEC
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_sg_flash_tween.tween_callback(_play_color_flash)


## 颜色反馈：
##   完全透明 → 彩色（0.12s）→ 保持（0.10s）→ 完全透明（0.22s）→ 直接回常态色
func _play_color_flash() -> void:
	if _sg_style == null:
		return

	if _sg_flash_tween != null and _sg_flash_tween.is_valid():
		_sg_flash_tween.kill()

	var flash_color: Color = (
		COLOR_HAS_GROUND if HAS_GROUND else COLOR_NO_GROUND
	)

	var transparent: Color = flash_color
	transparent.a = 0.0

	_sg_flash_tween = create_tween()
	# ① 透明 → 彩色
	_sg_flash_tween.tween_property(
		_sg_style, "bg_color", flash_color, SET_GROUND_FLASH_IN
	)
	# ② 保持
	_sg_flash_tween.tween_interval(SET_GROUND_FLASH_HOLD)
	# ③ 彩色 → 透明
	_sg_flash_tween.tween_property(
		_sg_style, "bg_color", transparent, SET_GROUND_FLASH_OUT
	)
	# ④ 直接回常态色
	_sg_flash_tween.tween_callback(
		func() -> void: _sg_style.bg_color = COLOR_SET_GROUND_NORMAL
	)


## 按 HAS_GROUND 更新图标
func _update_set_ground_icon() -> void:
	if set_ground_button == null:
		return

	var tex: Texture2D = _icon_has_ground if HAS_GROUND else _icon_no_ground

	if tex != null:
		set_ground_button.icon = tex


## 只在 unlink 状态显示
## LinkButton.button_pressed: true = unlink，false = link
## SetGround 按钮现在始终显示 ✓
##   之前只在 unlink 时显示 ✗ 原因是 unlink 会禁用 send_action ✗
##   现在地面命令走 send_setting（不受门控 ✓）→ link / unlink 都能用 ✓
func _update_set_ground_visibility() -> void:
	if set_ground_button == null:
		return

	if not set_ground_button.visible:
		set_ground_button.visible = true
		print("[CarMode] SetGround 按钮始终显示")


func _on_set_ground_button_down(grab_pos: Vector2) -> void:
	_set_ground_holding = true
	_set_ground_hold_time = 0.0
	_sg_grab_offset = grab_pos - set_ground_button.global_position


func _on_set_ground_button_up() -> void:
	_set_ground_holding = false
	_set_ground_hold_time = 0.0

	if not _sg_dragging:
		return

	# 松手时才判定拖动距离 ✓
	var moved: float = (
		set_ground_button.global_position - _sg_rest_position
	).length()

	if moved >= SET_GROUND_DRAG_DIST:
		# 拖够了 → 切换 + 弹回 + 闪烁 ✓
		_trigger_drag_toggle()
	else:
		# 没拖够 → 弹回，不切换 ✓
		_cancel_drag()


## 长按计时：达到 SET_GROUND_HOLD_SEC 就切换 HAS_GROUND
func _tick_set_ground_hold(delta: float) -> void:
	if not _set_ground_holding:
		return

	_set_ground_hold_time += delta

	if _set_ground_hold_time < SET_GROUND_HOLD_SEC:
		return

	_set_ground_holding = false
	_set_ground_hold_time = 0.0

	# 长按成功 → 进入【拖动状态】✓
	#   拖满 SET_GROUND_DRAG_DIST 才真正切换（双重防误触 ✓）
	_sg_dragging = true
	_sg_rest_position = set_ground_button.global_position

	print("[CarMode] SetGround 进入拖动状态（拖满 300px 切换）")


func _ready() -> void:
	# 找推流画面节点（stream.tscn 里的 StreamWindow，全屏铺满）
	# ZoomFit 按钮：两个图标 + 初始样式
	if ResourceLoader.exists(ICON_ZOOM_OFF):
		_icon_zoom_off = load(ICON_ZOOM_OFF)

	if ResourceLoader.exists(ICON_ZOOM_ON):
		_icon_zoom_on = load(ICON_ZOOM_ON)

	_touch_platform = (
		DisplayServer.is_touchscreen_available()
		or OS.has_feature("mobile")
	)

	if zoom_fit_button != null:
		zoom_fit_button.focus_mode = Control.FOCUS_NONE
		zoom_fit_button.expand_icon = true

	_update_zoom_fit_icon()

	# 方向盘灵敏度按钮：三个图标 + 初始样式
	for i in range(ICON_STEER_SENSITIVITY.size()):
		if ResourceLoader.exists(ICON_STEER_SENSITIVITY[i]):
			_steer_sensitivity_icons[i] = load(ICON_STEER_SENSITIVITY[i])

	if steer_sensitivity_button != null:
		steer_sensitivity_button.focus_mode = Control.FOCUS_NONE
		steer_sensitivity_button.expand_icon = true

	_update_steer_sensitivity_icon()

	# LinkButton：re-link 时需要重新初始化（用 Blender 当前相机姿态做基准）
	var link_btn := get_tree().root.find_child("LinkButton", true, false)

	if link_btn != null and link_btn.has_signal("toggled"):
		if not link_btn.toggled.is_connected(_on_link_toggled):
			link_btn.toggled.connect(_on_link_toggled)
		print("[CarMode] 已监听 LinkButton（re-link 会重新初始化）")

	# SetGround：加载两个图标 + 接长按信号 + 初始显示状态
	if ResourceLoader.exists(ICON_NO_GROUND):
		_icon_no_ground = load(ICON_NO_GROUND)

	if ResourceLoader.exists(ICON_HAS_GROUND):
		_icon_has_ground = load(ICON_HAS_GROUND)

	if set_ground_button != null:
		set_ground_button.focus_mode = Control.FOCUS_NONE
		set_ground_button.expand_icon = true
		# ⚠️ 不用 button_down/button_up 信号：真机上不可靠 ✗
		#    改用 _input() 手动矩形命中检测（和 drone_mode 的 Roll 按钮同一套做法）

	# SetGround：复制一份专属样式（SubResource 是共用的 ✗ 直接改会影响别的按钮 ✗）
	if set_ground_button != null:
		var base_style: StyleBox = set_ground_button.get_theme_stylebox("normal")

		if base_style is StyleBoxFlat:
			_sg_style = (base_style as StyleBoxFlat).duplicate()
			set_ground_button.add_theme_stylebox_override("normal", _sg_style)
			_sg_style.bg_color = COLOR_SET_GROUND_NORMAL

		_sg_rest_position = set_ground_button.global_position

	_update_set_ground_icon()
	_update_set_ground_visibility()
	print("[CarMode][DBG] SetGround 初始化：按钮存在=", set_ground_button != null,
		" 可见=", set_ground_button.visible if set_ground_button else false,
		" HAS_GROUND=", HAS_GROUND,
		" 图标已加载=", _icon_no_ground != null and _icon_has_ground != null)

	stream_window = get_tree().root.find_child(
		"StreamWindow",
		true,
		false
	) as Control

	if stream_window == null:
		push_warning("[CarMode] 找不到 StreamWindow，画面旋转不可用")

	# 查找常驻的 Connection 节点。
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
	)

	# 接收 Blender 回报的 ground_status（决定 HAS_GROUND）
	if connection_node != null and is_instance_valid(connection_node):
		if connection_node.has_signal("text_message_received"):
			if not connection_node.text_message_received.is_connected(
				_on_ground_status_message
			):
				connection_node.text_message_received.connect(
					_on_ground_status_message
				)

	if rotation_sender.is_available():
		print("[CarMode] Orientation plugin loaded")
	else:
		push_error(
			"[CarMode] Orientation plugin singleton not found"
		)

	if connection_node == null:
		push_error(
			"[CarMode] Connection node not found"
		)
	elif not connection_node.has_method("send_action"):
		push_error(
			"[CarMode] Connection.send_action() not found"
		)


func _process(delta: float) -> void:
	# 画面动态旋转：放在所有提前 return 之前，独立于网络/姿态数据
	_update_stream_rotation(delta)

	# SetGround：长按计时 + 跟随 link 状态显示/隐藏
	# （放在提前 return 之前，保证 link 状态变化立刻生效）
	_tick_set_ground_hold(delta)
	_update_set_ground_visibility()

	if not rotation_sender.has_orientation_data():
		return

	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	# 第一次进入 Car Mode 时，校准手机当前姿态。
	if not phone_calibrated:
		if not rotation_sender.calibrate():
			return

		phone_calibrated = true

		print("[CarMode] Phone orientation calibrated")

	# 先通知 Blender 初始化车辆控制状态。
	# 初始化成功之前，不发送常规姿态数据。
	if not car_mode_initialized:
		initialize_retry_timer += delta

		if initialize_retry_timer < INITIALIZE_RETRY_INTERVAL:
			return

		initialize_retry_timer = 0.0

		var sent: bool = bool(
			connection_node.call(
				"send_action",
				"car",
				{"command": "initialize"}
			)
		)

		if sent:
			car_mode_initialized = true

			print(
				"[CarMode] Blender car control initialized"
			)

		return

	# 每帧更新速度，使加速和减速保持平滑。
	# 放在发送节流之前，保证速度斜坡不会只在发送时推进。
	_ramp_speed(delta)

	# 按设定频率发送车辆姿态与前进/后退数据。
	rotation_send_timer += delta

	if rotation_send_timer < 1.0 / _send_rate():
		return

	rotation_send_timer = 0.0

	var q: Quaternion = (
		rotation_sender.get_rotation_quaternion()
	)

	# 车辆前进/后退的单条消息位移。
	#
	# forward 为正数：Blender 沿车辆局部 -Z 方向前进。
	# forward 为负数：Blender 沿车辆局部 +Z 方向后退。
	var move_speed: float = maxf(
		0.0,
		Options.get_float("move_speed")
	)

	var forward_distance: float = (
		_forward_step()
		* _current_speed
		* move_speed
	)

	# 将手机姿态和车辆前进/后退量合并到同一条消息。
	var car_data: Dictionary = {
		"x": q.x,
		"y": q.y,
		"z": q.z,
		"w": q.w,
		"forward": forward_distance,
		"steer_scale": _steer_sensitivity_scale()
	}

	connection_node.call(
		"send_action",
		"car",
		car_data
	)

	if VERBOSE_ORIENTATION_LOG:
		print(
			"[CarMode] Quaternion sent: ",
			"X=", snappedf(q.x, 0.01),
			" Y=", snappedf(q.y, 0.01),
			" Z=", snappedf(q.z, 0.01),
			" W=", snappedf(q.w, 0.01)
		)


## 取重力（测试时可注入）
func _get_gravity() -> Vector3:
	if _gravity_override.length() > 0.01:
		return _gravity_override

	return Input.get_gravity()


## 根据手机横向倾斜角 θ，把推流画面反向旋转 -θ
func _update_stream_rotation(delta: float) -> void:
	if not STREAM_ROLL_ENABLED:
		return

	# 被外部暂停（打开预览设置页）→ 不更新旋转
	if _stream_rotation_suspended:
		return

	if stream_window == null or not is_instance_valid(stream_window):
		return

	var gravity: Vector3 = _get_gravity()

	if gravity.length() < 0.1:
		return

	# 屏幕平面内的重力方向 → 手机横滚角 θ
	#   atan2(g.x, -g.y)：竖直握持时 θ = 0
	var roll: float = atan2(gravity.x, -gravity.y)

	# 平滑（与帧率无关的指数平滑）
	var k: float = 1.0 - exp(-maxf(delta, 1e-4) / STREAM_ROLL_SMOOTH_TAU)
	_stream_roll = lerp_angle(_stream_roll, roll, k)

	# 绕自身中心旋转（不缩放）
	stream_window.pivot_offset = stream_window.size * 0.5
	stream_window.rotation = _stream_roll * STREAM_ROLL_SIGN * STREAM_ROLL_GAIN

	if STREAM_ROLL_DEBUG:
		_stream_debug_timer += delta

		if _stream_debug_timer >= 1.0:
			_stream_debug_timer = 0.0
			print(
				"[CarMode] gravity=%s  θ=%.1f°  增益=%.2f  画面旋转=%.1f°"
				% [
					str(gravity),
					rad_to_deg(roll),
					STREAM_ROLL_GAIN,
					rad_to_deg(stream_window.rotation)
				]
			)


## 离开 Car Mode：把推流画面转回 0，避免影响其它模式
func _exit_tree() -> void:
	if _zoom_tween != null and _zoom_tween.is_valid():
		_zoom_tween.kill()

	if stream_window != null and is_instance_valid(stream_window):
		stream_window.rotation = 0.0
		stream_window.scale = Vector2.ONE


# ============================================================
# ZoomFit 按钮（缩放适配开关，目前只有样式切换）
# ============================================================

## 屏幕坐标是否落在 ZoomFit 按钮上
func _is_zoom_fit_hit(viewport_position: Vector2) -> bool:
	if zoom_fit_button == null or not zoom_fit_button.visible:
		return false

	return zoom_fit_button.get_global_rect().has_point(viewport_position)


## 触摸/鼠标输入：命中 ZoomFit 就切换（用矩形命中，不用 Button.pressed）
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		# SetGround：按下开始计时，抬起结束（手动命中检测，真机可靠 ✓）
		if event.pressed and _is_set_ground_hit(event.position):
			_on_set_ground_button_down(event.position)
			# ⚠️ 不调用 set_input_as_handled()，与其他按钮保持一致
			return

		if not event.pressed and (_set_ground_holding or _sg_dragging):
			_on_set_ground_button_up()
			return

		# ZoomFit / SteerSensitivity 照旧 ✓（必须在 ScreenTouch 分支里）
		if event.pressed and _is_zoom_fit_hit(event.position):
			_toggle_zoom_fit()
			get_viewport().set_input_as_handled()
			return

		if event.pressed and _is_steer_sensitivity_hit(event.position):
			_cycle_steer_sensitivity()
			get_viewport().set_input_as_handled()

		return

	# 拖动中：手指移动 → 按钮跟随（独立分支 ✓）
	if event is InputEventScreenDrag:
		if _sg_dragging:
			_move_set_ground_to((event as InputEventScreenDrag).position)
		return

	if event is InputEventMouseMotion:
		if _sg_dragging and not _touch_platform:
			_move_set_ground_to((event as InputEventMouseMotion).position)
		return

	if event is InputEventMouseButton:
		# 真机上触摸会产生模拟鼠标事件 → 必须忽略，否则会切两次
		if _touch_platform:
			return

		if event.button_index != MOUSE_BUTTON_LEFT:
			return

		# 鼠标松开：结束 SetGround 长按
		if not event.pressed:
			if _set_ground_holding or _sg_dragging:
				_on_set_ground_button_up()
			return

		if _is_set_ground_hit(event.position):
			_on_set_ground_button_down(event.position)
			get_viewport().set_input_as_handled()
			return

		if _is_zoom_fit_hit(event.position):
			_toggle_zoom_fit()
			get_viewport().set_input_as_handled()
			return

		if _is_steer_sensitivity_hit(event.position):
			_cycle_steer_sensitivity()
			get_viewport().set_input_as_handled()


## 点击：ZOOM_FIT = !ZOOM_FIT
func _toggle_zoom_fit() -> void:
	ZOOM_FIT = not ZOOM_FIT
	_update_zoom_fit_icon()
	_apply_zoom_fit()

	print("[CarMode] ZOOM_FIT =", ZOOM_FIT)


## 按当前状态设置图标
func _update_zoom_fit_icon() -> void:
	if zoom_fit_button == null:
		return

	var icon: Texture2D = _icon_zoom_on if ZOOM_FIT else _icon_zoom_off

	if icon != null:
		zoom_fit_button.icon = icon
		zoom_fit_button.text = ""
	else:
		zoom_fit_button.text = "ON" if ZOOM_FIT else "OFF"


## ZoomFit 的缩放目标：
##   ZOOM_FIT = true  → 让"画面的高"等于"屏幕的宽"（scale = 屏幕宽 / 屏幕高）
##                      → 放大裁切，旋转时屏幕里不会露出推流背景
##   ZOOM_FIT = false → 复原成 1:1
func _zoom_fit_target_scale() -> Vector2:
	if stream_window == null or not is_instance_valid(stream_window):
		return Vector2.ONE

	if not ZOOM_FIT:
		return Vector2.ONE

	var screen_width: float = stream_window.size.x
	var screen_height: float = maxf(stream_window.size.y, 1.0)

	# 画面高（= 屏幕高）→ 变成屏幕宽
	var factor: float = screen_width / screen_height

	return Vector2(factor, factor)


## 带过渡动画地应用缩放（绕画面中心，因为 pivot_offset 已在旋转里设为中心）
func _apply_zoom_fit() -> void:
	if stream_window == null or not is_instance_valid(stream_window):
		return

	if _zoom_tween != null and _zoom_tween.is_valid():
		_zoom_tween.kill()

	_zoom_tween = create_tween()
	_zoom_tween.set_trans(Tween.TRANS_SINE)
	_zoom_tween.set_ease(Tween.EASE_IN_OUT)
	_zoom_tween.tween_property(
		stream_window,
		"scale",
		_zoom_fit_target_scale(),
		ZOOM_FIT_TWEEN_TIME
	)


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


# ============================================================
# 方向盘灵敏度（三档循环）
# ============================================================

## 屏幕坐标是否落在灵敏度按钮上
func _is_steer_sensitivity_hit(viewport_position: Vector2) -> bool:
	if steer_sensitivity_button == null or not steer_sensitivity_button.visible:
		return false

	return steer_sensitivity_button.get_global_rect().has_point(viewport_position)


## 点击：STEER_SENSITIVITY = (STEER_SENSITIVITY + 1) % 3
func _cycle_steer_sensitivity() -> void:
	STEER_SENSITIVITY = (STEER_SENSITIVITY + 1) % 3
	_update_steer_sensitivity_icon()

	print(
		"[CarMode] STEER_SENSITIVITY =",
		STEER_SENSITIVITY,
		" 倍率 =",
		_steer_sensitivity_scale()
	)


## 当前灵敏度倍率（按 %3 取档）
func _steer_sensitivity_scale() -> float:
	var index: int = STEER_SENSITIVITY % STEER_SENSITIVITY_MULTIPLIERS.size()

	return float(STEER_SENSITIVITY_MULTIPLIERS[index])


## 按当前档位设置图标
func _update_steer_sensitivity_icon() -> void:
	if steer_sensitivity_button == null:
		return

	var index: int = STEER_SENSITIVITY % _steer_sensitivity_icons.size()
	var icon: Texture2D = _steer_sensitivity_icons[index]

	if icon != null:
		steer_sensitivity_button.icon = icon
		steer_sensitivity_button.text = ""
	else:
		steer_sensitivity_button.text = str(index)


## 外部开关：暂停 / 恢复推流画面的动态旋转
##   暂停时立刻把画面转回水平（0°），避免预览页里看到歪的推流
func set_stream_rotation_enabled(enabled: bool) -> void:
	_stream_rotation_suspended = not enabled

	if enabled:
		print("[CarMode] 推流画面旋转：恢复")
		return

	_stream_roll = 0.0

	if stream_window != null and is_instance_valid(stream_window):
		stream_window.rotation = 0.0

	print("[CarMode] 推流画面旋转：暂停（画面已回正）")
