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

const INITIALIZE_RETRY_INTERVAL: float = 0.25

# 发送频率自适应 Blender 的输出帧率。
# 最低 60 Hz，最高 120 Hz。
const MIN_SEND_RATE: float = 60.0
const MAX_SEND_RATE: float = 120.0

# ---- 车辆速度变化的平滑效果 ----
# 当前速度按固定速率逐渐逼近目标速度，而不是立即跳变。
#
# 例如：
#   1x → 3x：约 0.11 秒
#   1x → 9x：约 0.44 秒
# 反向操作时也会先减速，再逐渐向相反方向加速。
const SPEED_RAMP_PER_SECOND: float = 18.0

# 打开后会持续打印四元数调试信息。
# 正常使用时保持 false，避免大量日志影响调试。
const VERBOSE_ORIENTATION_LOG := false

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

	_current_speed = move_toward(
		_current_speed,
		target_speed,
		SPEED_RAMP_PER_SECOND * delta
	)


# 手机是否已经完成初始姿态校准。
var phone_calibrated: bool = false

# Blender 是否已经记录车辆控制的初始状态。
var car_mode_initialized: bool = false


func _ready() -> void:
	# 查找常驻的 Connection 节点。
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
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
		"forward": forward_distance
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
